using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Cage.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

// Real WebView2, but no visible window, production profile, server, or remote input.
// The baseline is the previous fire-and-forget per-event ExecuteScriptAsync path.
// Awaiting baseline results is deliberately outside the measured enqueue interval.
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool injectMismatch = args.Contains("--inject-mismatch", StringComparer.Ordinal);
        var paths = args.Where(arg => arg != "--inject-mismatch").ToArray();
        string project = paths.Length == 1 ? Path.GetFullPath(paths[0]) : FindProject();
        string output = Path.Combine(project, "_output", DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fff") + "-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(output);
        using var context = new ApplicationContext();
        using var host = new HiddenHost();
        using var web = new WebView2 { Dock = DockStyle.Fill, TabStop = false };
        host.Controls.Add(web);
        _ = host.Handle;
        _ = web.Handle;
        var fixture = new Fixture(host, web, project, output, injectMismatch);
        int exitCode = 1;
        EventHandler? start = null;
        start = async (_, _) =>
        {
            Application.Idle -= start;
            try
            {
                await fixture.RunAsync().WaitAsync(TimeSpan.FromSeconds(120));
                exitCode = 0;
            }
            catch (Exception ex) { fixture.RecordFailure(ex); }
            finally
            {
                try { await fixture.ShutdownAsync(); }
                catch (Exception ex) { fixture.RecordFailure(ex); exitCode = 1; }
                fixture.Save(exitCode == 0);
                Console.WriteLine($"{(exitCode == 0 ? "PASS" : "FAIL")}: {Path.Combine(output, "result.json")}");
                context.ExitThread();
            }
        };
        Application.Idle += start;
        Application.Run(context);
        return exitCode;
    }

    private static string FindProject()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "Cage.Windows.Bridge.Tests.csproj"))) return dir.FullName;
        throw new InvalidOperationException("Pass the windows.bridge.tests directory as the only argument.");
    }
}

internal sealed class HiddenHost : Form
{
    public HiddenHost()
    {
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        Location = new System.Drawing.Point(-32000, -32000);
        Size = new System.Drawing.Size(640, 480);
        FormBorderStyle = FormBorderStyle.None;
    }
    protected override bool ShowWithoutActivation => true;
    protected override void SetVisibleCore(bool value) => base.SetVisibleCore(false);
    protected override CreateParams CreateParams
    {
        get { var value = base.CreateParams; value.ExStyle |= 0x08000000 | 0x00000080; return value; }
    }
}

internal sealed class Fixture
{
    private const string Root = "http://localhost:47893";
    private const string CrossRoot = "http://127.0.0.1:47893";
    private const string Owner = "10000000-0000-0000-0000-000000000001";
    private readonly HiddenHost host;
    private readonly WebView2 web;
    private readonly string output;
    private readonly bool injectMismatch;
    private readonly Dictionary<string, object?> report;
    private readonly List<object> checks = [];
    private readonly List<Measurement> bursts = [];
    private readonly List<Measurement> singles = [];
    private readonly List<string> failures = [];
    private readonly List<object> requests = [];
    private readonly Dictionary<string, Batch> batches = [];
    private readonly List<JsonElement> frameReports = [];
    private readonly TaskCompletionSource ready = NewSignal();
    private readonly TaskCompletionSource frames = NewSignal();
    private readonly TaskCompletionSource rpcRequestsReady = NewSignal();
    private readonly TaskCompletionSource rpcDone = NewSignal();
    private readonly TaskCompletionSource fatal = NewSignal();
    private readonly List<(string Id, int Index)> rpcRequests = [];
    private readonly System.Windows.Forms.Timer visibilityMonitor = new() { Interval = 20 };
    private int sent;
    private int received;
    private int rpcReplies;
    private int browserPid;
    private bool visibleObserved;
    private bool foregroundObserved;
    private CoreWebView2Environment? environment;

