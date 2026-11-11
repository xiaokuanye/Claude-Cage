import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import { promisify } from "node:util";
import test from "node:test";
import { createDisplaySettings, densitySettings, displayDensity } from "./display-density.mjs";

function fakeManager() {
  const child = new EventEmitter();
  child.signals = [];
  child.kill = signal => { child.killed = true; child.signals.push(signal ?? "SIGTERM"); return true; };
  return child;
}

test("densities are bounded and take Chromium's 1/64 steps", () => {
  assert.equal(displayDensity(2), 2);
  assert.equal(displayDensity(1.8), 1.796875);
  assert.equal(displayDensity(0.75), 0.75);
  for (const value of [0.74, 4.01, NaN, Infinity, "2", undefined, null]) assert.equal(displayDensity(value), null);
  assert.equal(densitySettings(1.5), "Xft/DPI 147456\nGdk/WindowScalingFactor 1\nGdk/UnscaledDPI 147456\n");
});

test("a change is written before the manager is told to reload", t => {
  const directory = mkdtempSync(join(tmpdir(), "cage-density-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, "settings", "xsettings.conf"), managers = [];
  const settings = createDisplaySettings({ file, initial: 2, available: true, start: () => { managers.push(fakeManager()); return managers.at(-1); } });
  assert.equal(readFileSync(file, "utf8"), densitySettings(2));
  assert.equal(settings.set(1.25), 1.25);
  assert.equal(readFileSync(file, "utf8"), densitySettings(1.25));
  assert.deepEqual(managers[0].signals, ["SIGHUP"]);
  // An unchanged density leaves applications alone.
  assert.equal(settings.set(1.25), 1.25);
  assert.deepEqual(managers[0].signals, ["SIGHUP"]);
  settings.close();
  assert.deepEqual(managers[0].signals, ["SIGHUP", "SIGTERM"]);
});

test("a manager that ends is started again with the current density", async t => {
  const directory = mkdtempSync(join(tmpdir(), "cage-density-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, "xsettings.conf"), managers = [];
  const settings = createDisplaySettings({ file, initial: 2, available: true, restart: 5, start: () => { managers.push(fakeManager()); return managers.at(-1); } });
  managers[0].emit("exit", 1);
  assert.equal(settings.set(1), 1);
  await pause(30);
  assert.equal(managers.length, 2);
  assert.equal(readFileSync(file, "utf8"), densitySettings(1));
  settings.close();
  managers[1].emit("exit", 0);
  await pause(30);
  assert.equal(managers.length, 2);
});

test("a display without a settings manager keeps its density", async () => {
  const settings = createDisplaySettings({ file: "/nonexistent/xsettings.conf", initial: 1.5, available: false,
    start: () => assert.fail("started"), published: () => assert.fail("probed") });
  assert.equal(settings.available, false);
  assert.equal(settings.set(1), 1.5);
  assert.equal(await settings.waitForReady(), false);
  settings.close();
});

function readinessFixture(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), "cage-density-"));
  const file = join(directory, "xsettings.conf"), managers = [];
  const settings = createDisplaySettings({ file, initial: 1.5, available: true,
    start: () => { managers.push(fakeManager()); return managers.at(-1); },
    published: async scale => readFileSync(file, "utf8") === densitySettings(scale),
    ...options,
  });
  t.after(() => { settings.close(); rmSync(directory, { recursive: true, force: true }); });
  return { settings, managers };
}

test("readiness checks publication, including after a harmless HUP", async t => {
  const { settings, managers } = readinessFixture(t);
  assert.equal(await settings.waitForReady(), true);
  settings.set(1.25);
  // ChildProcess.killed is also true after SIGHUP; it does not mean exit.
  assert.equal(managers[0].killed, true);
  assert.equal(await settings.waitForReady(), true);
});

test("a live manager is not ready until the expected settings publish", async t => {
  let published = false;
  const { settings } = readinessFixture(t, { published: async () => published });
  await assert.rejects(settings.waitForReady({ timeout: 15, interval: 2 }), /unavailable/);
  published = true;
  assert.equal(await settings.waitForReady(), true);
});

test("a failed publication query is retried within the readiness deadline", async t => {
  const { settings } = readinessFixture(t, { published: async () => { throw new Error("X server unavailable"); } });
  await assert.rejects(settings.waitForReady({ timeout: 15, interval: 2 }), /unavailable/);
});

test("an exited manager cannot acknowledge settings returned by an in-flight query", async t => {
  let manager;
  const { settings, managers } = readinessFixture(t, { restart: 1000,
    published: async () => { manager.emit("exit", 1); return true; } });
  manager = managers[0];
  await assert.rejects(settings.waitForReady({ timeout: 15, interval: 2 }), /unavailable/);
  settings.close();
  await assert.rejects(settings.waitForReady(), /closed/);
});

const browserSource = readFileSync(new URL("./browser-agent.mjs", import.meta.url), "utf8");
function browserResizeFixture({ available = true, ready = true, initial = 2 } = {}) {
  const calls = [], scales = [];
  const settings = { available, scale: initial,
    set(scale) { scales.push(scale); if (available) this.scale = scale; return this.scale; },
    async waitForReady() { if (available && !ready) throw new Error("not published"); },
  };
  const start = browserSource.indexOf("async function resizeDisplay("), end = browserSource.indexOf("\nlet mutations", start);
  assert.ok(start >= 0 && end > start);
  const resize = new Function("displaySettings", "displayScale", "displayDensity", "runFile",
    `let displaySize = "";\n${browserSource.slice(start, end)}\nreturn resizeDisplay;`)(
      settings, initial, displayDensity, async (path, args) => { calls.push({ path, args }); return { stdout: "" }; });
  return { resize, calls, scales };
}

test("browser waits for its initial settings before launching Chromium", () => {
  const wait = browserSource.indexOf("await displaySettings.waitForReady();");
  assert.ok(wait > browserSource.indexOf("const displaySettings ="));
  assert.ok(wait < browserSource.indexOf('const chrome = spawn("/usr/bin/chromium"'));
  assert.ok(browserSource.includes("const displayScale = config.display_scale === 1.5 ? 1.5 : 2;"));
});

test("browser applies same-size density changes while preserving display wake-up", async () => {
  const { resize, calls, scales } = browserResizeFixture({ initial: 1.5 });
  assert.deepEqual(await resize(1000, 700, 1), { ok: true, scale: 1 });
  const count = calls.length;
  assert.deepEqual(await resize(1000, 700, 1.25), { ok: true, scale: 1.25 });
  assert.deepEqual(scales, [1, 1.25]);
  assert.equal(calls.length, count + 1);
  assert.deepEqual(calls.at(-1).args, ["--output", "VNC-0", "--mode", "cage-1000x700"]);
  assert.deepEqual(await resize(2000, 1400), { ok: true, scale: 1.5 });
});

test("browser without settings keeps its configured density and omits acknowledgement", async () => {
  const { resize } = browserResizeFixture({ available: false, initial: 1.5 });
  assert.deepEqual(await resize(1500, 1050, 1), { ok: true });
  await assert.rejects(resize(200, 240, 1), /Invalid display size/);
});

test("browser does not resize or acknowledge unconfirmed settings", async () => {
  const { resize, calls } = browserResizeFixture({ ready: false });
  await assert.rejects(resize(1000, 700, 1), /not published/);
  assert.equal(calls.length, 0);
});

const tools = ["/usr/bin/Xtigervnc", "/usr/bin/xsettingsd", "/usr/bin/dump_xsettings"].every(existsSync);
test("xsettingsd publishes each density on a real display", { skip: !tools && "needs Xtigervnc and xsettingsd" }, async t => {
  // X socket paths are short; the repository may live in a deep directory.
  const directory = mkdtempSync(join(tmpdir(), "cgd-"));
  const display = `:${180 + process.pid % 400}`;
  const server = spawn("/usr/bin/Xtigervnc", [display, "-geometry", "640x480", "-depth", "24", "-rfbport", "-1", "-rfbunixpath", join(directory, "v"), "-nolisten", "tcp", "-SecurityTypes", "None", "-ac"], { stdio: "ignore" });
  const env = { ...process.env, DISPLAY: display };
  delete env.XAUTHORITY;
  let settings;
  t.after(() => { settings?.close(); server.kill(); rmSync(directory, { recursive: true, force: true }); });
  const published = async scale => {
    const { stdout } = await promisify(execFile)("/usr/bin/dump_xsettings", [], { env, timeout: 500 });
    return densitySettings(scale).trimEnd().split("\n").every(line => stdout.split("\n").includes(line));
  };
  const file = join(directory, "xsettings.conf");
  settings = createDisplaySettings({ file, initial: 2, available: true, published,
    start: () => spawn("/usr/bin/xsettingsd", ["--config=" + file], { env, stdio: "ignore" }) });
  assert.equal(await settings.waitForReady({ timeout: 5000 }), true);
  settings.set(1.25);
  assert.equal(await settings.waitForReady(), true);
});
