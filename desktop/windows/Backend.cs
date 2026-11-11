using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Cage.Windows;

internal static class Backend
{
    private static readonly NativeHelperLifetime helpers = new();
    public static bool ClientOnly => File.Exists(Path.Combine(AppContext.BaseDirectory, "resources", "client-only"));
    private static string ConfigPath => Path.GetFullPath(
        Environment.GetEnvironmentVariable("CLAUDE_CAGE_CONFIG") is { Length: > 0 } configured
            ? configured : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude-cage", ClientOnly ? "client" : "", "config.json"));
    public static string Root => Path.GetDirectoryName(ConfigPath)!;
    public static string Executable => Path.Combine(AppContext.BaseDirectory, "resources", "cage.exe");

    public static List<Process> CaptureSmokeControllers()
    {
        var processes = new List<Process>();
        try
        {
            foreach (var profile in new[] { Root, Path.Combine(Root, "desktop-entry") })
            {
                var record = Path.Combine(profile, "control.json");
                if (!File.Exists(record)) continue;
                using var data = JsonDocument.Parse(File.ReadAllText(record));
                Process process;
                try { process = Process.GetProcessById(data.RootElement.GetProperty("pid").GetInt32()); }
                catch (ArgumentException) { continue; } // It already exited.
                try
                {
                    // Pin the actual process handle before requesting shutdown.
                    // A released profile lock alone does not release its image.
                    _ = process.SafeHandle;
                    if (process.HasExited) { process.Dispose(); continue; }
                    if (!string.Equals(Path.GetFullPath(process.MainModule!.FileName), Path.GetFullPath(Executable), StringComparison.OrdinalIgnoreCase))
                        throw new IOException("自检后台身份与当前应用不符，未等待其他程序");
                    processes.Add(process);
                }
                catch { process.Dispose(); throw; }
            }
            return processes;
        }
        catch { foreach (var process in processes) process.Dispose(); throw; }
    }

    public static ProcessStartInfo StartInfo(string executable, params string[] arguments)
    {
        var start = new ProcessStartInfo(executable) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = AppContext.BaseDirectory,
        };
        // Helpers execute outside the installed directory. Keep an explicitly
        // selected relative profile bound to the same absolute file.
        start.Environment["CLAUDE_CAGE_CONFIG"] = ConfigPath;
        if (arguments.Length > 0 && arguments[0] == "desktop") start.Environment["CAGE_DESKTOP_OWNER_PID"] = Environment.ProcessId.ToString();
        foreach (var arg in arguments) start.ArgumentList.Add(arg);
        return start;
    }

    public static Task<(int Exit, JsonElement Data)> Json(string[] arguments, CancellationToken cancellation = default, TimeSpan? deadline = null, int outputLimit = 65536) =>
        JsonAt(Executable, arguments, cancellation, deadline, outputLimit);

    public static async Task<(int Exit, JsonElement Data)> JsonAt(string executable, string[] arguments, CancellationToken cancellation = default, TimeSpan? deadline = null, int outputLimit = 65536)
    {
        var result = await RunHelper(helpers, StartInfo(executable, arguments), cancellation,
            deadline ?? TimeSpan.FromMinutes(3), outputLimit).ConfigureAwait(false);
        return ParseJson(result);
    }

    public static void CloseSmokeAdmission() => helpers.CloseAdmission();
    public static Task<bool> DrainSmokeHelpers(TimeSpan grace) => helpers.DrainAsync(grace);

    // The shutdown exception is explicit, not an argument-based bypass that a
    // late ordinary Json/Report request could use after admission is closed.
    public static async Task<(int Exit, JsonElement Data)> PrepareSmokeShutdown(CancellationToken cancellation)
    {
        var result = await RunHelper(helpers, StartInfo(Executable, "prepare-update", "--json"),
            cancellation, TimeSpan.FromSeconds(20), 65536, shutdown: true).ConfigureAwait(false);
        return ParseJson(result);
    }

    private static (int Exit, JsonElement Data) ParseJson((int Exit, string Output) result)
    {
        try { using var document = JsonDocument.Parse(result.Output); return (result.Exit, document.RootElement.Clone()); }
        catch (JsonException) { throw new IOException("Cage 后台未返回有效状态，请查看工作台日志"); }
    }

    internal static async Task<(int Exit, string Output)> RunHelper(NativeHelperLifetime owner, ProcessStartInfo start,
        CancellationToken cancellation, TimeSpan deadline, int outputLimit, string? input = null, bool shutdown = false)
    {
        cancellation.ThrowIfCancellationRequested();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation, shutdown ? CancellationToken.None : owner.Stopping);
        timeout.CancelAfter(deadline);
        var helper = owner.Start(start, shutdown);
        var process = helper.Process;
        StreamReader? standardOutput = null, standardError = null;
        StreamWriter? standardInput = null;
        Task<string> output = Task.FromResult("");
        Task errors = Task.CompletedTask, writing = Task.CompletedTask;
        try
        {
            standardOutput = process.StandardOutput; standardError = process.StandardError;
            output = ReadLimited(standardOutput, outputLimit, timeout.Token);
            errors = Drain(standardError, timeout.Token);
            if (input != null) { standardInput = process.StandardInput; writing = WriteInput(standardInput, input, timeout.Token); }
            await writing.WaitAsync(timeout.Token).ConfigureAwait(false);
            var text = await output.WaitAsync(timeout.Token).ConfigureAwait(false);
            await helper.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            await errors.WaitAsync(timeout.Token).ConfigureAwait(false);
            return (process.ExitCode, text);
        }
        finally
        {
            timeout.Cancel();
            // Finish registration only after exit, explicit pipe disposal and
            // observation of every I/O task, including timed-out stdin writes.
            await helper.CompleteAsync([output, errors, writing], standardOutput, standardError, standardInput).ConfigureAwait(false);
        }
    }

    private static async Task WriteInput(StreamWriter writer, string input, CancellationToken token)
    {
        await writer.WriteAsync(input.AsMemory(), token).ConfigureAwait(false);
        await writer.FlushAsync(token).ConfigureAwait(false);
        writer.Close();
    }

    public static async Task<string> ReadLimited(StreamReader reader, int limit, CancellationToken token)
    {
        var text = new StringBuilder(); var buffer = new char[4096]; int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) > 0)
        {
            text.Append(buffer, 0, count);
            if (text.Length > limit) throw new IOException("后台响应超过允许大小");
        }
        return text.ToString();
    }

    public static async Task Drain(StreamReader reader, CancellationToken token)
    {
        var buffer = new char[4096];
        while (await reader.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false) > 0) { }
    }
    public static async Task Report(string message)
    {
        try
        {
            var start = StartInfo(Executable, "diagnostic-event");
            start.RedirectStandardInput = true;
            await RunHelper(helpers, start, CancellationToken.None, TimeSpan.FromSeconds(5), 65536,
                JsonSerializer.Serialize(new { source = "native", message = message[..Math.Min(message.Length, 4096)] })).ConfigureAwait(false);
        }
        catch (Exception) { /* Logging failure must not recurse or replace the original error. */ }
    }
    public static string Text(this JsonElement data, string name) =>
        data.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : "";
}
