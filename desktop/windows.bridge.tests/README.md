# Real WebView2 native-input transport fixture

## Transport change and scope

The Windows host now sends native key/composition events with `PostWebMessageAsJson` instead of executing a new JavaScript string for every event. A document-created bridge dispatches the existing `cage-native-input` DOM event. Payloads, owner checks, Caps Lock state, event order, RPC replies and file-command deadlines retain their existing contracts; keyboard events are not batched, throttled or dropped by this change.

Only the Windows host implementation changes. Shared frontend production code, macOS/Linux hosts, guest rendering, mobile clients and SSH transport are unchanged. macOS/Linux native runtimes have not been tested for this patch; Chromium platform simulation is not native macOS acceptance.

## Running the fixture

Windows-only integration test, linking the production `../windows/NativeBridge.cs` (not a copied bridge). Requires the .NET 10 SDK and an installed WebView2 runtime. It does not install or update either dependency.

```powershell
dotnet run --project desktop/windows.bridge.tests/Cage.Windows.Bridge.Tests.csproj -c Release
```

An optional `-- --inject-mismatch` negative control intentionally corrupts the first native-input payload after preparing the expected value. It must produce a failed `result.json`, dispose its isolated browser, and return exit code 1. It does not change production code. Run the normal command afterwards to reconfirm a clean pass.

The host creates a permanently hidden, no-activation WinForms window and an isolated WebView2 profile under this project's `_output/<unique-run>/profile`. All web document requests are intercepted in-process; the localhost fixture URLs have no listening server. No installed Cage process, production profile, account, cloud service, or real keyboard is used. Profiles and `result.json` are retained for audit. A failed assertion, timeout, script error, or failure to shut down the isolated browser returns a nonzero exit code.

Checks cover exact Unicode/quotation/emoji detail preservation, event order, composition updates/commit/cancel and Enter, key modifiers, concurrent request/reply isolation, and absence of the injected bridge inside both same-origin and cross-origin iframes. The cross-origin iframe also checks that it cannot access the parent's bridge. A same-origin frame shares its parent's origin and can access parent objects by normal browser rules; this test does not claim to sandbox same-origin scripts.

After warmup, six pairs of 256-event bursts alternate path order. Another 32 pairs measure isolated single-event roundtrips. Baseline dispatches the previous per-event `ExecuteScriptAsync` DOM event without awaiting each event before the next enqueue. The new path calls production `NativeBridge.InputMessage` and `PostWebMessageAsJson`. Both include JSON serialization in host enqueue timing and use the same DOM event handler and host acknowledgement. Baseline script tasks are checked outside the enqueue interval. `result.json` contains each sample, min/median/p95/max, runtime versions, production source hash, visibility checks, and failures. Timing has no hardware-dependent pass threshold.

This measures local host-to-WebView2 DOM delivery and its acknowledgement only. It is not real IME/keyboard acceptance, remote-input ownership verification, RFB/remote-render timing, or an end-to-end performance claim.

## Measured example

Two clean runs on 2026-11-11 with Windows x64, .NET 10.0.12 and WebView2 157.0.4341.42 each delivered all 3,316 input payloads in order and resolved 24 interleaved RPCs. The hidden host was never observed visible or foreground, and each isolated browser exited after disposal. Between those runs, `--inject-mismatch` correctly failed with exit code 1 and also shut down its browser.

Each table cell is the run's median in milliseconds, shown as **script / message**; lower is better. Burst medians use six samples per path, isolated medians use 32.

| Local measurement | Run 1 | Run 2 |
| --- | ---: | ---: |
| 256-event host enqueue | 2.792 / 3.564 | 2.676 / 3.743 |
| 256-event delivery and acknowledgement | 15.396 / 7.704 | 13.874 / 8.030 |
| Single-event delivery and acknowledgement | 0.190 / 0.131 | 0.189 / 0.135 |

The burst delivery path improved in these samples, while host enqueue was slower. Single-event savings were only about 0.05 ms. These synthetic, single-machine measurements do not establish a remote-desktop speedup or a stable tail-latency improvement. Physical keyboard/IME behavior, WebView recreation, existing-server combinations and input-to-visible-frame latency require separate runtime acceptance.

Related regression commands (from the repository root):

```powershell
node --test scripts/windows-native-bridge.test.mjs
dotnet run --project desktop/windows.tests/Cage.Windows.Tests.csproj -c Release
```

The browser regression is `ui/scripts/caps-lock-smoke.mjs`; first run `npm run prepare-vnc` from `ui`. It requires Playwright plus an installed browser, optionally selected with `CAGE_PLAYWRIGHT_MODULE` and `CAGE_TEST_BROWSER_PATH`. It routes requests to local modules and uses in-memory RFB/QEMU encoding, with no production account or remote session.
