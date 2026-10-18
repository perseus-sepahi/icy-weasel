/*
 * Icy Weasel — block estimator.
 *
 * WebKit does not report content-rule-list blocks back to the host app; the
 * rules are evaluated inside the network process and the page simply never sees
 * the resource. There is no API to ask "how many did you block?".
 *
 * What we CAN observe is the page-side consequence: a blocked subresource fires
 * an `error` event on its element. That over-counts genuine 404s and
 * under-counts resources blocked before an element existed (fetch/XHR, beacons),
 * so the number is reported to the UI as an estimate and labelled as one.
 *
 * Runs in the isolated "IcyWeasel" content world: the DOM is shared, so error
 * events and computed styles are visible here, but nothing this script defines
 * — including the message handler — is visible to the page.
 */
(function () {
  "use strict";

  var counted = 0;
  var seen = new Set();

  function registrable(host) {
    var parts = String(host || "").split(".");
    return parts.length >= 2 ? parts.slice(-2).join(".") : host;
  }

  var pageDomain = registrable(location.hostname);

  function report() {
    try {
      window.webkit.messageHandlers.icyWeaselBlocked.postMessage({ count: counted });
    } catch (e) {}
  }

  window.addEventListener("error", function (event) {
    var el = event.target;
    if (!el || !el.tagName) return;
    var tag = el.tagName.toLowerCase();
    if (["img", "script", "iframe", "link", "video", "audio", "source"].indexOf(tag) === -1) return;

    var src = el.src || el.href || "";
    if (!src || seen.has(src)) return;
    seen.add(src);

    // Only third-party failures are plausibly blocks rather than broken pages.
    try {
      if (registrable(new URL(src, location.href).hostname) === pageDomain) return;
    } catch (e) { return; }

    counted++;
    report();
  }, true);

  // Elements hidden by a css-display-none rule are definite blocks. Sampling
  // once after load is cheap and catches the cosmetic half of the picture.
  window.addEventListener("load", function () {
    setTimeout(function () {
      try {
        var hidden = 0;
        var candidates = document.querySelectorAll(
          '[class*="ad"],[id*="ad"],ins,iframe,[class*="sponsor"],[class*="promo"]'
        );
        for (var i = 0; i < candidates.length && i < 500; i++) {
          if (getComputedStyle(candidates[i]).display === "none") hidden++;
        }
        if (hidden > 0) { counted += hidden; report(); }
      } catch (e) {}
    }, 400);
  });
})();
