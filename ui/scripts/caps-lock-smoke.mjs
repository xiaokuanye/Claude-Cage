// Run `npm run prepare-vnc` in ui first. No Cage server or user session is used:
// every browser request is fulfilled from local UI modules or rejected.
// CAGE_PLAYWRIGHT_MODULE and CAGE_TEST_BROWSER_PATH select the test runtime.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.CAGE_PLAYWRIGHT_MODULE || "playwright");
const root = fileURLToPath(new URL("../", import.meta.url));
const origin = "http://localhost:51234";
const nativeBridge = (await readFile(new URL("../../desktop/windows/NativeBridge.cs", import.meta.url), "utf8"))
  .match(/internal const string Script = """\s*([\s\S]*?)\s*""";/)?.[1];
assert.ok(nativeBridge, "production Windows native bridge must be available");
const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.CAGE_TEST_BROWSER_PATH,
});
const checks = [];
const problems = [];

async function fixture(platform) {
  const page = await browser.newPage();
  page.on("pageerror", (error) => problems.push(error.message));
  await page.addInitScript((value) => {
    Object.defineProperty(navigator, "platform", { get: () => value });
    // The fixture uses production RFB methods but never opens a socket.
    window.WebSocket = class {
      constructor() { throw new Error("Network sockets are forbidden in this fixture"); }
    };
  }, platform);
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) {
      problems.push(`Unexpected external request: ${url.origin}`);
      await route.abort();
      return;
    }
    if (url.pathname === "/caps-lock-smoke") {
      await route.fulfill({ contentType: "text/html", body: '<div id="remote"><canvas width="1000" height="500" tabindex="-1"></canvas></div>' });
      return;
    }
    const relative = decodeURIComponent(url.pathname).slice(1);
    const file = path.resolve(root, relative);
    if (!file.startsWith(root) || !/^(src|\.generated\/novnc)\//.test(relative)) {
      problems.push(`Unexpected fixture request: ${url.pathname}`);
      await route.abort();
      return;
    }
    try {
      const body = await readFile(path.extname(file) ? file : `${file}.js`);
      await route.fulfill({ contentType: "text/javascript", body });
    } catch (error) {
      problems.push(`${url.pathname}: ${error.message}`);
      await route.abort();
    }
  });
  await page.goto(`${origin}/caps-lock-smoke`);
  await page.evaluate(async ({ platform, nativeBridge }) => {
    const [{ default: RFB }, { default: Keyboard }, { installRemoteInput }] = await Promise.all([
      import("/.generated/novnc/core/rfb.js"),
      import("/.generated/novnc/core/input/keyboard.js"),
      import("/src/remote-input.js"),
    ]);
    const container = document.querySelector("#remote");
    const rfb = new EventTarget();
    for (const name of ["sendKey", "_cageSendKey", "_cageQueueInput", "_handleKeyEvent", "cageSetKeyboardTarget", "focus", "blur"])
      rfb[name] = RFB.prototype[name].bind(rfb);
    rfb._canvas = container.querySelector("canvas");
    rfb._keyboard = new Keyboard(rfb._canvas);
    rfb._rfbConnectionState = "connected";
    rfb._remoteCapsLock = rfb._remoteNumLock = null;
    let bytes = [];
    const packets = [], observed = [], requests = [];
    rfb._sock = {
      sQpush8(value) { bytes.push(value); },
      sQpush16(value) { bytes.push((value >> 8) & 255, value & 255); },
      sQpush32(value) { bytes.push(value >>> 24, (value >> 16) & 255, (value >> 8) & 255, value & 255); },
      flush() { packets.push(bytes); bytes = []; },
    };
    window.cageNativeIMEAvailable = true;
    const nativeRequest = async (value) => {
      if (value.action === "clipboardRevision") return 0;
      if (value.action !== "remoteInput") throw new Error(`Unexpected native operation: ${value.action}`);
      requests.push(value);
      return true;
    };
    let publishInput = detail => window.dispatchEvent(new CustomEvent("cage-native-input", { detail }));
    if (platform === "Win32") {
      let receive;
      window.chrome.webview = {
        addEventListener: (_, callback) => { receive = callback; },
        postMessage: ({ id, request }) => {
          nativeRequest(request).then(result => receive({ data: { id, result } }));
        },
      };
      window.eval(nativeBridge);
      publishInput = detail => receive({ data: { type: "cage-native-input", detail } });
    } else window.webkit = { messageHandlers: { cage: { postMessage: nativeRequest } } };
    const input = installRemoteInput({
      events: rfb,
      setKeyboardTarget: (target) => rfb.cageSetKeyboardTarget(target),
      sendKey: (...key) => rfb.sendKey(...key),
      focus: () => rfb.focus(),
      pasteText() { throw new Error("ASCII key fixture must not use paste"); },
      runKeyAction: (action) => rfb._cageQueueInput(() => action((...key) => rfb._cageSendKey(...key))),
    }, container, {
      mode: () => /mac/i.test(platform) ? "mac" : "native",
      isActive: () => true,
      tabId: () => "fixture-tab",
      caretRect: async () => ({ available: true, context: "a".repeat(32), rect: [20, 20, 1, 24] }),
      onStatus() {}, onFallback() {},
      insertText() { throw new Error("ASCII key fixture must not use text insertion"); },
    });
    rfb.focus();
    const target = container.querySelector("textarea");
    target.addEventListener("keydown", (event) => {
      observed.push({ key: event.key, caps: event.getModifierState("CapsLock"), shift: event.shiftKey });
    }, true);
    window.probe = {
      requests, input,
      run({ remoteCapsLock, qemu = false, sequence }) {
        packets.length = 0;
        observed.length = 0;
        rfb._remoteCapsLock = remoteCapsLock;
        rfb._remoteNumLock = null;
        rfb._qemuExtKeyEventSupported = qemu;
        const owner = requests.find((value) => value.operation === "activate").owner;
        for (const value of sequence) {
          if (Object.hasOwn(value, "feedback")) {
            // A server LED-state reply arrives after the CapsLock press.
            rfb._remoteCapsLock = value.feedback;
          } else {
            publishInput({ owner, ...value });
          }
        }
        return {
          observed,
          keys: packets.map((packet) => ({
            sym: ((packet[4] << 24) | (packet[5] << 16) | (packet[6] << 8) | packet[7]) >>> 0,
            down: Boolean(packet[0] === 255 ? packet[3] : packet[1]),
            protocol: packet[0] === 255 ? "qemu" : "rfb",
          })),
        };
      },
    };
  }, { platform, nativeBridge });
  await page.waitForFunction(() => probe.requests.some((value) => value.operation === "activate"));
  return page;
}

