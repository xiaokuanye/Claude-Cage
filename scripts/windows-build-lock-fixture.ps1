# Test-only helper. Opens one owned fixture file without delete sharing.
# It never launches or terminates another process.
#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$Ready,
    [Parameter(Mandatory)][string]$Release,
    [ValidateRange(0, 15000)][int]$ReleaseAfterMilliseconds = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ([IO.Path]::GetFileName($rootPath) -cnotmatch '^cage-build-move-test-[0-9a-f]{32}$') { throw 'Not an owned lock fixture root.' }
foreach ($path in @($Target, $Ready, $Release)) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Lock fixture path escapes its root.' }
    $parent = Get-Item -LiteralPath (Split-Path $full -Parent) -Force
    while ($parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Lock fixture cannot use reparse points.' }
        $parent = $parent.Parent
    }
    if ((Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Lock fixture cannot use reparse points.' }
}
$stream = [IO.File]::Open($Target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    [IO.File]::WriteAllText($Ready, 'ready')
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Release) -and $elapsed.ElapsedMilliseconds -lt 15000) {
        if ($ReleaseAfterMilliseconds -gt 0 -and $elapsed.ElapsedMilliseconds -ge $ReleaseAfterMilliseconds) { break }
        Start-Sleep -Milliseconds 20
    }
} finally { $stream.Dispose() }
