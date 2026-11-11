# Real, isolated Windows file-lock regressions. No Cage install/build is invoked.
#requires -Version 7.0
. (Join-Path $PSScriptRoot 'windows-common.ps1')
. (Join-Path $PSScriptRoot 'windows-build-move.ps1')
if (-not $IsWindows) { throw 'File-sharing regression requires Windows.' }
function Assert-Move([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$fixtureRoot = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('cage-build-move-test-' + [guid]::NewGuid().ToString('N')))).FullName
$savedRunnerTemp = $env:RUNNER_TEMP
$helpers = [Collections.Generic.List[object]]::new()
$passed = $false
function New-MoveFixture {
    $stage = Join-Path $fixtureRoot ('windows-build-' + [guid]::NewGuid().ToString('N'))
    $resources = New-Item -ItemType Directory -Path (Join-Path $stage 'app/resources') -Force
    $file = Join-Path $resources.FullName 'cage.exe'
    [IO.File]::WriteAllText($file, 'isolated fixture, not an executable')
    return @{ stage = $stage; file = $file; destination = (Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))) }
}
function Start-LockFixture($Fixture, [int]$ReleaseAfterMilliseconds = 0) {
    $id = [guid]::NewGuid().ToString('N')
    $ready = Join-Path $fixtureRoot ($id + '.ready')
    $release = Join-Path $fixtureRoot ($id + '.release')
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'windows-build-lock-fixture.ps1'), '-Root', $fixtureRoot, '-Target', $Fixture.file, '-Ready', $ready, '-Release', $release, '-ReleaseAfterMilliseconds', "$ReleaseAfterMilliseconds")) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $helper = @{ process = $process; release = $release }
    $helpers.Add($helper)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready)) {
        if ($process.HasExited -or $clock.ElapsedMilliseconds -gt 5000) { throw 'Lock fixture did not become ready.' }
        Start-Sleep -Milliseconds 20
    }
    return $helper
}
try {
    $env:RUNNER_TEMP = $fixtureRoot
    Initialize-WindowsBuildLockQuery
    $unrelated = New-MoveFixture
    $unrelatedHelper = Start-LockFixture $unrelated
    $delayed = New-MoveFixture
    $evidence = New-WindowsBuildMoveEvidence $delayed.stage
    $delayedHelper = Start-LockFixture $delayed 2500
    Move-WindowsBuildApp $evidence $delayed.destination -TimeoutMilliseconds 6000
    Assert-Move (Test-Path -LiteralPath (Join-Path $delayed.destination 'resources/cage.exe')) 'Delayed-release relocation failed.'
    Assert-Move ($evidence.attempts.Count -gt 1 -and $evidence.attempts[0].nativeError -in @(32, 33)) 'Delayed fixture did not exercise a real sharing violation.'
    $report = Get-Content -LiteralPath $evidence.report -Raw | ConvertFrom-Json
    $lockOwners = @($report.snapshots | ForEach-Object { $_.lockOwners })
    Assert-Move ($delayedHelper.process.Id -in $lockOwners.pid) 'Restart Manager did not identify the actual isolated lock owner.'
    Assert-Move (@($lockOwners | Where-Object { $_.pid -eq $delayedHelper.process.Id -and $_.identityMatched -and $_.parentPid -eq $PID }).Count -gt 0) 'Lock owner creation time/parent identity was not verified.'
    Assert-Move ($unrelatedHelper.process.Id -notin $lockOwners.pid) 'Unrelated lock holder entered the stage-specific lock evidence.'
    Write-Output 'PASS: real sharing violation retries until delayed release; Restart Manager identifies only the target-file holder.'

    $blocked = New-MoveFixture
    $blockedHelper = Start-LockFixture $blocked
    $blockedEvidence = New-WindowsBuildMoveEvidence $blocked.stage
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $caught = $false
    try { Move-WindowsBuildApp $blockedEvidence $blocked.destination -TimeoutMilliseconds 500 -MaximumAttempts 3 }
    catch { $caught = (Get-WindowsBuildNativeError $_.Exception) -in @(32, 33) }
    Assert-Move $caught 'Persistent sharing violation did not fail.'
    Assert-Move ($blockedEvidence.attempts.Count -le 3 -and $clock.ElapsedMilliseconds -lt 5000) 'Persistent sharing conflict exceeded its bounded retry budget.'
    Assert-Move ((Test-Path -LiteralPath $blocked.file) -and -not (Test-Path -LiteralPath $blocked.destination)) 'Failed relocation destroyed or partially moved its source stage.'
    Assert-Move (Test-Path -LiteralPath $blockedEvidence.report) 'Failure evidence was not preserved.'
    Write-Output 'PASS: persistent sharing conflict fails within the bounded retry budget and preserves source and diagnostics.'

    $invalid = New-MoveFixture
    $invalidEvidence = New-WindowsBuildMoveEvidence $invalid.stage
    $missingParentDestination = Join-Path $fixtureRoot 'missing-parent/app'
    $caught = $false
    try { Move-WindowsBuildApp $invalidEvidence $missingParentDestination }
    catch { $caught = (Get-WindowsBuildNativeError $_.Exception) -notin @(32, 33) }
    Assert-Move ($caught -and $invalidEvidence.attempts.Count -eq 1) 'A non-sharing path error was retried or accepted.'
    Assert-Move (Test-Path -LiteralPath $invalid.file) 'Non-sharing error removed the source.'
    Assert-Move ((Get-WindowsBuildNativeError ([IO.IOException]::new('generic error'))) -eq 0) 'Generic IOException was classified as a sharing violation.'
    Assert-Move ((Get-WindowsBuildNativeError ([UnauthorizedAccessException]::new())) -eq 5) 'Access-denied error lost its native identity.'
    Assert-Move (-not $unrelatedHelper.process.HasExited) 'Non-target process was stopped.'
    Write-Output 'PASS: non-sharing failures do not retry; same-name non-target helper remains running.'

    # Exercise the actual error policy with a deterministic 5, without changing
    # the user's ACLs or requiring an administrator account to lose access.
    $originalProbe = (Get-Command Assert-WindowsBuildFileMoveable).ScriptBlock
    try {
        function Assert-WindowsBuildFileMoveable { param([string]$Path); throw [ComponentModel.Win32Exception]::new(5) }
        $denied = New-MoveFixture
        $deniedEvidence = New-WindowsBuildMoveEvidence $denied.stage
        $caught = $false
        try { Move-WindowsBuildApp $deniedEvidence $denied.destination }
        catch { $caught = (Get-WindowsBuildNativeError $_.Exception) -eq 5 }
        Assert-Move ($caught -and $deniedEvidence.attempts.Count -eq 1 -and (Test-Path -LiteralPath $denied.file)) 'Access-denied 5 was retried or changed the source.'
    } finally { Set-Item Function:Assert-WindowsBuildFileMoveable $originalProbe }
    Write-Output 'PASS: injected pure access-denied 5 fails immediately without ACL changes.'

    $processFixture = New-MoveFixture
    Copy-Item -LiteralPath (Join-Path ([Environment]::SystemDirectory) 'cmd.exe') -Destination $processFixture.file -Force
    $processEvidence = New-WindowsBuildMoveEvidence $processFixture.stage
    $start = [Diagnostics.ProcessStartInfo]::new($processFixture.file)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in @('/D', '/C', 'ping.exe -n 4 127.0.0.1 >nul')) { $start.ArgumentList.Add($argument) }
    $ownImage = [Diagnostics.Process]::Start($start)
    try {
        Save-WindowsBuildMoveEvidence $processEvidence 'running_fixture'
        Assert-Move ($ownImage.WaitForExit(5000)) 'Owned process fixture failed to exit naturally.'
        Save-WindowsBuildMoveEvidence $processEvidence 'exited_fixture'
        $running = @($processEvidence.snapshots[0].processes | Where-Object { $_.pid -eq $ownImage.Id })
        $exited = @($processEvidence.snapshots[1].processes | Where-Object { $_.pid -eq $ownImage.Id })
        Assert-Move ($running.Count -eq 1 -and $running[0].parentPid -eq $PID -and $running[0].imagePath -eq $processFixture.file -and $running[0].startUtc -and $running[0].state -eq 'running') 'Exact staged image PID/PPID/start was not captured.'
        Assert-Move ($exited.Count -eq 1 -and $exited[0].state -eq 'exited_since_observed') 'Exited staged image was not retained in evidence.'
    } finally {
        if (-not $ownImage.HasExited) { $ownImage.Kill(); $ownImage.WaitForExit(3000) | Out-Null }
        $ownImage.Dispose()
    }
    Write-Output 'PASS: exact staged image PID/PPID/start captured and later exit retained.'

    $largeFixture = New-MoveFixture
    foreach ($index in 1..130) { [IO.File]::WriteAllText((Join-Path (Split-Path $largeFixture.file -Parent) ("fixture-$index.dll")), 'fixture') }
    $largeEvidence = New-WindowsBuildMoveEvidence $largeFixture.stage
    Assert-Move ($largeEvidence.files.Count -eq 128 -and $largeEvidence.filesTruncated -and $largeFixture.file -in $largeEvidence.files) 'Lock resource query is not capped or excluded the staged executable.'
    Write-Output 'PASS: file query capped at 128 resources with executable priority and explicit truncation.'

    $unsafeRejected = $false
    try { $null = New-WindowsBuildMoveEvidence $fixtureRoot } catch { $unsafeRejected = $true }
    Assert-Move $unsafeRejected 'Broad non-stage path was admitted.'
    Write-Output 'PASS: source stage safety boundary.'
    $passed = $true
} finally {
    foreach ($helper in $helpers) {
        [IO.File]::WriteAllText($helper.release, 'release')
        # Only handles returned by our own Start call may be terminated, and
        # only if the cooperative fixture release failed.
        if (-not $helper.process.WaitForExit(3000)) { $helper.process.Kill(); $helper.process.WaitForExit(3000) | Out-Null }
        $helper.process.Dispose()
    }
    $env:RUNNER_TEMP = $savedRunnerTemp
    if ($passed) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        if ([IO.Path]::GetFileName($resolved) -cnotmatch '^cage-build-move-test-[0-9a-f]{32}$' -or (Split-Path $resolved -Parent) -ne ([IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar))) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { Write-Warning "Failed isolated fixture retained: $fixtureRoot" }
}
