using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Cage.Windows;

internal static class NativeHelperTests
{
    internal static async Task<bool> RunFixture(string[] args)
    {
        if (args is ["prepare-update", "--json"])
        {
            Console.WriteLine("{\"status\":\"prepared\"}"); return true;
        }
        if (args is ["diagnostic-event"])
        {
            var marker = Environment.GetEnvironmentVariable("CAGE_TEST_DIAGNOSTIC_MARKER")!;
            PublishPid(marker);
            // Neither read stdin nor exit: exercise the actual Report deadline.
            await Task.Delay(TimeSpan.FromSeconds(30)); return true;
        }
        if (args is not ["lifecycle-helper", var mode, var markerPath, var release]) return false;
        PublishPid(markerPath);
        switch (mode)
        {
            case "wait":
                using (var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                    while (!File.Exists(release)) await Task.Delay(10, deadline.Token);
                Console.WriteLine("{\"status\":\"ready\"}"); break;
            case "pipes":
                // Fill stderr as well as stdout, then stop reading stdin.
                var flood = new string('x', 128 * 1024);
                await Task.WhenAll(Console.Out.WriteAsync(flood), Console.Error.WriteAsync(flood));
                await Task.Delay(TimeSpan.FromSeconds(30)); break;
            case "invalid": Console.WriteLine("not-json"); break;
            case "ready": Console.WriteLine("{\"status\":\"ready\"}"); break;
            default: throw new InvalidOperationException("Unknown isolated fixture mode");
        }
        return true;
    }

    private static void PublishPid(string path)
    {
        File.WriteAllText(path + ".new", Environment.ProcessId.ToString());
        File.Move(path + ".new", path);
    }

    internal static async Task Run(string root, string executable)
    {
        var assertions = 0;
        var owners = new List<NativeHelperLifetime>();
        var requests = new List<Task>();
        NativeHelperLifetime NewOwner() { var owner = new NativeHelperLifetime(); owners.Add(owner); return owner; }
        void Check(bool value, string message) { assertions++; if (!value) throw new Exception(message); }
        async Task Reject<T>(Func<Task> action, string message) where T : Exception
        {
            assertions++;
            try { await action(); } catch (T) { return; }
            throw new Exception(message);
        }
        string PathFor(string name) => Path.Combine(root, "lifecycle-" + name);
        ProcessStartInfo Start(string mode, string name) => Backend.StartInfo(executable,
            "lifecycle-helper", mode, PathFor(name + ".pid"), PathFor(name + ".release"));
        Task<(int Exit, string Output)> Run(NativeHelperLifetime owner, string mode, string name,
            TimeSpan? deadline = null, int limit = 65536, string? input = null)
        {
            var start = Start(mode, name); start.RedirectStandardInput = input != null;
            var task = Backend.RunHelper(owner, start, CancellationToken.None, deadline ?? TimeSpan.FromSeconds(10), limit, input);
            requests.Add(task); return task;
        }
        async Task<Process> Pin(string name)
        {
            var timer = Stopwatch.StartNew();
            while (!File.Exists(PathFor(name + ".pid")))
            {
                if (timer.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException("Fixture did not start");
                await Task.Delay(10);
            }
            // The fixture atomically publishes a complete PID marker.
            var pid = File.ReadAllText(PathFor(name + ".pid"));
            var child = Process.GetProcessById(int.Parse(pid)); _ = child.SafeHandle; return child;
        }

        try
        {
        var graceful = NewOwner();
        var pending = Run(graceful, "wait", "graceful");
        using (var child = await Pin("graceful"))
        {
            graceful.CloseAdmission();
            var drain = graceful.DrainAsync(TimeSpan.FromSeconds(5));
            Check(!drain.IsCompleted && graceful.ActiveCount == 1, "drain skipped an admitted helper");
            await Reject<InvalidOperationException>(() => Run(graceful, "ready", "rejected"), "closed admission accepted a helper");
            Check(!File.Exists(PathFor("rejected.pid")), "rejected helper actually started");
            File.WriteAllText(PathFor("graceful.release"), "release");
            Check((await pending).Exit == 0 && await drain, "in-flight helper did not drain normally");
            Check(child.HasExited && graceful.ActiveCount == 0, "normal completion leaked a process/count");
        }

        // Same executable, deliberately outside the registry. Neither drain nor
        // timeout may terminate it; its owning test handle releases it below.
        using (var unrelated = Process.Start(Start("wait", "unrelated"))!)
        {
            try
            {
                var forced = NewOwner();
                var request = Run(forced, "wait", "forced");
                using var child = await Pin("forced");
                Check(!await forced.DrainAsync(TimeSpan.FromMilliseconds(100)), "delayed helper did not reach forced drain");
                await Reject<OperationCanceledException>(async () => await request, "forced request did not cancel");
                Check(child.HasExited && forced.ActiveCount == 0, "forced drain returned before owned process exit");
                Check(!unrelated.HasExited, "drain killed an unregistered same-executable process");
            }
            finally
            {
                File.WriteAllText(PathFor("unrelated.release"), "release");
                try { await unrelated.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
                finally { if (!unrelated.HasExited) { unrelated.Kill(); await unrelated.WaitForExitAsync(); } }
            }
        }

        var timeoutOwner = NewOwner();
        var timed = Run(timeoutOwner, "wait", "timeout", TimeSpan.FromSeconds(1));
        using (var child = await Pin("timeout"))
        {
            await Reject<OperationCanceledException>(async () => await timed, "request deadline did not fire");
            Check(child.HasExited && timeoutOwner.ActiveCount == 0, "timeout failed to wait for process exit");
        }
        var pipeOwner = NewOwner();
        await Reject<OperationCanceledException>(async () => await Run(pipeOwner, "pipes", "pipes",
            TimeSpan.FromSeconds(1), 256 * 1024, new string('s', 1024 * 1024)), "blocked stdin was not deadline bounded");
        Check(pipeOwner.ActiveCount == 0 && await pipeOwner.DrainAsync(TimeSpan.FromSeconds(1)), "pipe timeout leaked accounting");

        var outputOwner = NewOwner();
        await Reject<IOException>(async () => await Run(outputOwner, "pipes", "oversize", limit: 128), "output limit was not enforced");
        Check(outputOwner.ActiveCount == 0 && await outputOwner.DrainAsync(TimeSpan.FromSeconds(1)), "output failure leaked accounting");
        var failedStart = NewOwner();
        await Reject<System.ComponentModel.Win32Exception>(async () => await Backend.RunHelper(failedStart,
            Backend.StartInfo(PathFor("absent.exe")), CancellationToken.None, TimeSpan.FromSeconds(1), 128), "missing executable accepted");
        Check(failedStart.ActiveCount == 0 && await failedStart.DrainAsync(TimeSpan.FromSeconds(1)), "start failure leaked accounting");

        // Race admission with close repeatedly. The start either fails without
        // a child or is present in the exact drain snapshot, never in between.
        for (var i = 0; i < 12; i++)
        {
            var owner = NewOwner();
            var name = "race-" + i;
            File.WriteAllText(PathFor(name + ".release"), "release");
            var raced = Task.Run(() => Run(owner, "wait", name));
            var drain = Task.Run(() => owner.DrainAsync(TimeSpan.FromSeconds(5)));
            try { await raced; } catch (InvalidOperationException) { }
            Check(await drain && owner.ActiveCount == 0, "close/start race missed a child");
        }

        var explicitOwner = NewOwner();
        await Reject<InvalidOperationException>(async () => await Backend.RunHelper(explicitOwner, Start("ready", "early-shutdown"),
            CancellationToken.None, TimeSpan.FromSeconds(1), 128, shutdown: true), "shutdown bypass allowed before close");
        Check(await explicitOwner.DrainAsync(TimeSpan.FromSeconds(1)), "empty drain failed");
        Check((await Backend.RunHelper(explicitOwner, Start("ready", "explicit-shutdown"),
            CancellationToken.None, TimeSpan.FromSeconds(2), 128, shutdown: true)).Exit == 0, "explicit shutdown rejected after drain");

        // Exercise production JsonAt/Report too, not only the isolated registry.
        await Reject<IOException>(async () => await Backend.JsonAt(executable,
            ["lifecycle-helper", "invalid", PathFor("invalid.pid"), PathFor("invalid.release")]), "invalid JSON accepted");
        var previousMarker = Environment.GetEnvironmentVariable("CAGE_TEST_DIAGNOSTIC_MARKER");
        try
        {
            Environment.SetEnvironmentVariable("CAGE_TEST_DIAGNOSTIC_MARKER", PathFor("report.pid"));
            var report = Backend.Report("synthetic diagnostic fixture only");
            using (var diagnostic = await Pin("report"))
            {
                await report.WaitAsync(TimeSpan.FromSeconds(12));
                Check(diagnostic.HasExited, "Report completed without waiting for timeout cleanup");
            }
            Environment.SetEnvironmentVariable("CAGE_TEST_DIAGNOSTIC_MARKER", PathFor("drained-report.pid"));
            var reporting = Backend.Report("synthetic diagnostic fixture only");
            using var activeReport = await Pin("drained-report");
            Backend.CloseSmokeAdmission();
            await Reject<InvalidOperationException>(async () => await Backend.JsonAt(executable,
                ["prepare-update", "--json"]), "ordinary prepare-update bypassed closed admission");
            Check(!await Backend.DrainSmokeHelpers(TimeSpan.FromMilliseconds(100)), "Report not registered in shutdown drain");
            await reporting;
            Check(activeReport.HasExited, "shutdown drain missed fire-and-forget-style Report");
            Environment.SetEnvironmentVariable("CAGE_TEST_DIAGNOSTIC_MARKER", PathFor("rejected-report.pid"));
            await Backend.Report("must not spawn after shutdown");
            Check(!File.Exists(PathFor("rejected-report.pid")), "closed Report launched a process");
            var prepared = await Backend.PrepareSmokeShutdown(CancellationToken.None);
            Check(prepared.Exit == 0 && prepared.Data.Text("status") == "prepared", "explicit Backend shutdown failed");
        }
        finally { Environment.SetEnvironmentVariable("CAGE_TEST_DIAGNOSTIC_MARKER", previousMarker); }

        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("Cage.MainWindow.Source.cs")!;
        using var reader = new StreamReader(source);
        var host = await reader.ReadToEndAsync();
        Check(host.IndexOf("Backend.CloseSmokeAdmission();", StringComparison.Ordinal) < host.IndexOf("Backend.DrainSmokeHelpers(", StringComparison.Ordinal)
            && host.IndexOf("Backend.DrainSmokeHelpers(", StringComparison.Ordinal) < host.IndexOf("Backend.CaptureSmokeControllers();", StringComparison.Ordinal),
            "host capture no longer follows admission close and drain");
        Check(host.Contains("if (completingSmoke) throw new InvalidOperationException") && host.Contains("if (completingSmoke || bootstrapping"),
            "host lost refresh/reconnect closing gates");
        Check(host.Contains("Program.SmokeOutput != null && operation != \"status\"") && host.Contains("checkUpdate.Enabled = Program.SmokeOutput == null;"),
            "smoke permits updater helpers outside the native registry");
        Check(host.Contains("errors:(window.__cageSmokeErrors||[]).slice(0,8)") && !host.Contains("if (!nativeBridgeReady && web.CoreWebView2 != null)"),
            "successful smoke does not capture bounded JS errors");
        Check(!host.Contains("document.body?.innerText") && !host.Contains("scrub(event.message)") && !host.Contains("pageURL"),
            "smoke exports arbitrary page content or private URLs");
        Console.WriteLine($"Windows native helper lifetime: {assertions} assertions passed; close/drain race, deadlines, bounded pipes, owned-handle cleanup, unrelated process survival, Report/Json integration and host contract.");
        }
        finally
        {
            // Failed assertions must not leave a fixture running. Only each
            // registry's owned handles are eligible for cancellation/cleanup.
            foreach (var owner in owners) await owner.DrainAsync(TimeSpan.Zero);
            try { await Task.WhenAll(requests); } catch (Exception) { }
            await Backend.DrainSmokeHelpers(TimeSpan.Zero);
        }
    }
}
