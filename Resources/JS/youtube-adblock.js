/*
 * Icy Weasel — YouTube ad removal.
 *
 * YouTube serves ads from the same hosts as videos, so no network or cosmetic
 * rule can remove them. What can: the player only schedules ads it is told
 * about. The ad schedule arrives as fields of the player response
 * (`adPlacements`, `adSlots`, `playerAds`), either inlined in the page as
 * `ytInitialPlayerResponse` or fetched from /youtubei/v1/player. Deleting those
 * fields before the player reads them means there is nothing to play. This is
 * the same technique uBlock Origin's YouTube scriptlets use.
 *
 * Layer 2 is a safety net for anything that still gets scheduled: when the
 * player enters its `ad-showing` state, jump to the end of the ad and press
 * Skip. YouTube changes this machinery regularly; expect to update this file.
 *
 * Installed in every frame, but does nothing off YouTube.
 */
(function () {
  "use strict";
  const host = location.hostname;
  if (!/(^|\.)youtube(-nocookie)?\.com$/.test(host)) return;

  // Swift substitutes true/false. See the header of the strategy section below.
  const PRUNE_SCHEDULE = __IW_YT_PRUNE__;
  const AD_KEYS = PRUNE_SCHEDULE ? ["adPlacements", "adSlots", "playerAds", "adBreakHeartbeatParams"] : [];

  function prune(value) {
    if (!value || typeof value !== "object") return value;
    const targets = [value, value.playerResponse, value.response && value.response.playerResponse];
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) {
        const item = value[i];
        if (item && typeof item === "object") targets.push(item, item.playerResponse, item.player && item.player.args);
      }
    }
    for (let t = 0; t < targets.length; t++) {
      const target = targets[t];
      if (!target || typeof target !== "object") continue;
      for (let k = 0; k < AD_KEYS.length; k++) {
        if (AD_KEYS[k] in target) { try { delete target[AD_KEYS[k]]; } catch (e) {} }
      }
    }
    return value;
  }

  // 1. Everything the page parses.
  const nativeParse = JSON.parse;
  JSON.parse = new Proxy(nativeParse, {
    __proto__: null,
    apply(target, self, args) { return prune(Reflect.apply(target, self, args)); }
  });

  // 2. Everything the page fetches as JSON.
  if (window.Response) {
    const nativeJson = Response.prototype.json;
    Response.prototype.json = new Proxy(nativeJson, {
      __proto__: null,
      apply(target, self, args) { return Reflect.apply(target, self, args).then(prune); }
    });
  }

  // 3. The response inlined into the watch page, assigned by an inline script.
  for (const name of ["ytInitialPlayerResponse", "playerResponse"]) {
    let stored;
    try {
      Object.defineProperty(window, name, {
        configurable: true, enumerable: true,
        get() { return stored; },
        set(v) { stored = prune(v); }
      });
    } catch (e) {}
  }

  // 4. Safety net: get out of any ad that starts anyway.
  function escapeAd() {
    const player = document.querySelector(".html5-video-player");
    if (!player || !player.classList.contains("ad-showing")) return;
    const video = player.querySelector("video");
    if (video) {
      video.muted = true;
      try { video.playbackRate = 16; } catch (e) {}
      if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
        video.currentTime = video.duration;
      }
    }
    const skip = document.querySelector(
      ".ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-overlay-close-button");
    if (skip) skip.click();
  }
  function watch() {
    new MutationObserver(escapeAd).observe(document.documentElement,
      { subtree: true, attributes: true, attributeFilter: ["class"], childList: true });
    setInterval(escapeAd, 500);
  }
  if (document.documentElement) watch(); else document.addEventListener("DOMContentLoaded", watch, { once: true });

  // 5. Ad furniture around the player and in feeds.
  const style = document.createElement("style");
  style.textContent = [
    "ytd-ad-slot-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-promoted-sparkles-web-renderer",
    "ytd-display-ad-renderer", "ytd-banner-promo-renderer", "ytd-statement-banner-renderer",
    "ytd-player-legacy-desktop-watch-ads-renderer", "#player-ads", "#masthead-ad",
    "ytd-rich-item-renderer:has(ytd-ad-slot-renderer)", ".ytp-ad-overlay-container", ".ytp-ad-module"
  ].join(",") + "{display:none!important}" +
  // Never show a frame of an ad while it is being skipped.
  ".html5-video-player.ad-showing video{opacity:0!important}";
  (document.head || document.documentElement).appendChild(style);
})();
