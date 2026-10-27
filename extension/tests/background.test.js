import test from "node:test";
import assert from "node:assert/strict";

function event() {
  const listeners = [];
  return { addListener: (fn) => listeners.push(fn), fire: (...args) => listeners.forEach((fn) => fn(...args)) };
}

let serial = 0;
async function worker() {
  const messages = [];
  const ports = [];
  const tab = { id: 1, windowId: 1, index: 0, active: true, incognito: false, url: "https://example.com/new", title: "New" };
  const windows = [{ id: 1, focused: true, incognito: false, tabs: [tab] }];
  globalThis.chrome = {
    runtime: {
      onStartup: event(), onInstalled: event(), getManifest: () => ({ version: "1" }),
      connectNative() {
        const port = { onMessage: event(), onDisconnect: event(), postMessage: (msg) => messages.push(msg), disconnect() {} };
        ports.push(port);
        return port;
      },
    },
    storage: {
      local: { get: async () => ({ profileKey: "3f2504e0-4f89-41d3-9a0c-0305e82c3301" }) },
      session: { get: async () => { throw new Error("quota storage must not be needed"); } },
    },
    extension: { isAllowedIncognitoAccess: async () => false },
    windows: { getAll: async () => windows, onFocusChanged: event(), WINDOW_ID_NONE: -1 },
    tabs: Object.fromEntries(["onActivated", "onCreated", "onUpdated", "onRemoved", "onMoved", "onAttached", "onReplaced"].map((name) => [name, event()])),
  };
  await import(`../background.js?test=${serial++}`);
  const drain = async () => { for (let i = 0; i < 10; i++) await new Promise(setImmediate); };
  return { chrome, messages, ports, tab, drain };
}

test("reconnect snapshot is not overwritten by the older triggering event", async () => {
  const w = await worker();
  w.chrome.tabs.onUpdated.fire(1, { url: "https://example.com/old" });
  w.chrome.tabs.onUpdated.fire(1, { url: "https://example.com/also-old" });
  await w.drain();
  assert.deepEqual(w.messages.map((m) => m.type), ["hello", "inventory", "active"]);
  assert.equal(w.messages.at(-1).tab.url, w.tab.url);
});

test("a deduplicated update still reconnects and a snapshot needs no session storage", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.ports[0].onDisconnect.fire();
  w.chrome.tabs.onUpdated.fire(1, { url: w.tab.url });
  await w.drain();
  assert.equal(w.ports.length, 2);
  assert.deepEqual(w.messages.map((m) => m.type), ["hello", "inventory", "active", "hello", "inventory", "active"]);
  w.chrome.tabs.onUpdated.fire(1, { url: w.tab.url });
  await w.drain();
  assert.equal(w.messages.length, 6);
});

test("native host disconnect reconnects without waiting for a browser event", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.ports[0].onDisconnect.fire();
  await new Promise((resolve) => setTimeout(resolve, 1100));
  await w.drain();
  assert.equal(w.ports.length, 2);
  assert.equal(w.messages.at(-1).type, "active");
});

test("a host that keeps failing is retried less and less often", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  // As when Webby isn't installed: every connection drops at once.
  for (const delay of [1000, 2000, 4000]) {
    w.ports.at(-1).onDisconnect.fire();
    const count = w.ports.length;
    t.mock.timers.tick(delay - 1);
    await w.drain();
    assert.equal(w.ports.length, count);
    t.mock.timers.tick(1);
    await w.drain();
    assert.equal(w.ports.length, count + 1);
  }
});

test("activation reads the current active tab after rapid switches", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.chrome.tabs.query = async () => [w.tab];
  w.chrome.tabs.onActivated.fire({ tabId: 99, windowId: 1 });
  await w.drain();
  assert.equal(w.messages.at(-1).type, "active");
  assert.equal(w.messages.at(-1).tab.id, 1);
});

test("failed initial snapshot is retried on the next event", async () => {
  const w = await worker();
  const getAll = w.chrome.windows.getAll;
  w.chrome.windows.getAll = async () => { throw new Error("temporary API failure"); };
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.chrome.windows.getAll = getAll;
  w.chrome.tabs.onUpdated.fire(1, { title: "older title" });
  await w.drain();
  assert.equal(w.ports.length, 2);
  assert.deepEqual(w.messages.map((m) => m.type), ["hello", "inventory", "active"]);
});
