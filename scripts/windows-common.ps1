# Shared build helpers. PowerShell 7 runs these scripts on Windows, macOS and Linux.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-BuildTool {
    param([string]$Tool, [string[]]$Arguments)
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed with exit code $LASTEXITCODE" }
}

function Get-WindowsWorkbenchTestBase {
    if ($env:RUNNER_TEMP) { return [IO.Path]::GetFullPath($env:RUNNER_TEMP) }
    return [IO.Path]::GetTempPath()
}

function Invoke-InIsolatedTestTemp {
    param([Parameter(Mandatory)][scriptblock]$Checks)
    # Windows' default temp is inside AppData, which must remain protected
    # against project sharing. Put test projects in the runner's own temp.
    $directory = Join-Path (Get-WindowsWorkbenchTestBase) ('cage-go-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    $savedTemp = $env:TEMP; $savedTmp = $env:TMP
    try {
        $env:TEMP = $directory; $env:TMP = $directory
        & $Checks
    } finally {
        $env:TEMP = $savedTemp; $env:TMP = $savedTmp
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-SmokeSafeText {
    param($Value)
    if ($Value -isnot [string]) { return '' }
    $text = [regex]::Replace($Value, 'https?://[^\s"''<>]+', {
        param($match)
        try { return ([Uri]$match.Value).GetLeftPart([UriPartial]::Path) }
        catch { return '[URL omitted]' }
    })
    $text = $text -replace '[?#][^\s"''<>)]*', '[redacted]'
    return $text.Substring(0, [Math]::Min(768, $text.Length))
}

function Assert-WindowsWorkbenchReport {
    param([int]$ExitCode, [string]$Report)
    if (-not (Test-Path -LiteralPath $Report -PathType Leaf)) { throw "Cage workbench acceptance failed ($ExitCode). No smoke report: $Report" }
    if ((Get-Item -LiteralPath $Report).Length -gt 65536) { throw 'Cage smoke report exceeds the bounded diagnostic size.' }
    $result = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json -AsHashtable
    $safe = @{ phase = ConvertTo-SmokeSafeText $result['phase']; nativeStatus = ConvertTo-SmokeSafeText $result['nativeStatus']; jsErrors = @() }
    if ($result['prepareExit'] -is [int] -or $result['prepareExit'] -is [long]) { $safe.prepareExit = $result['prepareExit'] }
    if ($result['prepareStatus'] -in @('prepared', 'stop_required', 'error', 'unexpected')) { $safe.prepareStatus = $result['prepareStatus'] }
    if ($result['page'] -is [System.Collections.IDictionary] -and $result['page']['errors']) {
        $safe.jsErrors = @($result['page']['errors'] | Select-Object -First 8 | ForEach-Object {
            if ($_ -isnot [System.Collections.IDictionary]) { return }
            @{
                type = ConvertTo-SmokeSafeText $_['type']
                source = if ($_['source'] -is [string] -and $_['source'].StartsWith('/')) { ConvertTo-SmokeSafeText $_['source'] } else { '' }
                message = ConvertTo-SmokeSafeText $_['message']
                stack = @($_['stack'] | Select-Object -First 6 | ForEach-Object { ConvertTo-SmokeSafeText $_ })
            }
        })
    }
    # Log only these already-bounded fields, even when the process failed. Do
    # not print launch entries, page URLs, account data or the raw report.
    Write-Host ('Cage smoke diagnostic: ' + ($safe | ConvertTo-Json -Depth 6 -Compress))
    if ($ExitCode -ne 0 -or $result['success'] -ne $true -or $result['nativeBridgeReady'] -ne $true) {
        throw "Cage workbench/bridge acceptance failed ($ExitCode), phase $($safe.phase): $($safe.nativeStatus). Diagnostics: $Report"
    }
}

function Save-WindowsWorkbenchPublicReport {
    param([string]$Report, [string]$Destination, [int]$ExitCode = -1, $ProcessIdentity)
    # An allowlist, not a copy of the raw report. Free text, screenshots, URLs,
    # profile/configuration and helper output must never enter CI artifacts.
    $public = [ordered]@{ schema = 1; exitCode = $ExitCode; reportState = 'missing'; success = $false; nativeBridgeReady = $false }
    if (Test-Path -LiteralPath $Report -PathType Leaf) {
        $public.reportState = 'invalid'
        try {
            if ((Get-Item -LiteralPath $Report).Length -gt 65536) { throw 'Oversized report' }
            $raw = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json -AsHashtable
            if ($raw -isnot [System.Collections.IDictionary]) { throw 'Invalid report' }
            $public.reportState = 'parsed'
            $public.success = $raw['success'] -eq $true
            $public.nativeBridgeReady = $raw['nativeBridgeReady'] -eq $true
            $phases = @('starting', 'initializing_webview', 'webview_initialized', 'starting_backend', 'backend_returned', 'loading_workbench', 'stopping_backend', 'stopping_browser', 'completed')
            $public.phase = if ($raw['phase'] -in $phases) { $raw['phase'] } else { 'unknown' }
            if ($raw['prepareExit'] -is [int] -or $raw['prepareExit'] -is [long]) { $public.prepareExit = $raw['prepareExit'] }
            if ($raw['prepareStatus'] -in @('prepared', 'stop_required', 'error', 'unexpected')) { $public.prepareStatus = $raw['prepareStatus'] }
            $public.errorCount = @($raw['errors'] | Where-Object { $null -ne $_ }).Count
            # Empty on successful smoke does not establish full JS coverage.
            $public.pageErrorsCaptured = $raw['page'] -is [System.Collections.IDictionary]
            if ($public.pageErrorsCaptured) { $public.pageErrorCount = @($raw['page']['errors'] | Where-Object { $null -ne $_ }).Count }
        } catch { $public.reportState = 'invalid' }
    }
    if ($ProcessIdentity) { $public.process = $ProcessIdentity }
    [IO.File]::WriteAllText($Destination, ($public | ConvertTo-Json -Depth 4))
}

function Assert-WindowsWorkbench {
    param([Parameter(Mandatory)][string]$AppDirectory)
    if (-not $IsWindows) { throw 'Workbench acceptance requires Windows.' }
    $testRoot = Join-Path (Get-WindowsWorkbenchTestBase) ('cage-build-ui-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $privateRoot = Join-Path $testRoot 'private'
    New-Item -ItemType Directory -Path $privateRoot | Out-Null
    $report = Join-Path $privateRoot 'smoke.raw.json'
    $publicReport = Join-Path $testRoot 'smoke.json'
    Save-WindowsWorkbenchPublicReport -Report $report -Destination $publicReport
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $AppDirectory 'Cage.exe'))
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $AppDirectory
    $start.Environment['CLAUDE_CAGE_CONFIG'] = Join-Path $privateRoot 'profile/config.json'
    $start.ArgumentList.Add('--smoke-test')
    $start.ArgumentList.Add($report)
    $window = $null
    $processIdentity = $null
    $exitCode = -1
    $passed = $false
    try {
        $window = [Diagnostics.Process]::Start($start)
        $processIdentity = @{ pid = $window.Id; parentPid = $PID; startUtc = $window.StartTime.ToUniversalTime().ToString('o'); imagePath = $start.FileName; exited = $false }
        if (-not $window.WaitForExit(180000)) { throw "Cage workbench acceptance timed out. Diagnostics retained at $testRoot" }
        $exitCode = $window.ExitCode
        Assert-WindowsWorkbenchReport -ExitCode $window.ExitCode -Report $report
        $passed = $true
    } finally {
        if ($window) {
            if (-not $window.HasExited) { $window.Kill($true); $window.WaitForExit() }
            if ($processIdentity) { $processIdentity.exited = $window.HasExited }
            $window.Dispose()
        }
        Save-WindowsWorkbenchPublicReport -Report $report -Destination $publicReport -ExitCode $exitCode -ProcessIdentity $processIdentity
        if (-not $passed) {
            # Close only this test's authenticated controller. Killing every
            # cage.exe could terminate another installed application or VM.
            try {
                $cleanup = [Diagnostics.ProcessStartInfo]::new((Join-Path $AppDirectory 'resources/cage.exe'))
                $cleanup.UseShellExecute = $false
                $cleanup.CreateNoWindow = $true
                $cleanup.RedirectStandardOutput = $true
                $cleanup.RedirectStandardError = $true
                $cleanup.Environment['CLAUDE_CAGE_CONFIG'] = Join-Path $privateRoot 'profile/config.json'
                $cleanup.ArgumentList.Add('prepare-update'); $cleanup.ArgumentList.Add('--json')
                $controller = [Diagnostics.Process]::Start($cleanup)
                try {
                    $stdout = $controller.StandardOutput.ReadToEndAsync()
                    $stderr = $controller.StandardError.ReadToEndAsync()
                    if (-not $controller.WaitForExit(20000)) { $controller.Kill($true); $controller.WaitForExit() }
                    if ($controller.ExitCode -ne 0) { Write-Warning 'The isolated smoke controller did not confirm shutdown; its profile is retained.' }
                } finally { $controller.Dispose() }
            } catch { Write-Warning "Isolated smoke cleanup failed: $($_.Exception.Message)" }
        }
        # Keep the public bounded smoke report through the complete build/job,
        # including a later relocation failure. Private failures stay local.
        if ($passed) { Remove-Item -LiteralPath $privateRoot -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "Public workbench report retained: $publicReport"
    }
}

function Get-CageVersion {
    param([string]$Repository)
    $value = (Get-Content -LiteralPath (Join-Path $Repository 'VERSION') -Raw).Trim()
    if ($value -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Invalid VERSION.' }
    return $value
}

function Get-BuildCommand {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw "Missing build tool: $($Names -join ' or ')"
}

function Get-VerifiedDependency {
    param($Dependency, [string]$Cache)
    if ($Dependency.url -notlike 'https://*') { throw 'Build dependencies must use HTTPS.' }
    $path = Join-Path $Cache $Dependency.file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-Item -ItemType Directory -Path $Cache -Force | Out-Null
        $partial = "$path.partial"
        try {
            Invoke-WebRequest -Uri $Dependency.url -OutFile $partial -TimeoutSec 900 -MaximumRedirection 5
            Move-Item -LiteralPath $partial -Destination $path -Force
        } finally {
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        }
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm $Dependency.algorithm).Hash
    if ($actual -ne $Dependency.hash) { throw "Dependency checksum mismatch: $($Dependency.file). Remove the cached file and retry." }
    return $path
}

function Expand-BuildArchive {
    param([string]$Archive, [string]$Destination, [string]$SevenZip)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Invoke-BuildTool $SevenZip @('x', '-y', '-bso0', '-bsp0', "-o$Destination", $Archive)
}

function Get-VerifiedGitArchive {
    param($Dependency, [string]$Cache)
    $archive = Join-Path $Cache $Dependency.file
    if (-not (Test-Path -LiteralPath $archive)) {
        $git = Get-BuildCommand @('git.exe', 'git')
        $checkout = Join-Path $Cache ('source-' + [guid]::NewGuid().ToString('N'))
        $partial = "$archive.partial"
        try {
            Invoke-BuildTool $git @('init', '--bare', '--quiet', $checkout)
            Invoke-BuildTool $git @('--git-dir', $checkout, 'fetch', '--depth=1', $Dependency.repository, $Dependency.commit)
            $actualCommit = & $git '--git-dir' $checkout 'rev-parse' 'FETCH_HEAD'
            if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $Dependency.commit) { throw 'Fetched source commit does not match the pinned QEMU build.' }
            # Git for Windows defaults can change archive bytes. Keep the
            # pinned source identical to the reviewed POSIX-generated archive.
            Invoke-BuildTool $git @('--git-dir', $checkout, '-c', 'core.autocrlf=false', '-c', 'tar.umask=0002', 'archive', '--format=tar', "--prefix=$($Dependency.prefix)", "--output=$partial", $Dependency.commit)
            $actualHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actualHash -ne $Dependency.hash) { throw "Source archive checksum mismatch: $($Dependency.file); expected $($Dependency.hash), actual $actualHash" }
            Move-Item -LiteralPath $partial -Destination $archive
        } finally {
            Remove-Item -LiteralPath $checkout -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Dependency.hash) { throw "Source archive checksum mismatch: $($Dependency.file); expected $($Dependency.hash), actual $actualHash. Remove the cached file and retry." }
    return $archive
}

function Get-SigningTool {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    if ($IsWindows) {
        $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
        $candidate = Get-ChildItem -LiteralPath $kits -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'x64/signtool.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    throw 'Release signing requires Windows SDK signtool.exe on Windows.'
}

function Assert-WindowsSigningConfiguration {
    if (-not $IsWindows) { throw 'Trusted Windows build verification requires Windows.' }
    $null = Get-SigningTool
    if ($env:CAGE_WINDOWS_SIGNING_PROVIDER -eq 'esigner') {
        if ($env:CAGE_ESIGNER_CREDENTIAL_ID -notmatch '^[0-9A-Fa-f-]{36}$' -or
            $env:CAGE_ESIGNER_CERTIFICATE_SERIAL -notmatch '^[0-9A-Fa-f]{32,40}$') {
            throw 'eSigner requires CAGE_ESIGNER_CREDENTIAL_ID and the expected CAGE_ESIGNER_CERTIFICATE_SERIAL.'
        }
    } elseif ($env:CAGE_WINDOWS_SIGNING_PROVIDER -and $env:CAGE_WINDOWS_SIGNING_PROVIDER -ne 'certificate-store') {
        throw 'Unknown CAGE_WINDOWS_SIGNING_PROVIDER; use esigner or certificate-store.'
    } elseif ($env:CAGE_WINDOWS_CERT_SHA1 -notmatch '^[0-9A-Fa-f]{40}$') {
        throw 'Certificate-store signing requires CAGE_WINDOWS_CERT_SHA1.'
    }
}

function Sign-CageFile {
    param([string]$Path, [string]$SignTool)
    Assert-WindowsSigningConfiguration
    if ($env:CAGE_WINDOWS_SIGNING_PROVIDER -eq 'esigner') {
        $Path = [IO.Path]::GetFullPath($Path)
        $stage = Join-Path ([IO.Path]::GetTempPath()) ('cage-signed-' + [guid]::NewGuid().ToString('N'))
        try {
            Invoke-BuildTool (Get-BuildCommand @('node.exe', 'node')) @((Join-Path $PSScriptRoot 'esigner.mjs'), 'sign', $Path, '--output-dir', $stage)
            $signed = Join-Path $stage ([IO.Path]::GetFileName($Path))
            Invoke-BuildTool $SignTool @('verify', '/pa', '/all', '/tw', $signed)
            $signature = Get-AuthenticodeSignature -LiteralPath $signed
            if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or
                $signature.SignerCertificate.SerialNumber -ne $env:CAGE_ESIGNER_CERTIFICATE_SERIAL -or
                ($env:CAGE_WINDOWS_CERT_SHA1 -and $signature.SignerCertificate.Thumbprint -ne $env:CAGE_WINDOWS_CERT_SHA1)) {
                throw 'eSigner output lacks the expected trusted publisher certificate or timestamp. Original file retained.'
            }
            $env:CAGE_WINDOWS_CERT_SHA1 = $signature.SignerCertificate.Thumbprint
            Copy-Item -LiteralPath $signed -Destination $Path -Force
        } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
    } else {
        Invoke-BuildTool $SignTool @('sign', '/sha1', $env:CAGE_WINDOWS_CERT_SHA1, '/fd', 'SHA256',
            '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256', '/d', 'Cage', $Path)
        Invoke-BuildTool $SignTool @('verify', '/pa', '/all', $Path)
    }
}
