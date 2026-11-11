import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import vm from 'node:vm';

const source = await readFile(new URL('../desktop/windows/NativeBridge.cs', import.meta.url), 'utf8');
const script = source.match(/internal const string Script = """\s*([\s\S]*?)\s*""";/)?.[1];
assert.ok(script);

function bridge({ protocol = 'http:', hostname = 'localhost', frame = false } = {}) {
  let reply, sent;
  const timers = new Map(), events = [];
  const window = { dispatchEvent: event => events.push(event) };
  window.top = frame ? {} : window;
  vm.runInNewContext(script, {
    window, location: { protocol, hostname }, crypto: { randomUUID }, CustomEvent,
    chrome: { webview: {
      addEventListener: (_, callback) => { reply = callback; },
      postMessage: value => { sent = value; },
    } },
    setTimeout: (callback, delay) => { const id = randomUUID(); timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id),
  });
  return {
    call: request => window.webkit.messageHandlers.cage.postMessage(request),
    reply: value => reply({ data: { id: sent.id, ...value } }),
    message: data => reply({ data }),
    timers, events, window,
  };
}

test('native file replies remain pending beyond four minutes and through the backend deadline', async () => {
  for (const action of ['uploadHostFiles', 'chooseUploadFiles', 'clipboardSyncRead', 'clipboardSyncWrite',
    'saveBrowserDownload', 'browserDownloadAction', 'desktopFileAction', 'exportDiagnostics', 'importTheme', 'exportTheme',
    'shareLocalProject', 'chooseFolder', 'chooseGuestMedia']) {
    const fixture = bridge();
    const pending = fixture.call({ action });
    const timer = [...fixture.timers.values()][0];
    assert.ok(timer.delay > 30 * 60 * 1000, action);
    fixture.reply({ result: { saved: true } });
    assert.equal((await pending).saved, true, action);
    assert.equal(fixture.timers.size, 0);
  }
});

test('file failure reaches the caller and the following request can succeed', async () => {
  const fixture = bridge();
  const first = fixture.call({ action: 'saveBrowserDownload' });
  fixture.reply({ error: '磁盘空间不足' });
  await assert.rejects(first, /磁盘空间不足/);
  const second = fixture.call({ action: 'clipboardSyncRead' });
  fixture.reply({ result: { text: 'next copy' } });
  assert.equal((await second).text, 'next copy');
  assert.equal(fixture.timers.size, 0);
});

test('ordinary native commands retain their bounded timeout', async () => {
  const fixture = bridge();
  const pending = fixture.call({ action: 'accountDevice' });
  const timer = [...fixture.timers.values()][0];
  assert.equal(timer.delay, 240_000);
  timer.callback();
  await assert.rejects(pending, /原生操作超时/);
  fixture.reply({ result: true });
});

test('input events preserve order and payload without consuming an outstanding RPC', async () => {
  const fixture = bridge();
  const pending = fixture.call({ action: 'remoteInput', operation: 'activate' });
  const values = [
    { owner: randomUUID(), kind: 'compositionstart' },
    { owner: randomUUID(), kind: 'compositionupdate', text: '中文「输入」😀\\\"\n', selectionStart: 2, selectionEnd: 2 },
    { owner: randomUUID(), kind: 'compositionend', text: '中文😀' },
    { owner: randomUUID(), kind: 'keydown', key: 'Enter', code: 'Enter', modifierCapsLock: true, shiftKey: true },
    { owner: randomUUID(), kind: 'keyup', key: 'Enter', code: 'Enter', modifierCapsLock: true, shiftKey: false },
  ];
  // Deliberately include the pending RPC id: a notification must never settle it.
  for (const detail of values) fixture.reply({ type: 'cage-native-input', detail });
  assert.equal(fixture.timers.size, 1);
  assert.deepEqual(fixture.events.map(event => event.detail), values);
  assert.ok(fixture.events.every(event => event.type === 'cage-native-input'));
  fixture.reply({ result: true });
  assert.equal(await pending, true);
  assert.equal(fixture.timers.size, 0);
});

test('malformed and unrelated notifications do not dispatch input or consume RPCs', async () => {
  const fixture = bridge();
  const pending = fixture.call({ action: 'remoteInput', operation: 'caret' });
  for (const value of [null, undefined, 0, 'input', {}, { type: 'cage-native-input' },
    { type: 'cage-native-input', detail: null }, { type: 'cage-native-input', detail: 'bad' }]) fixture.message(value);
  assert.equal(fixture.events.length, 0);
  assert.equal(fixture.timers.size, 1);
  fixture.reply({ result: true });
  await pending;
});

test('bridge is installed only in the local top-level workbench document', () => {
  for (const options of [{ frame: true }, { protocol: 'https:' }, { hostname: 'localhost.example' }, { hostname: '127.0.0.1' }]) {
    const fixture = bridge(options);
    assert.equal(fixture.window.webkit, undefined);
    assert.equal(fixture.window.cageNativeIMEAvailable, undefined);
  }
});