const keyPair = (key, code, caps, shift = false) => ["keydown", "keyup"].map((kind) => ({
  kind, key, code, textKey: key.length === 1, shiftKey: shift,
  ...(caps === undefined ? {} : { modifierCapsLock: caps }),
}));
const expectKeys = (result, expected, label, qemu) => {
  assert.deepEqual(result.keys.map(({ sym, down }) => [sym, down]), expected, label);
  assert.ok(result.keys.every(({ protocol }) => protocol === (qemu ? "qemu" : "rfb")), label);
  checks.push(label);
};
const press = (sym) => [[sym, true], [sym, false]];

try {
  const windows = await fixture("Win32");
  for (const qemu of [false, true]) {
    const suffix = qemu ? "QEMU" : "RFB";
    const run = (remoteCapsLock, sequence) => windows.evaluate((value) => probe.run(value), { remoteCapsLock, qemu, sequence });
    const missing = await run(true, keyPair("A", "KeyA"));
    assert.equal(missing.observed[0].caps, false, "Missing native state defaults to false in a real KeyboardEvent");
    expectKeys(missing, [...press(0xffe5), ...press(65)], `negative control: omitted lock state wrongly toggles CapsLock (${suffix})`, qemu);

    const on = await run(true, keyPair("A", "KeyA", true));
    assert.equal(on.observed[0].caps, true);
    expectKeys(on, press(65), `Windows CapsLock on stays on (${suffix})`, qemu);
    const off = await run(false, keyPair("a", "KeyA", false));
    assert.equal(off.observed[0].caps, false);
    expectKeys(off, press(97), `Windows CapsLock off stays off (${suffix})`, qemu);

    expectKeys(await run(false, keyPair("A", "KeyA", true)), [...press(0xffe5), ...press(65)],
      `Windows local CapsLock on resynchronizes stale remote off (${suffix})`, qemu);
    expectKeys(await run(true, keyPair("a", "KeyA", false)), [...press(0xffe5), ...press(97)],
      `Windows local CapsLock off resynchronizes stale remote on (${suffix})`, qemu);

    expectKeys(await run(false, [
      ...keyPair("CapsLock", "CapsLock", true), { feedback: true }, ...keyPair("A", "KeyA", true),
      ...keyPair("CapsLock", "CapsLock", false), { feedback: false }, ...keyPair("a", "KeyA", false),
    ]), [...press(0xffe5), ...press(65), ...press(0xffe5), ...press(97)],
    `Windows CapsLock on/off sequence has no extra toggles after LED replies (${suffix})`, qemu);

    for (const caps of [false, true]) {
      const letter = caps ? "a" : "A";
      const shifted = await run(caps, [
        { kind: "keydown", key: "Shift", code: "ShiftLeft", modifierCapsLock: caps, shiftKey: true },
        ...keyPair(letter, "KeyA", caps, true),
        { kind: "keyup", key: "Shift", code: "ShiftLeft", modifierCapsLock: caps, shiftKey: false },
      ]);
      assert.ok(shifted.observed.every((event) => event.caps === caps && event.shift));
      expectKeys(shifted, [[0xffe1, true], ...press(letter.codePointAt(0)), [0xffe1, false]],
        `Windows ${caps ? "CapsLock+Shift lowercase" : "Shift uppercase"} preserves modifiers (${suffix})`, qemu);
    }
  }
  const stale = await windows.evaluate(sequence => probe.run({ remoteCapsLock: false, sequence }),
    keyPair("a", "KeyA", false).map(value => ({ ...value, owner: "old-owner" })));
  expectKeys(stale, [], "structured Windows input rejects stale owners", false);
  await windows.evaluate(() => probe.input.dispose());
  const disposed = await windows.evaluate(sequence => probe.run({ remoteCapsLock: false, sequence }), keyPair("a", "KeyA", false));
  expectKeys(disposed, [], "structured Windows input is ignored after disposal", false);
  await windows.close();

  const mac = await fixture("MacIntel");
  for (const caps of [true, false]) {
    const letter = caps ? "A" : "a";
    const result = await mac.evaluate((value) => probe.run(value), { remoteCapsLock: caps, sequence: keyPair(letter, "KeyA", caps) });
    assert.equal(result.observed[0].caps, caps);
    expectKeys(result, press(letter.codePointAt(0)), `existing macOS native payload preserves CapsLock ${caps ? "on" : "off"}`, false);
  }
  await mac.evaluate(() => probe.input.dispose());
  await mac.close();
  assert.deepEqual(problems, [], "The fixture must have no page errors or unexpected requests");
  console.log(JSON.stringify({
    passed: true,
    checks,
    coverage: "Real Chromium KeyboardEvent, production installRemoteInput native-event bridge, noVNC keyboard, RFB lock synchronization, and final wire encoding; in-memory transport only.",
    limitation: "Native Windows/GTK/AppKit event production, physical keyboard LED state, and remote X11 application behavior require separate runtime acceptance. Mac platform detection is simulated in Chromium, not WebKit.",
  }, null, 2));
} finally {
  await browser.close();
}
