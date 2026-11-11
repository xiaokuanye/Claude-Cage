using Cage.Windows;

if (await NativeHelperTests.RunFixture(args)) return;

if (args is ["smoke-wait", var smokeRelease])
{
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    while (!File.Exists(smokeRelease)) await Task.Delay(20, deadline.Token);
    return;
}

if (args is ["app-update", "check" or "download"])
{
    File.AppendAllText(Path.Combine(Backend.Root, "retry-invocations"), "x");
    Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { phase = "failed", message = "limited", retryable = true, retryAt = Environment.GetEnvironmentVariable("CAGE_UPDATE_RETRY_AT") }));
    Environment.Exit(1);
}

// The recovery integration tests launch a copy of this executable through the
// same subprocess/JSON boundary used by the shipped updater.
if (args is ["prepare-update", "--json", "--stop"])
{
    File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "controller-invoked"), Environment.ProcessId.ToString());
    File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "profile-invoked"), Environment.GetEnvironmentVariable("CLAUDE_CAGE_CONFIG") ?? "missing");
    if (File.Exists(Path.Combine(AppContext.BaseDirectory, "broken-backend")))
    {
        Console.WriteLine("{\"status\":\"failed\"}"); Environment.Exit(7);
    }
    Console.WriteLine(File.Exists(Path.Combine(AppContext.BaseDirectory, "running-environment"))
        ? "{\"status\":\"stop_required\"}" : "{\"status\":\"prepared\"}");
    return;
}

#if WINDOWS
NativeInputTests.Run();
#endif

var assertions = 0;
void Check(bool condition, string message) { assertions++; if (!condition) throw new Exception(message); }
void Reject(Action action, string message)
{
    assertions++;
    try { action(); } catch (InvalidDataException) { return; }
    throw new Exception(message);
}
foreach (var (work, dpi) in new[] {
    (new System.Drawing.Rectangle(0, 0, 3840, 2080), 96),
    (new System.Drawing.Rectangle(0, 0, 3840, 2080), 192),
    (new System.Drawing.Rectangle(0, 0, 1920, 1040), 144),
    (new System.Drawing.Rectangle(0, 0, 1366, 728), 96),
    (new System.Drawing.Rectangle(-1920, 0, 1920, 1040), 96),
    (new System.Drawing.Rectangle(0, 0, 1280, 680), 192),
})
{
    var bounds = WindowLayout.Bounds(work, dpi, null);
    Check(work.Contains(bounds), "initial window extends beyond the monitor work area");
    Check(bounds.Width >= WindowLayout.Minimum(work, dpi).Width, "initial window is below its DPI-aware minimum");
    var restored = WindowLayout.Bounds(work, dpi, new WindowPlacement(5000, 3000, 5000, 4000, 96, false));
    Check(work.Contains(restored), "saved window is inaccessible after a monitor or DPI change");
}
Check(WindowLayout.Bounds(new(0, 0, 3840, 2080), 96, null).Width > 2500, "4K window stayed at a fixed 1280 pixels");
Check(WindowLayout.Bounds(new(0, 0, 3840, 2080), 192, new(100, 100, 1000, 700, 96, false)).Width == 2000,
    "restoring a user size did not account for the new monitor DPI");
Console.WriteLine($"Windows window layout: {assertions} assertions passed.");
assertions = 0;
Check(UpdatePolicy.IsWorkbench("http://localhost:4321/", 4321), "expected local origin rejected");
foreach (var origin in new[] { "https://localhost:4321/", "http://localhost:4322/", "http://localhost.evil:4321/", "http://user@localhost:4321/", "http://127.0.0.1:4321/", "file:///C:/workbench.html" })
    Check(!UpdatePolicy.IsWorkbench(origin, 4321), "foreign native bridge origin accepted: " + origin);
