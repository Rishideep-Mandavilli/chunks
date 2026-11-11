// Chunks Bridge — background service worker.
//
// Holds one native-messaging port to the Chunks app's local host and shuttles commands to the active
// tab's content script. Local-only: native messaging is a stdio pipe to a process on this Mac, never a
// network connection. Every act is decided and consented in the app; this file only carries it out.

const HOST = "com.chunks.bridge";
let port = null;

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, 2000);
    return;
  }
  port.onMessage.addListener(onCommand);
  port.onDisconnect.addListener(() => {
    port = null;
    // The app may not be up yet, or may have relaunched; retry quietly.
    setTimeout(connect, 2000);
  });
}

function activeTab() {
  return chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => tabs[0]);
}

// Only web pages have a content script; chrome://, the new-tab page and store pages do not, and
// messaging them rejects with "Receiving end does not exist".
function isWeb(tab) {
  return !!tab && /^https?:/.test(tab.url || "");
}

function reply(id, ok, message, snapshot) {
  if (port) port.postMessage({ id, ok, message, snapshot: snapshot || null });
}

async function onCommand(cmd) {
  const { id, action } = cmd;
  try {
    if (action === "navigate") {
      const tab = await activeTab();
      if (!tab) return reply(id, false, "no active tab");
      await chrome.tabs.update(tab.id, { url: cmd.url });
      return reply(id, true, "navigated");
    }
    const tab = await activeTab();
    if (!isWeb(tab)) return reply(id, false, "the active tab is not a web page");
    const result = await chrome.tabs.sendMessage(tab.id, cmd);
    reply(id, !!result.ok, result.message || "", result.snapshot || null);
  } catch (e) {
    reply(id, false, "the page could not be reached: " + (e && e.message ? e.message : e));
  }
}

// Push a fresh snapshot whenever the page changes so the app's state digest sees the live DOM.
async function pushSnapshot() {
  try {
    const tab = await activeTab();
    if (!isWeb(tab) || !port) return;
    const result = await chrome.tabs.sendMessage(tab.id, { id: "push", action: "snapshot" });
    if (result && result.snapshot) reply("push", true, "", result.snapshot);
  } catch (e) {
    /* a chrome:// or unloaded tab has no content script; nothing to push */
  }
}

chrome.tabs.onActivated.addListener(pushSnapshot);
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "complete") pushSnapshot();
});

connect();