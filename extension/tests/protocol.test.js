import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  HOST_NAME,
  PROTOCOL_VERSION,
  activeMessage,
  helloMessage,
  inventoryMessage,
  isOpenableURL,
  parseCommand,
  recordSent,
  tabClosedMessage,
  tabCreatedMessage,
  tabMovedMessage,
  tabReplacedMessage,
  tabUpdatedMessage,
} from "../protocol.js";

// The same files the Swift tests decode, so both sides agree on every message shape.
const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), "utf8"));

// Chrome objects carry more fields than the protocol sends; these extras must be dropped.
const chromeTab = (fields) => ({
  favIconUrl: "https://example.com/favicon.ico",
  status: "complete",
  pinned: false,
  audible: false,
  discarded: false,
  groupId: -1,
  incognito: false,
  windowId: 1,
  ...fields,
});

const docsTab = chromeTab({ id: 11, index: 0, active: false, url: "https://example.com/docs", title: "Docs", groupId: 3, lastAccessed: 1761580800000.5 });
const introTab = chromeTab({ id: 12, index: 1, active: true, url: "https://example.com/docs/intro", title: "Intro", openerTabId: 11, lastAccessed: 1761580900000 });

test("constants match the app", () => {
  assert.equal(HOST_NAME, "com.webby.bridge");
  assert.equal(PROTOCOL_VERSION, 1);
});

test("hello", () => {
  const message = helloMessage({ profile: "3f2504e0-4f89-41d3-9a0c-0305e82c3301", extVersion: "0.0.1", incognitoAllowed: false });
  assert.deepEqual(message, fixture("hello"));
});

test("inventory drops Chrome-only fields, groupless tabs' groupId and missing bounds", () => {
  const windows = [
    { id: 1, focused: true, incognito: false, alwaysOnTop: false, state: "normal", type: "normal", left: 0, top: 25, width: 1440, height: 875, tabs: [docsTab, introTab] },
    { id: 2, focused: false, incognito: true, alwaysOnTop: false, state: "normal", type: "normal", tabs: [chromeTab({ id: 21, index: 0, active: true, url: "chrome://newtab/", title: "New Tab", incognito: true, windowId: 2 })] },
  ];
  assert.deepEqual(inventoryMessage(windows), fixture("inventory"));
});

test("active carries the window and its incognito mode", () => {
  const { lastAccessed, ...tab } = introTab;
  assert.deepEqual(activeMessage(tab), fixture("active"));
  assert.equal(activeMessage({ ...tab, incognito: true, windowId: 2 }).incognito, true);
});

test("a tab that hasn't loaded yet reports empty URL and title", () => {
  const message = activeMessage(chromeTab({ id: 5, index: 0, active: true, url: undefined, title: undefined }));
  assert.equal(message.tab.url, "");
  assert.equal(message.tab.title, "");
});

test("tabCreated keeps the opener and uses the pending URL of a tab opened in the background", () => {
  const tab = chromeTab({ id: 13, index: 2, active: false, url: "", pendingUrl: "https://example.com/docs/setup", title: "", openerTabId: 12, status: "loading" });
  assert.deepEqual(tabCreatedMessage(tab), fixture("tabCreated"));
  assert.deepEqual(tabCreatedMessage(chromeTab({ id: 14, index: 0, active: true })), { type: "tabCreated", tab: { id: 14, windowId: 1, index: 0 } });
});

test("tabUpdated sends only what changed since the last message", () => {
  const changeInfo = { status: "loading", url: "https://example.com/docs/setup", title: "Setup" };
  assert.deepEqual(tabUpdatedMessage(12, changeInfo, { url: "https://example.com/docs/intro", title: "Intro" }), fixture("tabUpdated"));
  assert.deepEqual(tabUpdatedMessage(12, { title: "Setup" }, { url: "https://example.com/docs/setup", title: "Intro" }), { type: "tabUpdated", tabId: 12, title: "Setup" });
  assert.equal(tabUpdatedMessage(12, { url: "https://example.com/docs/setup" }, { url: "https://example.com/docs/setup" }), null);
  assert.equal(tabUpdatedMessage(12, { status: "complete", favIconUrl: "x" }), null);
  assert.deepEqual(tabUpdatedMessage(12, { url: "https://example.com/" }), { type: "tabUpdated", tabId: 12, url: "https://example.com/" });
});