Check(UpdatePolicy.Entry("http://localhost:4321/#token").Port == 4321, "entry URL rejected");
Reject(() => UpdatePolicy.Entry("http://localhost:4321/"), "entry without token accepted");
Check(UpdatePolicy.IsNewer("0.1.0-alpha.10", "0.1.0-alpha.9"), "numeric prerelease ordering");
Check(UpdatePolicy.IsNewer("0.1.0", "0.1.0-alpha.10"), "stable release ordering");
Check(UpdatePolicy.IsNewer("1.0.0-alpha.beta", "1.0.0-alpha.10"), "text prerelease ordering");
Check(!UpdatePolicy.IsNewer("0.1.0-alpha.01", "0.1.0-alpha.0"), "leading zero accepted");
Check(!UpdatePolicy.IsNewer("0.1.0-alpha.1", "0.1.0-alpha.1"), "same version accepted");
Check(!UpdatePolicy.IsNewer("0.1.0-alpha.1", "0.1.0"), "downgrade accepted");
Check(!UpdatePolicy.IsNewer("v0.2.0", "0.1.0"), "noncanonical version accepted");
Check(!UpdatePolicy.IsNewer("0.2.0+metadata", "0.1.0"), "unmatched backend version accepted");
var root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "cage-update-policy-tests"));
var good = Path.Combine(root, "download-abc", "Cage-setup.exe");
Check(UpdatePolicy.DownloadPath(good, root) == good, "private download rejected");
foreach (var path in new[] { Path.Combine(root + "-other", "download-abc", "Cage-setup.exe"), Path.Combine(root, "verified-abc", "Cage-setup.exe"), Path.Combine(root, "download-abc", "nested", "Cage-setup.exe"), Path.Combine(root, "download-abc", "Cage.exe") })
    Reject(() => UpdatePolicy.DownloadPath(path, root), "untrusted download path accepted: " + path);
Console.WriteLine($"Windows update/bridge policy: {assertions} assertions passed.");

