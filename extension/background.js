// Webby extension service worker. Reports tabs to the Webby Mac app over native messaging
// and carries out the app's commands. Listeners are registered at the top level so Chrome
// can wake the worker for them, and the open native port keeps the worker alive. No
// persistent identity lives in globals: after a restart the worker reconnects on the next
// event and sends a fresh hello, inventory and active tab.
import {
  HOST_NAME,
  activeMessage,
  helloMessage,
  inventoryMessage,
  parseCommand,
  recordSent,
  tabClosedMessage,
  tabCreatedMessage,
  tabMovedMessage,
  tabReplacedMessage,
  tabUpdatedMessage,
} from "./protocol.js";

const MIN_RECONNECT_DELAY = 1000;
const MAX_RECONNECT_DELAY = 60_000;
// A connection that stays up this long was working, so the next retry starts over.
const HEALTHY_CONNECTION = 10_000;

let port = null;
let queue = Promise.resolve();
let sent = {};
let reconnectTimer = null;
let reconnectDelay = MIN_RECONNECT_DELAY;
let eventSerial = 0;
let snapshotThrough = 0;

// Runs tasks one at a time, so messages reach the app in event order.
function enqueue(task) {
  queue = queue.then(task).catch((error) => console.warn("Webby:", error));
}

// Events already represented by a snapshot must not replay older captured fields.
function enqueueBrowserEvent(task) {
  const serial = ++eventSerial;
  enqueue(() => serial > snapshotThrough ? task() : undefined);
}

// A random key per Chrome profile, kept across restarts, so the app can tell profiles apart.
async function profileKey() {
  const { profileKey: stored } = await chrome.storage.local.get("profileKey");
  if (typeof stored === "string" && stored) return stored;
  const key = crypto.randomUUID();
  await chrome.storage.local.set({ profileKey: key });
  return key;
}

// Retries a dropped connection, waiting longer each time it keeps failing (for example
// while Webby isn't installed), so a missing host doesn't keep the worker busy.
function scheduleReconnect() {
  reconnectTimer = setTimeout(() => enqueue(ensureConnected), reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
}

async function connect() {
  if (reconnectTimer !== null) clearTimeout(reconnectTimer);
  reconnectTimer = null;
  const next = chrome.runtime.connectNative(HOST_NAME);
  const openedAt = Date.now();
  next.onMessage.addListener((message) => enqueue(() => runCommand(message)));
  next.onDisconnect.addListener(() => {
    if (port === next) {
      port = null;
      if (Date.now() - openedAt >= HEALTHY_CONNECTION) reconnectDelay = MIN_RECONNECT_DELAY;
      scheduleReconnect();
    }
    console.warn("Webby: native host disconnected:", chrome.runtime.lastError?.message ?? "no error");
  });
  port = next;
  try {
    await sendSnapshot();
  } catch (error) {
    if (port === next) port = null;
    next.disconnect();
    scheduleReconnect();
    throw error;
  }
}

async function ensureConnected() {
  if (port) return false;
  await connect();
  return true;
}

// Dedupe is scoped to this worker and rebuilt by every snapshot. Keeping it in memory
// avoids storage.session quota failures interrupting delivery for large inventories.
async function post(message) {
  if (!port) return;
  port.postMessage(message);
  sent = recordSent(sent, message);
}

async function send(message) {
  // A new snapshot already includes this event and may include newer changes.
  if (await ensureConnected()) return;
  await post(message);
}

async function sendSnapshot() {
  const through = eventSerial;
  const [profile, incognitoAllowed, windows] = await Promise.all([
    profileKey(),
    chrome.extension.isAllowedIncognitoAccess(),
    chrome.windows.getAll({ populate: true }),
  ]);
  await post(helloMessage({ profile, extVersion: chrome.runtime.getManifest().version, incognitoAllowed }));
  await post(inventoryMessage(windows));
  const tab = windows.find((win) => win.focused)?.tabs?.find((t) => t.active);
  if (tab) await post(activeMessage(tab));
  if (port) snapshotThrough = through;
}

async function runCommand(value) {
  const command = parseCommand(value);
  if (!command) {
    console.warn("Webby: ignoring an invalid command from the app");
    return;
  }
  switch (command.type) {
    case "resend":
      await sendSnapshot();
      break;
    case "openTabs":
      await chrome.windows.create({ url: command.urls });
      break;
    case "focusTab": {
      const tab = await chrome.tabs.update(command.id, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
      break;
    }
  }
}

chrome.runtime.onStartup.addListener(() => enqueue(ensureConnected));
chrome.runtime.onInstalled.addListener(() => enqueue(ensureConnected));

chrome.tabs.onActivated.addListener(({ windowId }) => {
  enqueueBrowserEvent(async () => {
    // The originally activated tab may already be closed or inactive by queue time.
    const [tab] = await chrome.tabs.query({ active: true, windowId });
    if (tab) await send(activeMessage(tab));
  });
});

// Refresh window focus and bounds, including focus lost to an inaccessible private
// window. An inventory with no focused window clears the previous page in the app.
async function refreshWindows() {
  if (await ensureConnected()) return;
  await post(inventoryMessage(await chrome.windows.getAll({ populate: true })));
}

chrome.windows.onFocusChanged.addListener(() => enqueueBrowserEvent(refreshWindows));
chrome.windows.onBoundsChanged.addListener(() => enqueueBrowserEvent(refreshWindows));
chrome.windows.onRemoved.addListener(() => enqueueBrowserEvent(refreshWindows));

chrome.tabs.onCreated.addListener((tab) => {
  enqueueBrowserEvent(() => send(tabCreatedMessage(tab)));
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (!("url" in changeInfo) && !("title" in changeInfo)) return;
  enqueueBrowserEvent(async () => {
    if (await ensureConnected()) return;
    const message = tabUpdatedMessage(tabId, changeInfo, sent[tabId]);
    if (message) await post(message);
  });
});

chrome.tabs.onRemoved.addListener((tabId, { isWindowClosing }) => {
  enqueueBrowserEvent(() => send(tabClosedMessage(tabId, isWindowClosing)));
});

chrome.tabs.onMoved.addListener((tabId, { windowId, toIndex }) => {
  enqueueBrowserEvent(refreshWindows);
});

chrome.tabs.onAttached.addListener((tabId, { newWindowId, newPosition }) => {
  enqueueBrowserEvent(async () => {
    await send(tabMovedMessage(tabId, newWindowId, newPosition));
    await refreshWindows();
  });
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  enqueueBrowserEvent(async () => {
    await send(tabReplacedMessage(addedTabId, removedTabId));
    await refreshWindows();
  });
});
