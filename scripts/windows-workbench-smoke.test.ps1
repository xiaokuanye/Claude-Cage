# Cross-platform regression for the real smoke-report and CI artifact contract.
. (Join-Path $PSScriptRoot 'windows-common.ps1')
$directory = Join-Path ([IO.Path]::GetTempPath()) ('cage-smoke-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
$savedRunnerTemp = $env:RUNNER_TEMP
function Assert-SmokeContract([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.github/workflows/windows-build.yml') -Raw
    $publicBlocks = [regex]::Matches($workflow, '(?ms)^      - name: Preserve public (?:test|release acceptance) reports\r?\n.*?^          path: \|\r?\n(?<paths>(?:            [^\r\n]+\r?\n)+)')
    Assert-SmokeContract ($publicBlocks.Count -eq 2) 'Expected development and release public-report artifact blocks.'
    $expectedPublicPaths = @('${{ runner.temp }}/cage-smoke-*.json', '${{ runner.temp }}/cage-build-ui-*/smoke.json', '${{ runner.temp }}/cage-build-diagnostics-*/diagnostics.json')
    foreach ($block in $publicBlocks) {
        $paths = @($block.Groups['paths'].Value -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Assert-SmokeContract ($paths.Count -eq $expectedPublicPaths.Count -and @($paths | Where-Object { $_ -notin $expectedPublicPaths }).Count -eq 0) 'Public artifact paths must use the exact safe allowlist, never private trees or screenshots.'
    }
    $env:RUNNER_TEMP = Join-Path $directory 'runner-temp'
    Assert-SmokeContract ((Get-WindowsWorkbenchTestBase) -eq [IO.Path]::GetFullPath($env:RUNNER_TEMP)) 'CI report directory ignores RUNNER_TEMP.'
    $savedTemp = $env:TEMP; $savedTmp = $env:TMP
    $envFile = Join-Path $directory 'child-env.json'
    $envScript = Join-Path $directory 'child-env.ps1'
    [IO.File]::WriteAllText($envScript, '@{temp=$env:TEMP;tmp=$env:TMP} | ConvertTo-Json | Set-Content -LiteralPath $args[0]')
    $failed = $false
    try {
        Invoke-InIsolatedTestTemp {
            Invoke-BuildTool (Get-Process -Id $PID).Path @('-NoProfile','-NonInteractive','-File',$envScript,$envFile)
            throw 'injected test failure'
        }
    } catch { $failed = $_.Exception.Message -eq 'injected test failure' }
    $childEnv = Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json
    Assert-SmokeContract $failed 'Isolated test temp swallowed its test failure.'
    Assert-SmokeContract ($childEnv.temp -eq $childEnv.tmp -and (Split-Path $childEnv.temp -Parent) -eq $env:RUNNER_TEMP) 'Child tests did not inherit the isolated runner temp.'
    Assert-SmokeContract ($env:TEMP -eq $savedTemp -and $env:TMP -eq $savedTmp) 'Failed tests changed the caller temp environment.'
    Assert-SmokeContract (-not (Test-Path -LiteralPath $childEnv.temp)) 'Owned test temp was not cleaned.'
    Remove-Item Env:RUNNER_TEMP -ErrorAction SilentlyContinue
    Assert-SmokeContract ((Get-WindowsWorkbenchTestBase) -eq [IO.Path]::GetTempPath()) 'Local report directory lost its OS temp fallback.'
    $report = Join-Path $directory 'smoke.json'
    $fixture = Join-Path $directory 'fixture.json'
    $childScript = Join-Path $directory 'child.ps1'
    [IO.File]::WriteAllText($childScript, '[IO.File]::Copy($args[0],$args[1],$true); exit 17')
    @{
        success = $false; nativeBridgeReady = $false; phase = 'loading_workbench'
        prepareExit = 1; prepareStatus = 'stop_required'
        nativeStatus = 'failed http://localhost:1234/?token=private-token#private-fragment'
        entryJSON = 'private-entry'; pageURL = 'http://localhost:1234/#private-launch'
        page = @{ text = 'private-page-body'; errors = @(
            @{ type = 'module-load'; source = '/missing.js?session=private-query#private-fragment' },
            @{ type = 'error'; source = '/main.js'; message = 'syntax error'; stack = @('at http://localhost:1234/main.js?session=private-query#private-fragment') }
        ) }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',$childScript,$fixture,$report)) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    try {
        $child.WaitForExit()
        Assert-SmokeContract ($child.ExitCode -eq 17) 'Failure fixture did not exit unsuccessfully.'
        $failed = $false
        $captured = & {
            try { Assert-WindowsWorkbenchReport -ExitCode $child.ExitCode -Report $report }
            catch { $script:observedFailure = $_.Exception.Message; Write-Output ('Rejected smoke: ' + $_.Exception.Message) }
        } 6>&1
        $text = ($captured | ForEach-Object { $_.ToString() }) -join "`n"
        Assert-SmokeContract ($observedFailure -like '*loading_workbench*') 'Failure report was not parsed before rejecting its process exit.'
        foreach ($expected in @('loading_workbench', 'module-load', '/missing.js', 'syntax error', '"prepareExit":1', '"prepareStatus":"stop_required"')) {
            Assert-SmokeContract ($text.Contains($expected)) "Missing safe smoke evidence: $expected"
        }
        foreach ($private in @('private-token','private-fragment','private-query','private-entry','private-launch','private-page-body')) {
            Assert-SmokeContract (-not $text.Contains($private)) "Private smoke field leaked: $private"
        }
    } finally { $child.Dispose() }
    [IO.File]::WriteAllText($report, '{"success":true,"nativeBridgeReady":true}')
    Assert-WindowsWorkbenchReport -ExitCode 0 -Report $report
    $rejected = $false
    try { Assert-WindowsWorkbenchReport -ExitCode 17 -Report $report } catch { $rejected = $true }
    Assert-SmokeContract $rejected 'Nonzero child exit was accepted because its report said success.'
    $public = Join-Path $directory 'public-smoke.json'
    # Successful smoke must remain available when the later packaging step fails.
    $privateRoot = New-Item -ItemType Directory -Path (Join-Path $directory 'private')
    $privateReport = Join-Path $privateRoot.FullName 'smoke.raw.json'
    [IO.File]::WriteAllText((Join-Path $privateRoot.FullName 'config.json'), '{"token":"private-profile-token"}')
    @{
        success = $true; nativeBridgeReady = $true; phase = 'completed'; prepareExit = 0; prepareStatus = 'prepared'
        nativeStatus = 'Bearer private-bearer-token'; entryJSON = 'private-entry'; pageURL = 'http://localhost/?token=private-url-token'
        errors = @('private-error-token'); page = @{ text = 'private-page-body'; errors = @(@{ message = 'private-js-token' }) }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $privateReport
    Save-WindowsWorkbenchPublicReport -Report $privateReport -Destination $public -ExitCode 0
    Remove-Item -LiteralPath $privateRoot.FullName -Recurse -Force
    $publicText = Get-Content -LiteralPath $public -Raw
    $publicData = $publicText | ConvertFrom-Json
    Assert-SmokeContract ($publicData.success -and $publicData.phase -eq 'completed' -and $publicData.prepareExit -eq 0) 'Successful smoke evidence was lost after private cleanup.'
    Assert-SmokeContract ($publicData.errorCount -eq 1 -and $publicData.pageErrorCount -eq 1) 'Public evidence lost safe diagnostic counts.'
    Assert-SmokeContract (-not $publicText.Contains('private-')) 'Public smoke artifact leaked private values.'
    Assert-SmokeContract (@($publicData.PSObject.Properties.Name | Where-Object { $_ -in @('nativeStatus', 'entryJSON', 'pageURL', 'page', 'errors') }).Count -eq 0) 'Public artifact includes free-text fields.'
    [IO.File]::WriteAllText($report, ('x' * 65537))
    Save-WindowsWorkbenchPublicReport -Report $report -Destination $public -ExitCode 17
    Assert-SmokeContract ((Get-Content $public -Raw | ConvertFrom-Json).reportState -eq 'invalid') 'Oversized raw report escaped the bounded public contract.'
    Remove-Item -LiteralPath $report
    Save-WindowsWorkbenchPublicReport -Report $report -Destination $public -ExitCode -1
    Assert-SmokeContract ((Get-Content $public -Raw | ConvertFrom-Json).reportState -eq 'missing') 'Missing smoke report has no public diagnostic.'
    Write-Output 'PASS: RUNNER_TEMP/local selection, real failed child with existing diagnostic, safe evidence logging, and success/exit contract.'
    Write-Output 'PASS: successful public smoke survives private cleanup; profile, tokens and free text omitted; oversized/missing reports remain bounded.'
    Write-Output 'PASS: development/release artifact paths use the identical public JSON allowlist, without private trees or PNG globs.'
} finally {
    $env:RUNNER_TEMP = $savedRunnerTemp
    Remove-Item -LiteralPath $directory -Recurse
}
