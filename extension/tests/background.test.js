import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

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
    windows: { getAll: async () => windows, onFocusChanged: event(), onBoundsChanged: event(), onRemoved: event(), onCreated: event(), WINDOW_ID_NONE: -1 },
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

test("focus lost to an inaccessible incognito window clears the reported focus", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.chrome.windows.getAll = async () => [{ id: 1, focused: false, incognito: false, tabs: [w.tab] }];
  w.chrome.windows.onFocusChanged.fire(-1);
  await w.drain();
  assert.equal(w.messages.at(-1).type, "inventory");
  assert.equal(w.messages.at(-1).windows[0].focused, false);
});

test("window movement publishes fresh bounds", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.chrome.windows.getAll = async () => [{ id: 1, focused: true, incognito: false, left: 42, top: 80, width: 1000, height: 700, tabs: [w.tab] }];
  w.chrome.windows.onBoundsChanged.fire({ id: 1 });
  await w.drain();
  assert.deepEqual(w.messages.at(-1).windows[0].bounds, { left: 42, top: 80, width: 1000, height: 700 });
});

// Shared with the Swift tests (TabBindingReconcilerTests), which replay it through the
// app's reducers.
const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), "utf8"));

test("a window that opens after the snapshot without focus is reported by an inventory", async () => {
  const w = await worker();
  const docs = { id: 10, windowId: 1, index: 0, active: true, incognito: false, url: "https://a.example/docs?id=4", title: "Docs" };
  const front = { id: 1, focused: true, incognito: false, left: 0, top: 25, width: 1200, height: 800, tabs: [docs] };
  w.chrome.windows.getAll = async () => [front];
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  const pricing = { id: 20, windowId: 2, index: 0, active: true, incognito: false, url: "https://b.example/pricing#annual", title: "Pricing" };
  const later = { id: 2, focused: false, incognito: false, left: 40, top: 65, width: 1000, height: 700, tabs: [pricing] };
  w.chrome.windows.getAll = async () => [front, later];
  w.chrome.windows.onCreated.fire(later);
  await w.drain();
  assert.deepEqual(w.messages.map((m) => m.type), ["hello", "inventory", "active", "inventory"]);
  assert.deepEqual(w.messages.at(-1).windows.map((win) => [win.id, win.focused, win.tabs.map((t) => t.url)]),
    [[1, true, ["https://a.example/docs?id=4"]], [2, false, ["https://b.example/pricing#annual"]]]);
});

// Recorded from Chrome for Testing 157 restoring two windows (see CHROME-VALIDATION.md).
// The first snapshot already lists every restored window; unloaded background tabs carry
// their address as the title until they load, about 2.6 s later.
test("session restore produces the recorded stream", async () => {
  const recorded = fixture("browser-session-restore-recording");
  const w = await worker();
  const [hello, inventory, active, ...updates] = recorded;
  w.chrome.runtime.getManifest = () => ({ version: hello.extVersion });
  w.chrome.windows.getAll = async () => inventory.windows.map(({ bounds, tabs, ...win }) => ({
    ...win, ...bounds, tabs: tabs.map((tab) => ({ ...tab, windowId: win.id, incognito: win.incognito })),
  }));
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  for (const update of updates) w.chrome.tabs.onUpdated.fire(update.tabId, { title: update.title });
  await w.drain();
  assert.deepEqual(w.messages, recorded);
  assert.equal(active.windowId, inventory.windows.find((win) => win.focused).id);
});

// The bridge replays its latest inventory to a relaunched Webby, which closes the note of
// any tab that inventory doesn't list.
test("a new tab is followed by an inventory that lists it", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  const created = { id: 2, windowId: 1, index: 1, active: true, incognito: false, url: "chrome://newtab/", title: "New Tab" };
  w.chrome.windows.getAll = async () => [{ id: 1, focused: true, incognito: false, tabs: [{ ...w.tab, active: false }, created] }];
  w.chrome.tabs.onCreated.fire(created);
  await w.drain();
  assert.deepEqual(w.messages.slice(-2).map((m) => m.type), ["tabCreated", "inventory"]);
  assert.deepEqual(w.messages.at(-1).windows[0].tabs.map((t) => t.id), [1, 2]);
});

test("a replaced tab is reported before the inventory that follows", async () => {
  const w = await worker();
  w.chrome.runtime.onStartup.fire();
  await w.drain();
  w.chrome.tabs.onReplaced.fire(5, 1);
  await w.drain();
  assert.deepEqual(w.messages.slice(-2).map((m) => m.type), ["tabReplaced", "inventory"]);
  assert.deepEqual(w.messages.at(-2), { type: "tabReplaced", added: 5, removed: 1 });
});