var integration = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "cage-recovery-" + Guid.NewGuid());
Directory.CreateDirectory(integration);
var savedProfile = Environment.GetEnvironmentVariable("CLAUDE_CAGE_CONFIG");
try
{
    var selectedProfile = Path.Combine(integration, "selected profile", "config.json");
    Environment.SetEnvironmentVariable("CLAUDE_CAGE_CONFIG", Path.GetRelativePath(Environment.CurrentDirectory, selectedProfile));
    var backup = Path.Combine(integration, "old application");
    var candidate = Path.Combine(integration, "new application");
    void InstallFixture(string app, bool broken)
    {
        var resources = Path.Combine(app, "resources"); Directory.CreateDirectory(resources);
        foreach (var file in Directory.EnumerateFiles(AppContext.BaseDirectory))
            File.Copy(file, Path.Combine(resources, Path.GetFileName(file)));
        var controller = Path.Combine(resources, "cage.exe");
        File.Copy(Environment.ProcessPath!, controller, true);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(controller, File.GetUnixFileMode(Environment.ProcessPath!));
        if (broken) File.WriteAllText(Path.Combine(resources, "broken-backend"), "cannot start");
    }
    InstallFixture(backup, false); InstallFixture(candidate, true);
    var snapshotSource = Path.Combine(integration, "snapshot source");
    var snapshotTarget = Path.Combine(integration, "snapshot target");
    Directory.CreateDirectory(Path.Combine(snapshotSource, "my-project"));
    File.WriteAllText(Path.Combine(snapshotSource, "program.txt"), "program");
    File.WriteAllText(Path.Combine(snapshotSource, "my-project", "work.txt"), "personal data");
    File.WriteAllText(Path.Combine(snapshotSource, "Cage.install-files.json"), System.Text.Json.JsonSerializer.Serialize(new {
        version = 1, files = new[] { new { path = "program.txt", sha256 = new string('a', 64) } },
    }));
    var copyTree = typeof(UpdateInstaller).GetMethod("CopyTree", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
    copyTree.Invoke(null, [snapshotSource, snapshotTarget]);
    Check(File.ReadAllText(Path.Combine(snapshotTarget, "program.txt")) == "program", "update snapshot missed a declared program file");
    Check(!Directory.Exists(Path.Combine(snapshotTarget, "my-project")), "update snapshot copied live user data into the program rollback snapshot");
    Check(File.ReadAllText(Path.Combine(snapshotSource, "my-project", "work.txt")) == "personal data", "snapshot changed personal data");
    var nestedSnapshot = Path.Combine(snapshotSource, "updates", "backup");
    var rejectedNestedSnapshot = false;
    try { copyTree.Invoke(null, [snapshotSource, nestedSnapshot]); }
    catch (System.Reflection.TargetInvocationException error) when (error.InnerException is InvalidDataException) { rejectedNestedSnapshot = true; }
    Check(rejectedNestedSnapshot, "snapshot recursively copied its own output");
    Check(!Directory.Exists(nestedSnapshot), "overlapping snapshot destination was created before validation");
    var ensureComplete = typeof(UpdateInstaller).GetMethod("EnsureInstallationComplete", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!;
    ensureComplete.Invoke(null, [snapshotSource]);
    var recoveryReceipt = snapshotSource + ".cage-installation.json";
    File.WriteAllText(recoveryReceipt, System.Text.Json.JsonSerializer.Serialize(new { stagePath = candidate, backupPath = backup }));
    string? pendingRecovery = null;
    try { ensureComplete.Invoke(null, [snapshotSource]); }
    catch (System.Reflection.TargetInvocationException error) when (error.InnerException is IOException) { pendingRecovery = error.InnerException.Message; }
    Check(pendingRecovery != null, "updater accepted a partially restored installation");
    Check(pendingRecovery!.Contains(candidate) && pendingRecovery.Contains(backup), "recovery error omitted the preserved directories");
    Check(File.Exists(recoveryReceipt), "recovery validation removed the persistent receipt");
    File.Delete(recoveryReceipt);
    var rejectedMissingInstallation = false;
    try { ensureComplete.Invoke(null, [Path.Combine(integration, "missing installation")]); }
    catch (System.Reflection.TargetInvocationException error) when (error.InnerException is IOException) { rejectedMissingInstallation = true; }
    Check(rejectedMissingInstallation, "updater accepted a missing installation and could restore a program-only snapshot");
    if (!OperatingSystem.IsWindows())
    {
        File.Delete(Path.Combine(snapshotSource, "Cage.install-files.json"));
        Directory.CreateSymbolicLink(Path.Combine(snapshotSource, "external-link"), Path.Combine(snapshotSource, "my-project"));
        var legacySnapshot = Path.Combine(integration, "legacy snapshot");
        copyTree.Invoke(null, [snapshotSource, legacySnapshot]);
        Check(File.ReadAllText(Path.Combine(legacySnapshot, "my-project", "work.txt")) == "personal data", "legacy snapshot missed a regular file");
        Check(!Directory.Exists(Path.Combine(legacySnapshot, "external-link")), "legacy snapshot followed a user link");
    }
    await UpdateRecovery.PrepareRollback(backup);
    Check(File.Exists(Path.Combine(backup, "resources", "controller-invoked")), "recovery did not execute the old backend");
    Check(!File.Exists(Path.Combine(candidate, "resources", "controller-invoked")), "recovery executed the broken candidate backend");
    Check(File.ReadAllText(Path.Combine(backup, "resources", "profile-invoked")) == selectedProfile, "recovery child switched away from the original relative profile");
    File.WriteAllText(Path.Combine(backup, "resources", "running-environment"), "still running");
    var rejected = false;
    try { await UpdateRecovery.PrepareRollback(backup); } catch (IOException) { rejected = true; }
    Check(rejected, "recovery continued without a prepared response from the old backend");

    var garbage = Path.Combine(integration, "locked backup"); Directory.CreateDirectory(garbage);
    var lockedFile = Path.Combine(garbage, "old.dll"); File.WriteAllText(lockedFile, "old version");
    var download = Path.Combine(integration, "download"); Directory.CreateDirectory(download);
    var marker = Path.Combine(integration, "ack.json"); File.WriteAllText(marker, "confirmed");
    var liveApp = Path.Combine(candidate, "Cage.exe"); File.WriteAllText(liveApp, "healthy new application");
    FileStream? locked = null;
    if (OperatingSystem.IsWindows()) locked = new FileStream(lockedFile, FileMode.Open, FileAccess.Read, FileShare.Read);
    else File.SetUnixFileMode(garbage, UnixFileMode.UserRead | UnixFileMode.UserExecute);
    try
    {
        UpdateRecovery.CleanupAfterSuccess(garbage, download, marker);
        Check(File.ReadAllText(liveApp) == "healthy new application", "cleanup changed the confirmed new application");
        Check(File.Exists(lockedFile), "fixture did not cause the intended cleanup failure");
        Check(!Directory.Exists(download) && !File.Exists(marker), "one cleanup failure prevented independent cleanup");
    }
    finally
    {
        locked?.Dispose();
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(garbage, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }
    Console.WriteLine($"Windows snapshot/recovery integration: {assertions - 22} assertions passed; actual child process and filesystem failures exercised.");

    // Exercise the production updater's streamed state and process-exit path.
    var nativeResources = Path.Combine(AppContext.BaseDirectory, "resources");
    if (Directory.Exists(nativeResources)) throw new IOException("retry fixture requires an unused test resources directory");
    Directory.CreateDirectory(nativeResources);
    var savedRetry = Environment.GetEnvironmentVariable("CAGE_UPDATE_RETRY_AT");
    try
    {
        foreach (var file in Directory.EnumerateFiles(AppContext.BaseDirectory)) File.Copy(file, Path.Combine(nativeResources, Path.GetFileName(file)));
        var executable = Path.Combine(nativeResources, "cage.exe");
        File.Copy(Environment.ProcessPath!, executable, true);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(executable, File.GetUnixFileMode(Environment.ProcessPath!));
        var release = Path.Combine(integration, "smoke-release");
        using (var owned = System.Diagnostics.Process.Start(Backend.StartInfo(executable, "smoke-wait", release))!)
        {
            var record = Path.Combine(Backend.Root, "control.json");
            Directory.CreateDirectory(Backend.Root);
            var controllers = new List<System.Diagnostics.Process>();
            try
            {
                File.WriteAllText(record, System.Text.Json.JsonSerializer.Serialize(new { pid = Environment.ProcessId }));
                var foreignRejected = false;
                try { Backend.CaptureSmokeControllers(); } catch (IOException) { foreignRejected = true; }
                Check(foreignRejected, "smoke captured a controller outside its application executable");
                File.WriteAllText(record, System.Text.Json.JsonSerializer.Serialize(new { pid = owned.Id }));
                controllers = Backend.CaptureSmokeControllers();
                Check(controllers.Count == 1 && !controllers[0].HasExited, "smoke did not pin its live controller");
                var exit = NativeHelperLifetime.WaitForProcessExitAsync(controllers[0], CancellationToken.None);
                Check(!exit.IsCompleted, "smoke considered a still-running controller stopped");
                File.WriteAllText(release, "release owned child");
                await exit.WaitAsync(TimeSpan.FromSeconds(5));
                Check(controllers[0].HasExited, "smoke did not observe actual controller exit");
            }
            finally
            {
                File.WriteAllText(release, "release owned child");
                if (!owned.WaitForExit(5000)) { owned.Kill(); owned.WaitForExit(); }
                foreach (var controller in controllers) controller.Dispose();
                File.Delete(record);
            }
        }
        Console.WriteLine("Windows smoke shutdown: actual controller handle pinned, foreign executable rejected, process exit observed.");
        var retryAt = DateTimeOffset.UtcNow.AddHours(1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        Directory.CreateDirectory(Backend.Root);
        Environment.SetEnvironmentVariable("CAGE_UPDATE_RETRY_AT", retryAt);
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var failures = 0;
        using var updater = new AppUpdater(state => { if (state.GetValueOrDefault("phase") as string == "failed" && Interlocked.Increment(ref failures) == 2) completion.TrySetResult(); }, () => throw new Exception("unexpected installation"), () => {});
        updater.Handle("check");
        await completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Check(updater.Handle("status").GetValueOrDefault("retryAt") as string == retryAt, "process-exit path lost retry deadline");
        updater.Handle("check"); updater.Handle("install");
        await Task.Delay(100);
        Check(File.ReadAllText(Path.Combine(Backend.Root, "retry-invocations")) == "x", "native check/install bypassed server cooldown");
        Console.WriteLine("Windows updater protocol: real subprocess preserved deadline; early check/install blocked.");
        // This closes Backend's admission permanently, so keep it last.
        await NativeHelperTests.Run(integration, executable);
    }
    catch (Exception error)
    {
        Console.Error.WriteLine("Native fixture operation failure: " + error);
        throw;
    }
    finally
    {
        Environment.SetEnvironmentVariable("CAGE_UPDATE_RETRY_AT", savedRetry);
        try { Directory.Delete(nativeResources, true); }
        catch (UnauthorizedAccessException error)
        {
            NativeCleanupDiagnostics.Capture(Path.Combine(nativeResources, "cage.exe"), error);
            throw;
        }
    }
}
finally {
    Environment.SetEnvironmentVariable("CLAUDE_CAGE_CONFIG", savedProfile);
    Directory.Delete(integration, true);
}
