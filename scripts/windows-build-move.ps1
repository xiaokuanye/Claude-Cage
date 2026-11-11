# Build-only relocation diagnostics. Never stops processes or restarts services.
Set-StrictMode -Version Latest

function Initialize-WindowsBuildLockQuery {
    if ('CageBuild.RestartManager' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace CageBuild {
    public sealed class LockOwner { public int Pid; public long StartFileTime; }
    public sealed class LockQuery { public uint Error; public LockOwner[] Owners = Array.Empty<LockOwner>(); }
    public static class RestartManager {
        [StructLayout(LayoutKind.Sequential)] struct UniqueProcess { public int Pid; public System.Runtime.InteropServices.ComTypes.FILETIME Start; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct ProcessInfo {
            public UniqueProcess Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceName;
            public int AppType; public uint AppStatus; public uint SessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
        }
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern uint RmStartSession(out uint session, uint flags, StringBuilder key);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern uint RmRegisterResources(uint session, uint count, string[] files, uint apps, IntPtr processes, uint services, IntPtr names);
        [DllImport("rstrtmgr.dll")] static extern uint RmGetList(uint session, out uint needed, ref uint count, [In, Out] ProcessInfo[] info, ref uint reasons);
        [DllImport("rstrtmgr.dll")] static extern uint RmEndSession(uint session);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern SafeFileHandle CreateFile(string file, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        public static int DeleteSharingError(string file) {
            // Request DELETE access to test rename sharing, but never mark the
            // file for deletion. Closing this handle cannot change its data.
            using (var handle = CreateFile(file, 0x10000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                return handle.IsInvalid ? Marshal.GetLastWin32Error() : 0;
            }
        }
        public static LockQuery Query(string[] files) {
            var result = new LockQuery();
            if (files.Length == 0) return result;
            uint session;
            result.Error = RmStartSession(out session, 0, new StringBuilder(33));
            if (result.Error != 0) return result;
            try {
                result.Error = RmRegisterResources(session, (uint)files.Length, files, 0, IntPtr.Zero, 0, IntPtr.Zero);
                if (result.Error != 0) return result;
                uint count = 0, needed, reasons = 0;
                var info = Array.Empty<ProcessInfo>();
                // The list can race process exit/start. Limit both retries and size.
                for (int attempt = 0; attempt < 3; attempt++) {
                    result.Error = RmGetList(session, out needed, ref count, info, ref reasons);
                    if (result.Error == 0) {
                        result.Owners = new LockOwner[count];
                        for (int i = 0; i < count; i++) {
                            var start = info[i].Process.Start;
                            result.Owners[i] = new LockOwner { Pid = info[i].Process.Pid, StartFileTime = ((long)(uint)start.dwHighDateTime << 32) | (uint)start.dwLowDateTime };
                        }
                        return result;
                    }
                    if (result.Error != 234 || needed > 64) return result;
                    count = needed; info = new ProcessInfo[count];
                }
                return result;
            } finally { RmEndSession(session); }
        }
    }
}
'@
}

function Get-WindowsBuildNativeError {
    param([Exception]$Exception)
    for ($errorObject = $Exception; $null -ne $errorObject; $errorObject = $errorObject.InnerException) {
        if ($errorObject -is [ComponentModel.Win32Exception]) { return $errorObject.NativeErrorCode }
        # Only FACILITY_WIN32 HRESULTs: a generic IOException is not a sharing conflict.
        if (($errorObject.HResult -band 0xffff0000L) -eq 0x80070000L) { return ($errorObject.HResult -band 0xffff) }
    }
    return 0
}

function New-WindowsBuildMoveEvidence {
    param([Parameter(Mandatory)][string]$StageDirectory)
    $stagePath = [IO.Path]::GetFullPath($StageDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::GetFileName($stagePath) -cnotmatch '^windows-build-[0-9a-f]{32}$') { throw 'Expected an owned, unique Windows build stage.' }
    $appPath = Join-Path $stagePath 'app'
    if (-not (Test-Path -LiteralPath $appPath -PathType Container)) { throw 'The owned build app directory is missing.' }
    # Do not follow symlinks/junctions out of a build stage, even for diagnostics.
    $current = Get-Item -LiteralPath $appPath -Force
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build diagnostics do not follow reparse points.' }
        $current = $current.Parent
    }
    $files = @(Get-ChildItem -LiteralPath $appPath -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') })
    $reparse = Get-ChildItem -LiteralPath $appPath -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
    if ($reparse) { throw 'Build diagnostics do not follow reparse points.' }
    $reportRoot = Join-Path (Get-WindowsWorkbenchTestBase) ('cage-build-diagnostics-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $reportRoot | Out-Null
    return @{
        stage = $stagePath; app = $appPath; report = (Join-Path $reportRoot 'diagnostics.json')
        # EXEs first so large runtime closures cannot exclude the suspect CLI.
        files = @($files | Sort-Object @{ Expression = { $_.Extension -ne '.exe' } }, FullName | Select-Object -First 128 -ExpandProperty FullName)
        filesTruncated = $files.Count -gt 128
        images = @($files | Where-Object Extension -EQ '.exe' | Select-Object -ExpandProperty FullName)
        observed = @{}; snapshots = [Collections.Generic.List[object]]::new(); attempts = [Collections.Generic.List[object]]::new()
    }
}

function Save-WindowsBuildMoveEvidence {
    param($Evidence, [string]$Phase, [int]$NativeError = 0)
    if ($Evidence.snapshots.Count -ge 8) { return }
    try {
        $snapshot = [ordered]@{ phase = $Phase; utc = [DateTime]::UtcNow.ToString('o'); nativeError = $NativeError; processes = @(); lockOwners = @() }
        $all = @()
        try { $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate, ExecutablePath -OperationTimeoutSec 2) }
        catch { $snapshot.processQueryError = Get-WindowsBuildNativeError $_.Exception }
        $running = @{}
        foreach ($process in $all) {
            if (-not $process.ExecutablePath -or $process.ExecutablePath -notin $Evidence.images) { continue }
            $startUtc = if ($process.CreationDate) { $process.CreationDate.ToUniversalTime().ToString('o') } else { $null }
            $identity = "$($process.ProcessId)/$startUtc"
            $record = @{ pid = $process.ProcessId; parentPid = $process.ParentProcessId; startUtc = $startUtc; imagePath = $process.ExecutablePath; state = 'running' }
            $running[$identity] = $record
            if ($Evidence.observed.Count -lt 128) { $Evidence.observed[$identity] = $record }
        }
        $snapshot.processes = @($Evidence.observed.GetEnumerator() | ForEach-Object {
            $record = $_.Value.Clone()
            if (-not $running.ContainsKey($_.Key)) {
                # A missing/inaccessible CIM image path is not proof of exit.
                $record.state = 'not_observed'
                try {
                    $candidate = [Diagnostics.Process]::GetProcessById([int]$record.pid)
                    try { if ($candidate.HasExited) { $record.state = 'exited_since_observed' } }
                    finally { $candidate.Dispose() }
                } catch {
                    if ($_.Exception.GetBaseException() -is [ArgumentException]) { $record.state = 'exited_since_observed' }
                }
            }
            $record
        })
        try {
            Initialize-WindowsBuildLockQuery
            $query = [CageBuild.RestartManager]::Query([string[]]$Evidence.files)
            $snapshot.lockQueryError = $query.Error
            $snapshot.lockOwners = @($query.Owners | ForEach-Object {
                $owner = $_
                $process = $null
                try {
                    $live = [Diagnostics.Process]::GetProcessById($owner.Pid)
                    try {
                        if ($live.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $owner.StartFileTime) { $process = $all | Where-Object { $_.ProcessId -eq $owner.Pid } | Select-Object -First 1 }
                    } finally { $live.Dispose() }
                } catch { }
                @{ pid = $owner.Pid; startUtc = [DateTime]::FromFileTimeUtc($owner.StartFileTime).ToString('o'); parentPid = if ($process) { $process.ParentProcessId } else { $null }; imagePath = if ($process) { $process.ExecutablePath } else { $null }; identityMatched = $null -ne $process }
            })
        } catch { $snapshot.lockQueryError = Get-WindowsBuildNativeError $_.Exception; $snapshot.lockQueryUnavailable = $true }
        $Evidence.snapshots.Add($snapshot)
        $report = [ordered]@{ schema = 1; stage = $Evidence.stage; app = $Evidence.app; files = $Evidence.files; filesTruncated = $Evidence.filesTruncated; attempts = @($Evidence.attempts.ToArray()); snapshots = @($Evidence.snapshots.ToArray()) }
        [IO.File]::WriteAllText($Evidence.report, ($report | ConvertTo-Json -Depth 8))
    } catch { Write-Warning 'Could not save bounded build relocation evidence; no diagnostic failure is treated as proof that files are unlocked.' }
}

function Assert-WindowsBuildFileMoveable {
    param([string]$Path)
    $nativeError = [CageBuild.RestartManager]::DeleteSharingError($Path)
    if ($nativeError -ne 0) { throw [ComponentModel.Win32Exception]::new($nativeError) }
}

function Move-WindowsBuildApp {
    param($Evidence, [Parameter(Mandatory)][string]$Destination, [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 10000, [ValidateRange(1, 16)][int]$MaximumAttempts = 8)
    $destinationPath = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $prefix = $Evidence.stage + [IO.Path]::DirectorySeparatorChar
    if ($destinationPath -eq $Evidence.stage -or $destinationPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build destination must be outside its source stage.' }
    if (Test-Path -LiteralPath $destinationPath) { throw 'Build destination must not exist before relocation.' }
    $crossVolume = [IO.Path]::GetPathRoot($Evidence.app) -ne [IO.Path]::GetPathRoot($destinationPath)
    Save-WindowsBuildMoveEvidence $Evidence 'before_move'
    $elapsed = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $probeFile = $null
        $crossVolumeMoveStarted = $false
        try {
            Initialize-WindowsBuildLockQuery
            # Windows can report directory rename as access-denied (5) when a
            # child image has a handle lacking delete sharing. Probe the exact
            # staged images first so only a confirmed 32/33 permits waiting.
            foreach ($file in $Evidence.files) {
                $probeFile = $file
                Assert-WindowsBuildFileMoveable $file
            }
            $probeFile = $null
            # Directory.Move is atomic on a volume and preserves the exact native
            # error; Move-Item can emit provider errors or partially merge trees.
            if ($crossVolume) {
                # Keep the existing custom-output cross-volume capability. A
                # cross-volume provider move is not atomic: never retry it once
                # started, since a failure can leave both source and destination.
                $crossVolumeMoveStarted = $true
                Move-Item -LiteralPath $Evidence.app -Destination $destinationPath -ErrorAction Stop
            } else { [IO.Directory]::Move($Evidence.app, $destinationPath) }
            $Evidence.attempts.Add(@{ attempt = $attempt; elapsedMs = $elapsed.ElapsedMilliseconds; nativeError = 0 })
            Save-WindowsBuildMoveEvidence $Evidence 'moved'
            return
        } catch {
            $nativeError = Get-WindowsBuildNativeError $_.Exception
            $Evidence.attempts.Add(@{ attempt = $attempt; elapsedMs = $elapsed.ElapsedMilliseconds; nativeError = $nativeError; probeFile = $probeFile; crossVolumeMoveStarted = $crossVolumeMoveStarted })
            $retry = -not $crossVolumeMoveStarted -and $nativeError -in @(32, 33) -and $attempt -lt $MaximumAttempts -and $elapsed.ElapsedMilliseconds -lt $TimeoutMilliseconds
            if ($attempt -eq 1 -or -not $retry) { Save-WindowsBuildMoveEvidence $Evidence $(if ($retry) { 'sharing_conflict' } else { 'move_failed' }) $nativeError }
            if (-not $retry) { throw }
            $remaining = $TimeoutMilliseconds - $elapsed.ElapsedMilliseconds
            if ($remaining -le 0) { Save-WindowsBuildMoveEvidence $Evidence 'move_failed' $nativeError; throw }
            # Backoff is conditional on a confirmed sharing violation, never a
            # fixed post-smoke delay. Non-sharing failures are not retried.
            Start-Sleep -Milliseconds ([int][Math]::Min($remaining, [Math]::Min(2000, 100 * [Math]::Pow(2, $attempt - 1))))
        }
    }
}
