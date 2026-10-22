/*
 * Icy Weasel — password saving.
 *
 * Runs in the browser's isolated content world: it shares the page's DOM but
 * none of its JavaScript, so the page can't see it, call it or fake its messages.
 *
 * It only reports two things to the browser:
 *  - "formFound": this frame shows a password field (the browser then offers
 *    its key button; filling happens only when the user clicks it).
 *  - "submitted": the user, with a real click or Enter, submitted a password.
 *    Synthetic events (isTrusted false) are ignored, so a page can't make the
 *    browser offer to save credentials it invented.
 * The browser takes the site from WebKit's own record of the frame's origin,
 * never from anything this script says.
 */
(function () {
  "use strict";
  if (window.__icyWeaselPasswords) return;
  window.__icyWeaselPasswords = true;
  const handlers = window.webkit && window.webkit.messageHandlers;
  const handler = handlers && handlers.icyWeaselPasswords;
  if (!handler) return;
  const post = (message) => { try { handler.postMessage(message); } catch (e) {} };

  function visible(el) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none";
  }

  function passwordFields(scope) {
    return Array.from((scope || document).querySelectorAll('input[type="password"]')).filter(visible);
  }

  function usernameFieldFor(pw) {
    const scope = pw.form || document;
    const tagged = scope.querySelector('input[autocomplete~="username"], input[autocomplete~="email"]');
    if (tagged && tagged !== pw && visible(tagged)) return tagged;
    const inputs = Array.from(scope.querySelectorAll("input"));
    for (let i = inputs.indexOf(pw) - 1; i >= 0; i--) {
      const type = (inputs[i].getAttribute("type") || "text").toLowerCase();
      if (["text", "email", "tel"].includes(type) && visible(inputs[i])) return inputs[i];
    }
    return null;
  }

  let lastSent = "";
  function capture(pw) {
    if (!pw || !pw.value) return;
    const user = usernameFieldFor(pw);
    const message = { type: "submitted", username: user ? user.value.trim() : "", password: pw.value };
    const key = message.username + "\u0000" + message.password;
    if (key === lastSent) return;
    lastSent = key;
    post(message);
  }

  function filledPasswordNear(el) {
    const scope = (el && (el.form || (el.closest && el.closest("form")))) || document;
    return passwordFields(scope).find((field) => field.value) || null;
  }

  document.addEventListener("submit", (e) => { if (e.isTrusted) capture(filledPasswordNear(e.target)); }, true);
  document.addEventListener("click", (e) => {
    if (!e.isTrusted || !e.target.closest) return;
    const control = e.target.closest('button, input[type="submit"], input[type="button"], [role="button"]');
    if (control) capture(filledPasswordNear(control));
  }, true);
  document.addEventListener("keydown", (e) => {
    if (e.isTrusted && e.key === "Enter" && e.target && e.target.type === "password") capture(e.target);
  }, true);

  // Announce a password field once; sign-in forms often appear after load.
  let announced = false, scheduled = false;
  function scan() {
    scheduled = false;
    if (announced || passwordFields().length === 0) return;
    announced = true;
    observer.disconnect();
    post({ type: "formFound" });
  }
  const observer = new MutationObserver(() => {
    if (!scheduled) { scheduled = true; setTimeout(scan, 400); }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  scan();

  // Back/Forward can restore this page from WebKit's cache without running this
  // script again, while the browser forgot the form when the restore committed.
  window.addEventListener("pageshow", (e) => {
    if (!e.persisted) return;
    lastSent = "";
    if (passwordFields().length > 0) post({ type: "formFound" });
  });
})();