test("tabClosed, tabMoved and tabReplaced", () => {
  assert.deepEqual(tabClosedMessage(13, false), fixture("tabClosed"));
  assert.deepEqual(tabMovedMessage(12, 2, 1), fixture("tabMoved"));
  assert.deepEqual(tabReplacedMessage(14, 12), fixture("tabReplaced"));
});

test("dedupe state follows every message that carries a URL or title", () => {
  let sent = recordSent({}, fixture("inventory"));
  assert.deepEqual(sent, {
    11: { url: "https://example.com/docs", title: "Docs" },
    12: { url: "https://example.com/docs/intro", title: "Intro" },
    21: { url: "chrome://newtab/", title: "New Tab" },
  });

  sent = recordSent(sent, fixture("tabUpdated"));
  assert.deepEqual(sent[12], { url: "https://example.com/docs/setup", title: "Setup" });
  assert.equal(tabUpdatedMessage(12, { url: "https://example.com/docs/setup" }, sent[12]), null);

  sent = recordSent(sent, { type: "tabUpdated", tabId: 12, title: "Setup, part 2" });
  assert.deepEqual(sent[12], { url: "https://example.com/docs/setup", title: "Setup, part 2" });

  sent = recordSent(sent, fixture("tabCreated"));
  assert.deepEqual(sent[13], { url: "https://example.com/docs/setup" });

  sent = recordSent(sent, fixture("tabReplaced"));
  assert.equal(sent[12], undefined);
  assert.deepEqual(sent[14], { url: "https://example.com/docs/setup", title: "Setup, part 2" });

  sent = recordSent(sent, fixture("tabClosed"));
  assert.equal(sent[13], undefined);

  const before = { ...sent };
  recordSent(sent, fixture("active"));
  assert.deepEqual(sent, before, "recordSent must not modify its input");
  assert.deepEqual(recordSent(sent, fixture("active"))[12], { url: "https://example.com/docs/intro", title: "Intro" });
  assert.equal(recordSent(sent, fixture("tabMoved")), sent);
});

test("valid commands parse to themselves", () => {
  for (const name of ["resend", "openTabs", "focusTab"]) {
    assert.deepEqual(parseCommand(fixture(name)), fixture(name), name);
  }
  assert.deepEqual(parseCommand({ type: "resend", extra: true }), { type: "resend" });
});

test("invalid commands are refused", () => {
  const invalid = [
    null,
    "resend",
    [],
    {},
    { type: "closeTab", id: 3 },
    { type: "openTabs" },
    { type: "openTabs", urls: [] },
    { type: "openTabs", urls: ["javascript:alert(1)"] },
    { type: "openTabs", urls: ["file:///etc/passwd"] },
    { type: "openTabs", urls: ["https://example.com/", "chrome://settings"] },
    { type: "openTabs", urls: [42] },
    { type: "focusTab" },
    { type: "focusTab", id: -1 },
    { type: "focusTab", id: 1.5 },
    { type: "focusTab", id: "3" },
  ];
  for (const value of invalid) {
    assert.equal(parseCommand(value), null, JSON.stringify(value));
  }
});

test("only web URLs can be opened", () => {
  assert.equal(isOpenableURL("https://example.com/a?b=c#d"), true);
  assert.equal(isOpenableURL("http://localhost:3000/"), true);
  assert.equal(isOpenableURL("data:text/html,hi"), false);
  assert.equal(isOpenableURL("not a url"), false);
});
