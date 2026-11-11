#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Sign,
    [switch]$SkipUI,
    [string]$OutputDirectory,
    [string]$DependencyCache
)
. (Join-Path $PSScriptRoot 'windows-common.ps1')
. (Join-Path $PSScriptRoot 'windows-build-move.ps1')
$repository = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository '_output/windows-amd64/app' }
if (-not $DependencyCache) { $DependencyCache = Join-Path $repository '_output/windows-deps' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'Uninstall.exe')) { throw 'Do not build over an installed application. Choose a separate output directory and use the installer to upgrade.' }
$version = Get-CageVersion $repository
$signed = $Release -or $Sign
if ($signed) { Assert-WindowsSigningConfiguration }
$go = Get-BuildCommand @('go')
$dotnet = Get-BuildCommand @('dotnet')
$node = Get-BuildCommand @('node')
$npm = Get-BuildCommand @('npm.cmd', 'npm')
$sevenZip = Get-BuildCommand @('7z.exe', '7zz', '7z')
$dependencies = Get-Content -LiteralPath (Join-Path $repository 'packaging/windows/dependencies.json') -Raw | ConvertFrom-Json
$stage = Join-Path $repository ("_output/windows-build-" + [guid]::NewGuid().ToString('N'))
$savedGoOS, $savedGoArch, $savedCGO = $env:GOOS, $env:GOARCH, $env:CGO_ENABLED
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$buildCompleted = $false
$moveEvidence = $null
Push-Location $repository
try {
    if (-not $SkipUI) {
        Invoke-BuildTool $npm @('--prefix', 'ui', 'ci', '--no-audit', '--no-fund')
        Invoke-BuildTool $npm @('run', '--prefix', 'ui', 'build')
    } else {
        Invoke-BuildTool $node @('ui/scripts/verify-build.mjs')
    }
    $limaVersion = (Get-Content 'internal/limaembed/lima-version' -Raw).Trim()
    $assets = Join-Path $repository 'internal/limaembed/assets'
    $guest = Join-Path $assets 'lima-guestagent.Linux-x86_64'
    $env:GOOS = 'linux'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
    Invoke-BuildTool $go @('build', '-trimpath', '-ldflags', "-s -w -X github.com/lima-vm/lima/v2/pkg/version.Version=$limaVersion", '-o', $guest, 'github.com/lima-vm/lima/v2/cmd/lima-guestagent')
    $inputStream = [IO.File]::OpenRead($guest)
    $outputStream = [IO.File]::Create("$guest.gz")
    try {
        $gzip = [IO.Compression.GZipStream]::new($outputStream, [IO.Compression.CompressionLevel]::SmallestSize, $true)
        try { $inputStream.CopyTo($gzip) } finally { $gzip.Dispose() }
    } finally { $inputStream.Dispose(); $outputStream.Dispose() }
    Remove-Item -LiteralPath $guest
    New-Item -ItemType Directory -Path (Join-Path $assets 'templates') -Force | Out-Null
    Copy-Item 'third_party/lima/templates/*' (Join-Path $assets 'templates') -Recurse -Force
    $app = Join-Path $stage 'app'
    $resources = Join-Path $app 'resources'
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resources 'runtime') -Force | Out-Null
    $guestSetup = New-Item -ItemType Directory -Path (Join-Path $resources 'guest-os')
    Copy-Item -LiteralPath 'scripts/guest-os/new-windows-test-vm.ps1' -Destination (Join-Path $guestSetup.FullName 'new-windows-guest.ps1')
    Copy-Item -LiteralPath 'scripts/guest-os/windows-host-image.ps1' -Destination $guestSetup.FullName
    foreach ($file in @('windows-guest-media.ps1', 'install-guest-powershell.cmd', 'setup-windows-guest.ps1', 'complete-windows-guest.ps1', 'install-windows-host-manager.ps1', 'install-windows-workbench-components.ps1', 'initialize-windows-workbench-user.ps1', 'windows-host-enrollment.ps1', 'maintain-windows-workbench.ps1', 'update-windows-workbench-components.ps1', 'publish-windows-component-manifest.ps1', 'windows-workbench-packages.ps1')) {
        Copy-Item -LiteralPath (Join-Path 'scripts/guest-os' $file) -Destination $guestSetup.FullName
    }
    $bridgeSetup = New-Item -ItemType Directory -Path (Join-Path $guestSetup.FullName 'guest-clipboard-windows')
    foreach ($file in @('install.ps1', 'install-network.ps1')) {
        Copy-Item -LiteralPath (Join-Path 'scripts/guest-os/guest-clipboard-windows' $file) -Destination $bridgeSetup.FullName
    }
    & (Join-Path $PSScriptRoot 'guest-os/build-windows-workbench-payload.ps1') -Destination (Join-Path $guestSetup.FullName 'payload')
    $tailnetAssets = Join-Path $repository 'internal/tailnetassets/assets'
    New-Item -ItemType Directory -Path $tailnetAssets -Force | Out-Null
    foreach ($tailnetArch in @('amd64','arm64')) {
        $env:GOOS = 'linux'; $env:GOARCH = $tailnetArch; $env:CGO_ENABLED = '0'
        $tailnetOutput = Join-Path $stage ('cage-tailnet-linux-'+$tailnetArch)
        Push-Location (Join-Path $repository 'tools/tailnet')
        try { Invoke-BuildTool $go @('build','-trimpath','-ldflags','-s -w','-o',$tailnetOutput,'.') } finally { Pop-Location }
        $source = [IO.File]::OpenRead($tailnetOutput)
        $target = [IO.File]::Create((Join-Path $tailnetAssets ('cage-tailnet-linux-'+$tailnetArch+'.gz')))
        try { $compressed = [IO.Compression.GZipStream]::new($target,[IO.Compression.CompressionMode]::Compress); try { $source.CopyTo($compressed) } finally { $compressed.Dispose() } } finally { $source.Dispose(); $target.Dispose() }
    }
    $env:GOARCH = 'amd64'
    $env:GOOS = 'windows'
    $tags = 'external_hcs,external_wsl2,yq_noxml,yq_nolua,yq_noini,yq_nohcl,yq_notoml,yq_noprops,yq_nocsv,yq_nouri,yq_nobase64,yq_nosh,yq_noshell'
    $ldflags = "-s -w -X github.com/sylvinus/agent-vm/internal/version.Version=$version -X github.com/lima-vm/lima/v2/pkg/version.Version=$limaVersion"
    Invoke-BuildTool $go @('build', '-trimpath', '-tags', $tags, '-ldflags', $ldflags, '-o', (Join-Path $resources 'cage.exe'), './cmd/cage')
    Invoke-BuildTool (Join-Path $resources 'cage.exe') @('verify-vm-assets')
    Invoke-BuildTool (Join-Path $resources 'cage.exe') @('verify-web-assets')
    Invoke-BuildTool $dotnet @('publish', 'desktop/windows/Cage.Windows.csproj', '-c', 'Release', '-r', 'win-x64', '--self-contained', 'true',
        '-p:EnableWindowsTargeting=true', '-p:PublishSingleFile=true', '-p:RestoreLockedMode=true', "-p:Version=$version", "-p:InformationalVersion=$version", '-o', $app)
    Get-ChildItem -LiteralPath $app -File | Where-Object { $_.Extension -in @('.pdb', '.xml') } | Remove-Item -Force
    node scripts/bundle-cloud-kit.mjs $resources
    if ($LASTEXITCODE -ne 0) { throw "Cloud deployment kit verification failed." }
    $coreArchive = Get-VerifiedDependency $dependencies.mihomo $DependencyCache
    $core = Join-Path $stage 'mihomo'
    Expand-BuildArchive $coreArchive $core $sevenZip
    $coreExe = @(Get-ChildItem -LiteralPath $core -Filter '*.exe' -Recurse)
    if ($coreExe.Count -ne 1) { throw 'Unexpected Mihomo archive layout.' }
    Copy-Item -LiteralPath $coreExe[0].FullName -Destination (Join-Path $resources 'mihomo.exe')
    $sshArchive = Get-VerifiedDependency $dependencies.openssh $DependencyCache
    $ssh = Join-Path $stage 'openssh'
    Expand-BuildArchive $sshArchive $ssh $sevenZip
    $sshTarget = Join-Path $resources 'runtime/openssh'
    Copy-Item -LiteralPath (Join-Path $ssh 'OpenSSH-Win64') -Destination $sshTarget -Recurse
    # No SSH service is installed. Only the client is used by Cage/Lima.
    foreach ($serverFile in @('sshd.exe', 'sshd-session.exe', 'sshd-auth.exe', 'install-sshd.ps1', 'uninstall-sshd.ps1')) {
        Remove-Item -LiteralPath (Join-Path $sshTarget $serverFile) -Force -ErrorAction SilentlyContinue
    }
    $qemuArchive = Get-VerifiedDependency $dependencies.qemu $DependencyCache
    $qemuTarget = Join-Path $resources 'runtime/qemu'
    Expand-BuildArchive $qemuArchive $qemuTarget $sevenZip
    $qemuBuilt = Join-Path $DependencyCache 'qemu-cage'
    & (Join-Path $PSScriptRoot 'build-qemu-windows.ps1') -DependencyCache $DependencyCache -OutputDirectory $qemuBuilt
    $runtimeManifest = Get-Content (Join-Path $qemuBuilt 'cage-build.json') -Raw | ConvertFrom-Json
    $ownedRuntime = @($runtimeManifest.files | ForEach-Object { $_.name }) + @('cage-build.json')
    foreach ($name in $ownedRuntime) {
        if ([IO.Path]::GetFileName($name) -ne $name) { throw 'Invalid QEMU runtime manifest path.' }
        Copy-Item -LiteralPath (Join-Path $qemuBuilt $name) -Destination $qemuTarget -Force
    }
    # The two executables above are linked against the built dependency closure.
    # Vendor DLLs/executables outside that closure have no runtime consumer.
    Get-ChildItem -LiteralPath $qemuTarget -File | Where-Object {
        $_.Extension -in @('.exe', '.dll') -and $_.Name -notin $ownedRuntime
    } | Remove-Item -Force
    # Ship the x64 VM only, with its original firmware, DLLs and notices.
    Get-ChildItem -LiteralPath $qemuTarget -Filter 'qemu-system-*.exe' | Where-Object { $_.Name -ne 'qemu-system-x86_64.exe' } | Remove-Item -Force
    Get-ChildItem -LiteralPath (Join-Path $qemuTarget 'share') -File |
        Where-Object { $_.Name -match '^edk2-(?:aarch64|arm|loongarch64|riscv)-.*\.fd$' } | Remove-Item -Force
    foreach ($file in @('qemu-system-x86_64.exe', 'qemu-img.exe', 'share/efi-virtio.rom', 'share/kvmvapic.bin')) {
        if (-not (Test-Path -LiteralPath (Join-Path $qemuTarget $file))) { throw "QEMU archive lacks $file" }
    }
    $firmwareDirectories = & (Join-Path $qemuTarget 'qemu-system-x86_64.exe') '-L' 'help'
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect QEMU firmware directories.' }
    $bundledFirmware = [IO.Path]::GetFullPath((Join-Path $qemuTarget 'share')).TrimEnd('\', '/')
    if (-not @($firmwareDirectories | Where-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') -eq $bundledFirmware }).Count) {
        throw 'QEMU cannot locate its bundled firmware after relocation.'
    }
    Remove-Item -LiteralPath (Join-Path $qemuTarget '$PLUGINSDIR') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $qemuTarget 'qemu-uninstall.exe') -Force -ErrorAction SilentlyContinue
    $webviewArchive = Get-VerifiedDependency $dependencies.webview2 $DependencyCache
    Copy-Item -LiteralPath $webviewArchive -Destination (Join-Path $resources 'runtime/MicrosoftEdgeWebView2RuntimeInstallerX64.exe')
    Invoke-BuildTool $node @('scripts/collect-app-licenses.mjs', (Join-Path $resources 'licenses'))
    $coreSourceArchive = Get-VerifiedDependency $dependencies.mihomoSource $DependencyCache
    $coreSource = Join-Path $stage 'mihomo-source'
    Expand-BuildArchive $coreSourceArchive $coreSource $sevenZip
    $coreTar = @(Get-ChildItem -LiteralPath $coreSource -Filter '*.tar')
    if ($coreTar.Count -ne 1) { throw 'Unexpected Mihomo source archive layout.' }
    Expand-BuildArchive $coreTar[0].FullName $coreSource $sevenZip
    $coreLicense = Join-Path $coreSource ("mihomo-" + $dependencies.mihomo.version.TrimStart('v') + '/LICENSE')
    if (-not (Test-Path -LiteralPath $coreLicense -PathType Leaf)) { throw 'Mihomo source license is missing.' }
    $coreNotices = Join-Path $resources 'licenses/mihomo'
    New-Item -ItemType Directory -Path $coreNotices -Force | Out-Null
    Copy-Item -LiteralPath $coreLicense -Destination (Join-Path $coreNotices 'LICENSE')
    [IO.File]::WriteAllText((Join-Path $coreNotices 'NOTICE'), "Mihomo $($dependencies.mihomo.version), unmodified separate executable.`nSource: $($dependencies.mihomo.source)`nLicense: GPL-3.0; corresponding source accompanies the installer.`n")
    # Runtime packs and WebView2 are absent from the frontend license collector.
    $resolvedAssets = Get-Content -LiteralPath 'desktop/windows/obj/project.assets.json' -Raw | ConvertFrom-Json
    $nuget = @($resolvedAssets.packageFolders.PSObject.Properties.Name)[0]
    $runtimeVersion = $dependencies.dotnet.runtimeVersion
    $runtimePacks = @($resolvedAssets.project.frameworks.PSObject.Properties.Value.downloadDependencies |
        Where-Object { $_.name -in @('Microsoft.NETCore.App.Runtime.win-x64', 'Microsoft.WindowsDesktop.App.Runtime.win-x64') })
    if ($runtimePacks.Count -ne 2 -or @($runtimePacks | Where-Object { $_.version -ne "[$runtimeVersion, $runtimeVersion]" }).Count -ne 0) {
        throw 'Resolved .NET runtime differs from packaging/windows/dependencies.json. Use SDK 10.0.403 or review and update the runtime pin.'
    }
    $webviewVersion = ((Get-Content -LiteralPath 'desktop/windows/packages.lock.json' -Raw | ConvertFrom-Json).dependencies.PSObject.Properties.Value |
        ForEach-Object { $_.PSObject.Properties } | Where-Object { $_.Name -eq 'Microsoft.Web.WebView2' } | Select-Object -First 1).Value.resolved
    foreach ($package in @("microsoft.netcore.app.runtime.win-x64/$runtimeVersion", "microsoft.windowsdesktop.app.runtime.win-x64/$runtimeVersion", "microsoft.web.webview2/$webviewVersion")) {
        $source = Join-Path $nuget $package
        $target = Join-Path $resources "licenses/nuget/$package"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $notices = @(Get-ChildItem -LiteralPath $source -File | Where-Object { $_.Name -match '^(LICENSE|NOTICE|THIRD.?PARTY)' })
        if ($notices.Count -eq 0) { throw "Missing runtime license: $package" }
        $notices | Copy-Item -Destination $target
    }
    Copy-Item -LiteralPath 'packaging/windows/dependencies.json' -Destination (Join-Path $resources 'dependencies.json')
    Copy-Item -LiteralPath 'packaging/windows/README.txt' -Destination (Join-Path $app 'README.txt')
    Copy-Item -LiteralPath 'LICENSE' -Destination (Join-Path $app 'LICENSE.txt')
    [IO.File]::WriteAllText((Join-Path $app 'Cage.install-id'), 'io.github.lee-xeo.claude-cage')
    [IO.File]::WriteAllText((Join-Path $app 'version.txt'), $version)
    if ($signed) {
        $signTool = Get-SigningTool
        foreach ($file in @('Cage.exe', 'resources/cage.exe', 'resources/mihomo.exe')) { Sign-CageFile (Join-Path $app $file) $signTool }
    } else {
        [IO.File]::WriteAllText((Join-Path $app 'DEVELOPMENT-BUILD.txt'), "Unsigned development build. Automatic update installation is disabled. Windows 10/11 runtime acceptance is still required.`n")
    }
    $moveEvidence = New-WindowsBuildMoveEvidence -StageDirectory $stage
    Assert-WindowsWorkbench $app
    $previousOutput = $null
    if (Test-Path -LiteralPath $OutputDirectory) {
        $marker = Join-Path $OutputDirectory 'Cage.install-id'
        if (-not (Test-Path -LiteralPath $marker) -or (Get-Content -LiteralPath $marker -Raw) -ne 'io.github.lee-xeo.claude-cage') {
            throw 'Output directory exists and is not a Cage build.'
        }
        $previousOutput = $OutputDirectory + '.previous-' + [guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $OutputDirectory -Destination $previousOutput
    }
    New-Item -ItemType Directory -Path (Split-Path $OutputDirectory -Parent) -Force | Out-Null
    try { Move-WindowsBuildApp -Evidence $moveEvidence -Destination $OutputDirectory }
    catch {
        if ($previousOutput -and -not (Test-Path -LiteralPath $OutputDirectory)) { Move-Item -LiteralPath $previousOutput -Destination $OutputDirectory }
        throw
    }
    if ($previousOutput) { Remove-Item -LiteralPath $previousOutput -Recurse -Force }
    $buildCompleted = $true
    Write-Host "Built Windows x64 application: $OutputDirectory"
} catch {
    if ($moveEvidence) { Save-WindowsBuildMoveEvidence $moveEvidence 'build_failed' }
    Write-Warning "Failed build stage retained locally: $stage. Do not upload the stage or private smoke profiles."
    throw
} finally {
    Pop-Location
    $env:GOOS = $savedGoOS; $env:GOARCH = $savedGoArch; $env:CGO_ENABLED = $savedCGO
    if ($buildCompleted -and (Test-Path -LiteralPath $stage)) {
        try { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Temporary build files remain at $stage. Cleanup did not complete: $($_.Exception.Message)" }
    }
}
