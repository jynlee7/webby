// Webby extension service worker. Reports the active tab to the Mac app over
// native messaging. Implemented in step 4; this skeleton only logs startup.
const HOST = "com.webby.bridge";

chrome.runtime.onInstalled.addListener(() => {
  console.log(`Webby extension installed; native host: ${HOST}`);
});