    public Fixture(HiddenHost host, WebView2 web, string project, string output, bool injectMismatch)
    {
        this.host = host;
        this.web = web;
        this.output = output;
        this.injectMismatch = injectMismatch;
        report = new()
        {
            ["startedUtc"] = DateTimeOffset.UtcNow,
            ["scope"] = "Local hidden WinForms host -> real WebView2 DOM -> host acknowledgement; not remote-desktop or physical-keyboard end-to-end acceptance.",
            ["runtime"] = RuntimeInformation.FrameworkDescription,
            ["os"] = RuntimeInformation.OSDescription,
            ["architecture"] = RuntimeInformation.ProcessArchitecture.ToString(),
            ["webView2Sdk"] = "1.0.4314.35",
            ["webView2Assembly"] = typeof(CoreWebView2).Assembly.GetName().Version?.ToString(),
            ["negativeControlInjectedMismatch"] = injectMismatch,
            ["compiledBridgeScriptSha256"] = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(NativeBridge.Script))).ToLowerInvariant(),
            ["productionNativeBridgeSha256"] = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.GetFullPath(Path.Combine(project, "../windows/NativeBridge.cs"))))).ToLowerInvariant(),
            ["profile"] = Path.Combine(output, "profile"),
            ["network"] = "All document resources intercepted locally; no HTTP listener, accounts, production service or installed client used.",
            ["method"] = "32-event warmup per path; six alternating-order 256-event bursts per path; 32 alternating-order isolated roundtrips per path. Enqueue includes serialization and API invocation; delivery is final DOM acknowledgement at host; baseline script result tasks are awaited outside enqueue. No timing pass threshold.",
        };
        visibilityMonitor.Tick += (_, _) => ObserveVisibility();
        visibilityMonitor.Start();
        ObserveVisibility();
    }

    public async Task RunAsync()
    {
        environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(output, "profile"),
            new CoreWebView2EnvironmentOptions("--disable-background-networking --disable-component-update --disable-sync --no-first-run"));
        await web.EnsureCoreWebView2Async(environment);
        var core = web.CoreWebView2;
        browserPid = (int)core.BrowserProcessId;
        report["browserProcessId"] = browserPid;
        report["webView2Runtime"] = core.Environment.BrowserVersionString;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.NewWindowRequested += (_, e) => e.Handled = true;
        core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
        core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += ResourceRequested;
        core.WebMessageReceived += MessageReceived;
        core.ProcessFailed += (_, e) => fatal.TrySetException(new InvalidOperationException($"WebView2 process failed: {e.ProcessFailedKind}"));
        await core.AddScriptToExecuteOnDocumentCreatedAsync(NativeBridge.Script);
        core.Navigate(Root + "/fixture");
        await Wait(ready.Task);
        await Wait(frames.Task);
        Check("production bridge injected into localhost top document", true);
        foreach (var frame in frameReports)
        {
            Check($"{frame.GetProperty("name").GetString()} iframe has no injected native bridge",
                !frame.GetProperty("ime").GetBoolean() && !frame.GetProperty("cage").GetBoolean(), frame);
        }
        Check("cross-origin iframe cannot access parent bridge", frameReports.Single(f => f.GetProperty("name").GetString() == "cross-origin").GetProperty("parentBlocked").GetBoolean());

        var correctness = new List<Dictionary<string, object?>>
        {
            new() { ["owner"] = Owner, ["kind"] = "compositionstart", ["text"] = null, ["selectionStart"] = 0, ["selectionEnd"] = 0 },
            new() { ["owner"] = Owner, ["kind"] = "compositionupdate", ["text"] = "ni\"'\\\n", ["selectionStart"] = 2, ["selectionEnd"] = 4 },
            new() { ["owner"] = Owner, ["kind"] = "compositionupdate", ["text"] = "你好😃e\u0301\u2028\u2029</script>", ["selectionStart"] = 4, ["selectionEnd"] = 4 },
            new() { ["owner"] = Owner, ["kind"] = "compositionend", ["text"] = "你好😃e\u0301\"'\\\n</script>", ["selectionStart"] = 0, ["selectionEnd"] = 0 },
            Key("keydown", "Enter", "Enter", false),
            Key("keyup", "Enter", "Enter", false),
            Key("keydown", "A", "KeyA", true),
            Key("keyup", "A", "KeyA", true),
            new() { ["owner"] = Owner, ["kind"] = "compositionstart", ["text"] = null, ["selectionStart"] = 0, ["selectionEnd"] = 0 },
            new() { ["owner"] = Owner, ["kind"] = "compositionend", ["text"] = "", ["selectionStart"] = 0, ["selectionEnd"] = 0 },
        };
        await SendBatch("message", "correctness-message", correctness);
        await SendBatch("script", "correctness-baseline", correctness);
        Check("Unicode quotes emoji combining characters newlines and script-like text preserved", true);
        Check("composition start updates commit cancellation followed by Enter remain ordered", true);
        Check("key modifiers including CapsLock and keyup remain unchanged", true);

        // Begin real pending RPC promises, then interleave input with reverse-order replies.
        await core.ExecuteScriptAsync("fixture.startRpc(24)");
        await Wait(rpcRequestsReady.Task);
        var concurrent = await SendBatch("message", "concurrent-rpc", Payloads(96), true);
        await Wait(rpcDone.Task);
        Check("24 concurrent RPC replies resolve correct promises without entering input stream", rpcReplies == 24);
        Check("96 ordered native inputs remain separate from concurrent RPC replies", concurrent.Count == 96);
        core.PostWebMessageAsJson("null");
        core.PostWebMessageAsJson("[]");
        core.PostWebMessageAsJson("{\"id\":\"not-pending\",\"result\":\"ignore\"}");
        core.PostWebMessageAsJson("{\"type\":\"cage-native-input\",\"detail\":null}");

        await SendBatch("script", "warmup-script", Payloads(32));
        await SendBatch("message", "warmup-message", Payloads(32));
        for (int round = 0; round < 6; round++)
            foreach (string mode in round % 2 == 0 ? new[] { "script", "message" } : new[] { "message", "script" })
                bursts.Add(await SendBatch(mode, $"burst-{round}-{mode}", Payloads(256), round: round));
        for (int round = 0; round < 32; round++)
            foreach (string mode in round % 2 == 0 ? new[] { "script", "message" } : new[] { "message", "script" })
                singles.Add(await SendBatch(mode, $"single-{round}-{mode}", Payloads(1), round: round));

        string summaryJson = await core.ExecuteScriptAsync("({count:fixture.count,errors:fixture.errors,hasBridge:!!window.webkit?.messageHandlers?.cage})");
        using var summary = JsonDocument.Parse(summaryJson);
        Check("every sent input acknowledged exactly once with exact detail and sequence", sent == received && summary.RootElement.GetProperty("count").GetInt32() == sent,
            new { sent, received, domCount = summary.RootElement.GetProperty("count").GetInt32() });
        Check("page has no JavaScript errors", summary.RootElement.GetProperty("errors").GetArrayLength() == 0, summary.RootElement.Clone());
        await Wait(Task.CompletedTask);
        ObserveVisibility();
        Check("host never became visible or foreground during sampled run", !visibleObserved && !foregroundObserved,
            new { visibleObserved, foregroundObserved, samplingMilliseconds = 20, alwaysHiddenOverride = true, noActivateWindowStyle = true });
        report["timingSummary"] = new
        {
            burst = Summaries(bursts),
            isolatedRoundtrip = Summaries(singles),
            interpretation = "Unloaded synthetic local transport measurement, one machine and one runtime. Lower is better; no end-to-end speedup or remote acknowledgement is inferred."
        };
    }

    private static Dictionary<string, object?> Key(string kind, string key, string code, bool capsLock) => new()
    {
        ["owner"] = Owner, ["kind"] = kind, ["key"] = key, ["code"] = code,
        ["textKey"] = key != "Enter", ["repeat"] = false, ["ctrlKey"] = false, ["altKey"] = false,
        ["shiftKey"] = false, ["metaKey"] = false, ["modifierCapsLock"] = capsLock
    };

    private static List<Dictionary<string, object?>> Payloads(int count) => Enumerable.Range(0, count)
        .Select(i => Key(i % 2 == 0 ? "keydown" : "keyup", i % 4 == 0 ? "😃" : "中\"'\\", "KeyA", i % 3 == 0)).ToList();

    private async Task<Measurement> SendBatch(string mode, string id, List<Dictionary<string, object?>> values, bool interleaveRpc = false, int round = -1)
    {
        var batch = new Batch(values.Count);
        batches.Add(id, batch);
        for (int i = 0; i < values.Count; i++)
        {
            var detail = new Dictionary<string, object?>(values[i]) { ["batch"] = id, ["seq"] = i };
            batch.Values.Add(detail);
            batch.Expected.Add(JsonSerializer.SerializeToElement(detail));
        }
        var scripts = new List<Task<string>>(values.Count);
        batch.Start = Stopwatch.GetTimestamp();
        for (int i = 0; i < batch.Values.Count; i++)
        {
            var detail = batch.Values[i];
            if (injectMismatch && id == "correctness-message" && i == 0)
                detail = new Dictionary<string, object?>(detail) { ["text"] = "deliberately corrupted by negative control" };
            if (mode == "message") web.CoreWebView2.PostWebMessageAsJson(NativeBridge.InputMessage(detail));
            else scripts.Add(web.CoreWebView2.ExecuteScriptAsync("window.dispatchEvent(new CustomEvent('cage-native-input',{detail:" + JsonSerializer.Serialize(detail) + "}));"));
            sent++;
            if (interleaveRpc && i < rpcRequests.Count)
            {
                var rpc = rpcRequests[^(i + 1)];
                web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new { id = rpc.Id, result = new { index = rpc.Index, text = "RPC中文😃\"'" } }));
                rpcReplies++;
            }
        }
        double enqueue = Stopwatch.GetElapsedTime(batch.Start).TotalMilliseconds;
        await Wait(batch.Done.Task);
        await Wait(Task.WhenAll(scripts));
        return new Measurement(mode, id, round, values.Count, enqueue, Stopwatch.GetElapsedTime(batch.Start, batch.Finished).TotalMilliseconds);
    }

    private void ResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        string uri = e.Request.Uri;
        bool allowed = uri == Root + "/fixture" || uri == Root + "/frame" || uri == CrossRoot + "/frame";
        requests.Add(new { uri, allowed });
        string content = uri == Root + "/fixture" ? Html : FrameHtml;
        e.Response = environment!.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes(allowed ? content : "Blocked by isolated fixture")), allowed ? 200 : 403,
            allowed ? "OK" : "Forbidden", "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n");
    }

    private void MessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            if (e.Source != Root + "/fixture") throw new InvalidOperationException("Unexpected native message source: " + e.Source);
            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            var message = document.RootElement;
            if (message.TryGetProperty("request", out var request))
            {
                if (request.GetProperty("action").GetString() != "fixtureRpc") throw new InvalidOperationException("Unexpected RPC action");
                rpcRequests.Add((message.GetProperty("id").GetString()!, request.GetProperty("index").GetInt32()));
                if (rpcRequests.Count == 24) rpcRequestsReady.TrySetResult();
                return;
            }
            switch (message.GetProperty("fixture").GetString())
            {
                case "ready":
                    if (!message.GetProperty("bridge").GetBoolean() || !message.GetProperty("ime").GetBoolean()) throw new InvalidOperationException("Production bridge missing at fixture load");
                    ready.TrySetResult();
                    break;
                case "frame":
                    frameReports.Add(message.Clone());
                    if (frameReports.Count == 2) frames.TrySetResult();
                    break;
                case "input":
                    var detail = message.GetProperty("detail");
                    var batch = batches[detail.GetProperty("batch").GetString()!];
                    int seq = detail.GetProperty("seq").GetInt32();
                    if (seq != batch.Received || !JsonElement.DeepEquals(detail, batch.Expected[seq])) throw new InvalidOperationException("Input lost, reordered, duplicated, or mutated");
                    batch.Received++;
                    received++;
                    if (batch.Received == batch.Count)
                    {
                        batch.Finished = Stopwatch.GetTimestamp();
                        batch.Done.TrySetResult();
                    }
                    break;
                case "rpcDone":
                    var results = message.GetProperty("results");
                    if (results.GetArrayLength() != 24) throw new InvalidOperationException("Missing RPC results");
                    for (int i = 0; i < results.GetArrayLength(); i++)
                        if (results[i].GetProperty("index").GetInt32() != i || results[i].GetProperty("text").GetString() != "RPC中文😃\"'") throw new InvalidOperationException("RPC reply mismatch");
                    rpcDone.TrySetResult();
                    break;
                case "error": throw new InvalidOperationException("Page error: " + message.GetProperty("message").GetString());
                default: throw new InvalidOperationException("Unexpected fixture message");
            }
        }
        catch (Exception ex) { fatal.TrySetException(ex); }
    }

    private async Task Wait(Task task)
    {
        Task winner = await Task.WhenAny(task, fatal.Task).WaitAsync(TimeSpan.FromSeconds(15));
        await winner;
        if (fatal.Task.IsCompleted) await fatal.Task;
    }

    private void Check(string name, bool passed, object? evidence = null)
    {
        checks.Add(new { name, passed, evidence });
        if (!passed) throw new InvalidOperationException("Check failed: " + name);
    }

    private void ObserveVisibility()
    {
        visibleObserved |= host.Visible || IsWindowVisible(host.Handle);
        foregroundObserved |= GetForegroundWindow() == host.Handle || host.ContainsFocus;
    }

    public async Task ShutdownAsync()
    {
        visibilityMonitor.Stop();
        visibilityMonitor.Dispose();
        ObserveVisibility();
        web.Dispose();
        host.Dispose();
        if (browserPid != 0)
        {
            // Closing this controller should terminate its isolated browser process.
            // Never terminate a shared/external process to make the test pass.
            try
            {
                using var process = Process.GetProcessById(browserPid);
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
            }
            catch (ArgumentException) { }
            Check("isolated WebView2 browser process exited after disposal", true);
        }
        report["finalVisibility"] = new { visibleObserved, foregroundObserved };
    }

    public void RecordFailure(Exception ex) { failures.Add(ex.ToString()); Console.Error.WriteLine(ex); }

    public void Save(bool passed)
    {
        report["passed"] = passed;
        report["finishedUtc"] = DateTimeOffset.UtcNow;
        report["checks"] = checks;
        report["inputSent"] = sent;
        report["inputReceived"] = received;
        report["rpcReplies"] = rpcReplies;
        report["frameReports"] = frameReports;
        report["resourceRequests"] = requests;
        report["bursts"] = bursts;
        report["isolatedRoundtrips"] = singles;
        report["failures"] = failures;
        File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static object Summaries(List<Measurement> measurements) => measurements.GroupBy(m => m.Mode).ToDictionary(g => g.Key, g => new
    {
        samples = g.Count(),
        enqueueMilliseconds = Stats(g.Select(m => m.EnqueueMilliseconds)),
        allAcknowledgedMilliseconds = Stats(g.Select(m => m.AllAcknowledgedMilliseconds))
    });

    private static object Stats(IEnumerable<double> values)
    {
        var sorted = values.Order().ToArray();
        return new { minimum = sorted[0], median = sorted.Length % 2 == 0 ? (sorted[sorted.Length / 2 - 1] + sorted[sorted.Length / 2]) / 2 : sorted[sorted.Length / 2],
            p95 = sorted[(int)Math.Ceiling(sorted.Length * .95) - 1], maximum = sorted[^1] };
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();

    private sealed class Batch(int count)
    {
        public int Count { get; } = count;
        public List<Dictionary<string, object?>> Values { get; } = [];
        public List<JsonElement> Expected { get; } = [];
        public int Received { get; set; }
        public long Start { get; set; }
        public long Finished { get; set; }
        public TaskCompletionSource Done { get; } = NewSignal();
    }

    private sealed record Measurement(string Mode, string Batch, int Round, int Count, double EnqueueMilliseconds, double AllAcknowledgedMilliseconds);

    private const string Html = """
        <!doctype html><meta charset="utf-8"><title>Isolated native input bridge fixture</title>
        <script>
        const post = value => chrome.webview.postMessage(value);
        window.fixture = {count:0,errors:[],startRpc(count) {
          Promise.all(Array.from({length:count},(_,index) => window.webkit.messageHandlers.cage.postMessage({action:'fixtureRpc',index})))
            .then(results => post({fixture:'rpcDone',results}))
            .catch(error => post({fixture:'error',message:String(error)}));
        }};
        window.addEventListener('error', event => { fixture.errors.push(String(event.error || event.message)); post({fixture:'error',message:String(event.error || event.message)}); });
        window.addEventListener('unhandledrejection', event => { fixture.errors.push(String(event.reason)); post({fixture:'error',message:String(event.reason)}); });
        window.addEventListener('cage-native-input', event => {
          fixture.count++;
          post({fixture:'input',detail:event.detail});
        });
        window.addEventListener('message', event => {
          if (event.data?.fixture === 'frame' && ['http://localhost:47893','http://127.0.0.1:47893'].includes(event.origin)) post(event.data);
        });
        post({fixture:'ready',bridge:!!window.webkit?.messageHandlers?.cage,ime:window.cageNativeIMEAvailable===true});
        </script>
        <iframe name="same-origin" src="http://localhost:47893/frame"></iframe>
        <iframe name="cross-origin" src="http://127.0.0.1:47893/frame"></iframe>
        """;

    private const string FrameHtml = """
        <!doctype html><meta charset="utf-8"><title>Subframe injection boundary</title>
        <script>
        let parentBlocked=false;
        try { void parent.webkit; } catch { parentBlocked=true; }
        parent.postMessage({fixture:'frame',name:window.name,ime:window.cageNativeIMEAvailable===true,cage:!!window.webkit?.messageHandlers?.cage,parentBlocked},'http://localhost:47893');
        </script>
        """;
}
