// Chunks Bridge — content script. Reads the DOM and carries out one consented click / type.
//
// It assigns each visible control a stable #index (a data attribute) so the app can name a target it
// saw in a snapshot and re-resolve the same control before acting. It never decides whether an act is
// allowed — that is the app's consent card; this file only performs what arrived approved.

const SELECTOR = "a, button, [role=button], input, textarea, select, [onclick]";
const MAX_ELEMENTS = 60;
const MAX_TEXT = 4000;

function visible(el) {
  const r = el.getBoundingClientRect();
  return r.width > 0 && r.height > 0;
}

function labelOf(el) {
  const t =
    (el.innerText || "") ||
    (el.value || "") ||
    (el.placeholder || "") ||
    (el.getAttribute("aria-label") || "") ||
    (el.title || "");
  return t.replace(/\s+/g, " ").trim().slice(0, 80);
}

function isEditable(el) {
  const tag = el.tagName.toLowerCase();
  return tag === "textarea" || (tag === "input" && !["button", "submit", "checkbox", "radio"].includes(el.type)) || el.isContentEditable;
}

function collect() {
  const nodes = Array.from(document.querySelectorAll(SELECTOR)).filter(visible);
  const elements = [];
  nodes.forEach((el, i) => {
    if (elements.length >= MAX_ELEMENTS) return;
    el.setAttribute("data-chunks-idx", String(i));
    elements.push({
      index: i,
      text: labelOf(el),
      role: el.tagName.toLowerCase(),
      selector: '[data-chunks-idx="' + i + '"]',
      editable: isEditable(el),
    });
  });
  return elements;
}

function snapshot() {
  return {
    url: location.href,
    title: document.title,
    text: (document.body ? document.body.innerText : "").replace(/\s+/g, " ").trim().slice(0, MAX_TEXT),
    elements: collect(),
  };
}

function resolve(query) {
  const elements = collect();
  const q = (query || "").trim();
  if (q.startsWith("#")) {
    const i = parseInt(q.slice(1), 10);
    return elements.find((e) => e.index === i) || null;
  }
  const needle = q.toLowerCase();
  const exact = elements.filter((e) => e.text.toLowerCase() === needle);
  if (exact.length === 1) return exact[0];
  const partial = elements.filter((e) => e.text.toLowerCase().includes(needle));
  if (partial.length === 1) return partial[0];
  return null;
}

function byIndex(i) {
  return document.querySelector('[data-chunks-idx="' + i + '"]');
}

chrome.runtime.onMessage.addListener((cmd, sender, sendResponse) => {
  try {
    if (cmd.action === "snapshot") {
      sendResponse({ ok: true, message: "", snapshot: snapshot() });
      return;
    }
    if (cmd.action === "click") {
      const target = resolve(cmd.query);
      if (!target) return sendResponse({ ok: false, message: "no control answers " + cmd.query });
      const el = byIndex(target.index);
      if (!el) return sendResponse({ ok: false, message: "the control is gone" });
      // Re-read before acting: the words must still be the ones the card approved.
      if (cmd.text && labelOf(el).toLowerCase() !== String(cmd.text).toLowerCase()) {
        return sendResponse({ ok: false, message: "the control changed since it was approved" });
      }
      el.click();
      sendResponse({ ok: true, message: "clicked " + target.text });
      return;
    }
    if (cmd.action === "type") {
      const target = resolve(cmd.query);
      if (!target) return sendResponse({ ok: false, message: "no field answers " + cmd.query });
      const el = byIndex(target.index);
      if (!el || !isEditable(el)) return sendResponse({ ok: false, message: "not a field" });
      el.focus();
      if (el.isContentEditable) {
        // A contentEditable div is not an input: the native value setter throws
        // "Illegal invocation" on it. Select all and insert text instead.
        const sel = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(el);
        sel.removeAllRanges();
        sel.addRange(range);
        document.execCommand("insertText", false, cmd.text);
        el.dispatchEvent(new Event("input", { bubbles: true }));
      } else {
        const proto = el.tagName.toLowerCase() === "textarea"
          ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
        setter.call(el, cmd.text);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
      }
      sendResponse({ ok: true, message: "typed into " + target.text });
      return;
    }
    sendResponse({ ok: false, message: "unknown action" });
  } catch (e) {
    sendResponse({ ok: false, message: String(e && e.message ? e.message : e) });
  }
});