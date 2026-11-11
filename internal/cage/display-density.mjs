import { spawn, execFile } from "node:child_process";
import { existsSync, mkdirSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { setTimeout as pause } from "node:timers/promises";

const runFile = promisify(execFile);

// Chromium applies an XSETTINGS density in steps of 1/64.
export function displayDensity(value) {
  return typeof value === "number" && value >= 0.75 && value <= 4 ? Math.round(value * 64) / 64 : null;
}

export function densitySettings(scale) {
  const dpi = Math.round(scale * 96 * 1024);
  return `Xft/DPI ${dpi}\nGdk/WindowScalingFactor 1\nGdk/UnscaledDPI ${dpi}\n`;
}

// A display's pixel density is an XSETTINGS value, and Chromium follows a
// change without restarting. Each viewer can then have the density of its own
// screen. Without xsettingsd the display keeps the density it started with.
export function createDisplaySettings({
  file, initial, available = existsSync("/usr/bin/xsettingsd") && existsSync("/usr/bin/dump_xsettings"),
  start = () => spawn("/usr/bin/xsettingsd", ["--config=" + file], { stdio: "ignore" }),
  published = async scale => {
    const { stdout } = await runFile("/usr/bin/dump_xsettings", [], { timeout: 500 });
    return densitySettings(scale).trimEnd().split("\n").every(line => stdout.split("\n").includes(line));
  },
  restart = 1000,
}) {
  let scale = initial, child, timer, closed = false;
  const write = () => {
    writeFileSync(file + ".new", densitySettings(scale));
    renameSync(file + ".new", file);
  };
  const run = () => {
    const current = child = start();
    // Applications fall back to 96 DPI while no manager owns the settings.
    const ended = () => {
      if (child !== current) return;
      child = undefined;
      if (!closed) timer = setTimeout(run, restart);
    };
    current.on("error", ended);
    current.on("exit", ended);
  };
  if (available) {
    mkdirSync(path.dirname(file), { recursive: true });
    write();
    run();
  }
  return {
    available,
    get scale() { return scale; },
    set(value) {
      if (!available || value === scale) return scale;
      scale = value;
      write();
      // A manager that is being restarted reads the new file when it starts.
      child?.kill("SIGHUP");
      return scale;
    },
    // Writing a file or signalling a live manager does not establish that
    // applications can read the expected density from this X server yet.
    async waitForReady({ timeout = 3000, interval = 50 } = {}) {
      if (!available) return false;
      const deadline = Date.now() + timeout;
      do {
        if (closed) throw new Error("Display settings closed");
        const current = child, expected = scale;
        if (current && current.exitCode == null) {
          try {
            if (await published(expected) && child === current && scale === expected && current.exitCode == null) return true;
          } catch { /* The X server or manager may still be starting. */ }
        }
        if (Date.now() >= deadline) break;
        await pause(interval);
      } while (Date.now() < deadline);
      throw new Error("Display settings unavailable");
    },
    close() {
      closed = true;
      clearTimeout(timer);
      child?.kill();
    },
  };
}
