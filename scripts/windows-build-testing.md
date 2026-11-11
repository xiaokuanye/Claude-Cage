# Windows packaging shutdown checks

The packaging smoke closes admission to new native helpers before draining
already admitted commands. Diagnostic helpers use the same bounded lifetime.
Only the explicit smoke shutdown operation may start after the drain. These
rules do not change the normal window-close behavior, which keeps user work
running, or enable application updates during a smoke test.

Run the targeted checks from a checkout with PowerShell 7, .NET 10 and Node:

```powershell
dotnet run --project desktop/windows.tests/Cage.Windows.Tests.csproj -c Release
dotnet build desktop/windows/Cage.Windows.csproj -c Release
pwsh -NoProfile -File scripts/windows-workbench-smoke.test.ps1
pwsh -NoProfile -File scripts/windows-build-move.test.ps1
node --test scripts/windows-native-bridge.test.mjs internal/cage/browser-clipboard.test.mjs
```

The helper tests launch synthetic child processes in an isolated profile. They
cover delayed exit, concurrent admission/close, timeouts, blocked pipes and
unrelated-process survival. MainWindow wiring is also checked as a source
contract; that is not a dynamic test of every WebView2 initialization race.
The move tests exercise real Windows file-sharing locks. Neither test should
terminate installed Cage processes or change an existing account/profile.

Full packaging, installation and GUI smoke acceptance belongs on a disposable
Windows runner via `scripts/ci-windows-build.ps1`. Do not run that installer
acceptance entry point against a workstation's existing Cage installation.
Both Windows 2022 and Windows 2025 jobs must pass before claiming CI acceptance.
macOS and Linux host protocols are unchanged by this Windows-only lifecycle
and file-sharing fix; Windows results do not establish native acceptance there.

## Relocation failure evidence

The build retains `cage-build-ui-*/smoke.json` and
`cage-build-diagnostics-*/diagnostics.json` under `RUNNER_TEMP` (or OS temp
outside CI). The workflow uploads only these public reports and the existing
installer fixture reports. Raw smoke data/profile files remain under the
smoke's `private/` directory on failure and are not uploaded. Successful smoke
cleanup removes the private directory but retains its public result through
the later packaging steps.

Relocation diagnostics contain bounded image paths, process IDs, parent IDs,
start times, native error codes and read-only Restart Manager results. They do
not contain command lines, environment variables, launch tokens or account
data. A missing process or empty lock query is not proof of who held an earlier
lock. Failed build stages are retained locally for inspection; do not upload
the entire stage or a private profile.

Same-volume relocation is atomic. Only confirmed sharing/lock violations
(native errors 32/33, including a file-level probe for a directory access-denied
result) receive bounded retries. Other errors fail immediately. Cross-volume
outputs retain the previous Move-Item behavior; once that move begins, failures
are not retried because the directory may already have moved partially. Inspect
the retained source, destination and previous-output backup before recovery.

The original CI failure did not record a lock owner. These fixes close known
lifecycle gaps and improve evidence; they do not identify that historical owner.
