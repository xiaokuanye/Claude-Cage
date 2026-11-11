using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

internal static class NativeCleanupDiagnostics
{
    internal static void Capture(string executable, Exception error)
    {
        if (!OperatingSystem.IsWindows()) return;
        var utc = DateTime.UtcNow;
        using var probe = CreateFile(executable, 0x10000, 7, IntPtr.Zero, 3, 0, IntPtr.Zero);
        var sharing = probe.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        uint code = RmStartSession(out var session, 0, new StringBuilder(33));
        var owners = new List<object>();
        if (code == 0)
        {
            try
            {
                code = RmRegisterResources(session, 1, [executable], 0, IntPtr.Zero, 0, IntPtr.Zero);
                if (code == 0)
                {
                    uint count = 0, reasons = 0;
                    var info = Array.Empty<ProcessInfo>();
                    for (var attempt = 0; attempt < 3; attempt++)
                    {
                        code = RmGetList(session, out var needed, ref count, info, ref reasons);
                        if (code == 0)
                        {
                            for (var i = 0; i < count; i++)
                            {
                                var start = info[i].Process.Start;
                                owners.Add(new { pid = info[i].Process.Pid, startFileTime = ((long)(uint)start.dwHighDateTime << 32) | (uint)start.dwLowDateTime });
                            }
                            break;
                        }
                        if (code != 234 || needed > 64) break;
                        count = needed; info = new ProcessInfo[count];
                    }
                }
            }
            finally { RmEndSession(session); }
        }
        Console.Error.WriteLine("Native fixture cleanup evidence: " + JsonSerializer.Serialize(new {
            utc, executable, testPid = Environment.ProcessId, hresult = error.HResult, deleteSharingError = sharing,
            lockQueryError = code, owners,
        }));
    }

    [StructLayout(LayoutKind.Sequential)] private struct UniqueProcess { public int Pid; public System.Runtime.InteropServices.ComTypes.FILETIME Start; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ProcessInfo
    {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceName;
        public int AppType; public uint AppStatus, SessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string file, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] private static extern uint RmStartSession(out uint session, uint flags, StringBuilder key);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] private static extern uint RmRegisterResources(uint session, uint count, string[] files, uint apps, IntPtr processes, uint services, IntPtr names);
    [DllImport("rstrtmgr.dll")] private static extern uint RmGetList(uint session, out uint needed, ref uint count, [In, Out] ProcessInfo[] info, ref uint reasons);
    [DllImport("rstrtmgr.dll")] private static extern uint RmEndSession(uint session);
}
