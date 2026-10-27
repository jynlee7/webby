// Extension protocol v1 (plan.md §5.1.7): pure message building, URL/title dedupe and
// command checks. background.js wires these to Chrome events; tests/protocol.test.js
// checks them against the fixtures the Swift tests also decode.
// scripts/check-extension.sh checks HOST_NAME and PROTOCOL_VERSION against the app.

export const HOST_NAME = "com.webby.bridge";
export const PROTOCOL_VERSION = 1;

const isId = (value) => Number.isInteger(value) && value >= 0;

/** A tab as `inventory` and `active` report it. */
export function tabInfo(tab) {
  const info = {
    id: tab.id,
    index: tab.index,
    active: tab.active,
    url: tab.url ?? "",
    title: tab.title ?? "",
  };
  if (isId(tab.openerTabId)) info.openerTabId = tab.openerTabId;
  if (isId(tab.groupId)) info.groupId = tab.groupId; // -1 means "not in a group"
  if (typeof tab.lastAccessed === "number") info.lastAccessed = tab.lastAccessed;
  return info;
}

export function windowInfo(win) {
  const info = { id: win.id, focused: win.focused, incognito: win.incognito };
  const { left, top, width, height } = win;
  if ([left, top, width, height].every(Number.isInteger)) {
    info.bounds = { left, top, width, height };
  }
  info.tabs = (win.tabs ?? []).map(tabInfo);
  return info;
}

export function helloMessage({ profile, extVersion, incognitoAllowed }) {
  return { type: "hello", v: PROTOCOL_VERSION, profile, extVersion, incognitoAllowed };
}

export function inventoryMessage(windows) {
  return { type: "inventory", windows: windows.map(windowInfo) };
}

export function activeMessage(tab) {
  return { type: "active", windowId: tab.windowId, incognito: tab.incognito, tab: tabInfo(tab) };
}

export function tabCreatedMessage(tab) {
  const info = { id: tab.id, windowId: tab.windowId, index: tab.index };
  // A tab opened from a link often has only a pending URL when it is created.
  const url = tab.url || tab.pendingUrl;
  if (url) info.url = url;
  if (tab.title) info.title = tab.title;
  if (isId(tab.openerTabId)) info.openerTabId = tab.openerTabId;
  return { type: "tabCreated", tab: info };
}

/**
 * A `tabUpdated` for the URL and title in `changeInfo` that differ from what was last
 * sent for the tab, or null when nothing new would be sent.
 */
export function tabUpdatedMessage(tabId, changeInfo, lastSent = {}) {
  const message = { type: "tabUpdated", tabId };
  if (typeof changeInfo.url === "string" && changeInfo.url !== lastSent.url) message.url = changeInfo.url;
  if (typeof changeInfo.title === "string" && changeInfo.title !== lastSent.title) message.title = changeInfo.title;
  return "url" in message || "title" in message ? message : null;
}

export function tabClosedMessage(tabId, windowClosing) {
  return { type: "tabClosed", tabId, windowClosing };
}

export function tabMovedMessage(tabId, windowId, index) {
  return { type: "tabMoved", tabId, windowId, index };
}

export function tabReplacedMessage(added, removed) {
  return { type: "tabReplaced", added, removed };
}

/**
 * The dedupe state after sending `message`: the last URL and title sent per tab ID.
 * Returns a new object; `sent` is not modified.
 */
export function recordSent(sent, message) {
  const remember = (state, id, fields) => {
    const entry = { ...state[id] };
    if (fields.url !== undefined) entry.url = fields.url;
    if (fields.title !== undefined) entry.title = fields.title;
    return { ...state, [id]: entry };
  };
  switch (message.type) {
    case "inventory": {
      let next = {};
      for (const win of message.windows) {
        for (const tab of win.tabs) next = remember(next, tab.id, tab);
      }
      return next;
    }
    case "active":
      return remember(sent, message.tab.id, message.tab);
    case "tabCreated":
      return remember(sent, message.tab.id, message.tab);
    case "tabUpdated":
      return remember(sent, message.tabId, message);
    case "tabClosed": {
      const { [message.tabId]: _closed, ...rest } = sent;
      return rest;
    }
    case "tabReplaced": {
      const { [message.removed]: entry, ...rest } = sent;
      return entry ? { ...rest, [message.added]: entry } : rest;
    }
    default:
      return sent;
  }
}

/** Only web pages may be opened on the app's behalf. */
export function isOpenableURL(value) {
  if (typeof value !== "string") return false;
  try {
    const { protocol } = new URL(value);
    return protocol === "http:" || protocol === "https:";
  } catch {
    return false;
  }
}

/** A validated command from the app, or null if it isn't one. */
export function parseCommand(value) {
  if (value === null || typeof value !== "object") return null;
  switch (value.type) {
    case "resend":
      return { type: "resend" };
    case "openTabs":
      if (!Array.isArray(value.urls) || value.urls.length === 0 || !value.urls.every(isOpenableURL)) return null;
      return { type: "openTabs", urls: [...value.urls] };
    case "focusTab":
      return isId(value.id) ? { type: "focusTab", id: value.id } : null;
    default:
      return null;
  }
}
