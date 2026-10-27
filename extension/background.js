// Webby extension service worker. Reports tabs to the Webby Mac app over native messaging
// and carries out the app's commands. Listeners are registered at the top level so Chrome
// can wake the worker for them, and the open native port keeps the worker alive. No
// essential state lives in globals: after a restart the worker reconnects on the next
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

let port = null;
let queue = Promise.resolve();

// Runs tasks one at a time, so messages reach the app in event order.
function enqueue(task) {
  queue = queue.then(task).catch((error) => console.warn("Webby:", error));
}

// A random key per Chrome profile, kept across restarts, so the app can tell profiles apart.
async function profileKey() {
  const { profileKey: stored } = await chrome.storage.local.get("profileKey");
  if (typeof stored === "string" && stored) return stored;
  const key = crypto.randomUUID();
  await chrome.storage.local.set({ profileKey: key });
  return key;
}

async function connect() {
  const next = chrome.runtime.connectNative(HOST_NAME);
  next.onMessage.addListener((message) => enqueue(() => runCommand(message)));
  next.onDisconnect.addListener(() => {
    if (port === next) port = null;
    console.warn("Webby: native host disconnected:", chrome.runtime.lastError?.message ?? "no error");
  });
  port = next;
  await sendSnapshot();
}

async function ensureConnected() {
  if (!port) await connect();
}

// Posts on the current port and records what was sent for dedupe. If the port is gone,
// the message is dropped: the next event reconnects and sends a fresh snapshot.
async function post(message) {
  if (!port) return;
  port.postMessage(message);
  const { sent = {} } = await chrome.storage.session.get("sent");
  await chrome.storage.session.set({ sent: recordSent(sent, message) });
}

async function send(message) {
  await ensureConnected();
  await post(message);
}

async function sendSnapshot() {
  const [profile, incognitoAllowed, windows] = await Promise.all([
    profileKey(),
    chrome.extension.isAllowedIncognitoAccess(),
    chrome.windows.getAll({ populate: true }),
  ]);
  await post(helloMessage({ profile, extVersion: chrome.runtime.getManifest().version, incognitoAllowed }));
  await post(inventoryMessage(windows));
  const tab = windows.find((win) => win.focused)?.tabs?.find((t) => t.active);
  if (tab) await post(activeMessage(tab));
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

chrome.tabs.onActivated.addListener(({ tabId }) => {
  enqueue(async () => send(activeMessage(await chrome.tabs.get(tabId))));
});

chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  enqueue(async () => {
    const [tab] = await chrome.tabs.query({ active: true, windowId });
    if (tab) await send(activeMessage(tab));
  });
});

chrome.tabs.onCreated.addListener((tab) => {
  enqueue(() => send(tabCreatedMessage(tab)));
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (!("url" in changeInfo) && !("title" in changeInfo)) return;
  enqueue(async () => {
    const { sent = {} } = await chrome.storage.session.get("sent");
    const message = tabUpdatedMessage(tabId, changeInfo, sent[tabId]);
    if (message) await send(message);
  });
});

chrome.tabs.onRemoved.addListener((tabId, { isWindowClosing }) => {
  enqueue(() => send(tabClosedMessage(tabId, isWindowClosing)));
});

chrome.tabs.onMoved.addListener((tabId, { windowId, toIndex }) => {
  enqueue(() => send(tabMovedMessage(tabId, windowId, toIndex)));
});

chrome.tabs.onAttached.addListener((tabId, { newWindowId, newPosition }) => {
  enqueue(() => send(tabMovedMessage(tabId, newWindowId, newPosition)));
});

chrome.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
  enqueue(() => send(tabReplacedMessage(addedTabId, removedTabId)));
});
