# Mac App Store listing — Icy Weasel 1.0

Paste these into App Store Connect. Character limits are Apple's.

## App information

| Field | Value |
|---|---|
| Name (30) | Icy Weasel |
| Subtitle (30) | Private browser, no ads |
| Bundle ID | com.icyweasel.browser |
| SKU | ICYWEASEL-MAC-1 |
| Primary category | Productivity |
| Secondary category | Utilities |
| Price | Free |
| Copyright | © 2026 Mohammadreza Sepahi |
| Privacy policy URL | https://perseus-sepahi.github.io/icy-weasel/privacy.html (change if the site lives elsewhere) |
| Support URL | https://perseus-sepahi.github.io/icy-weasel/support.html |
| Marketing URL | https://perseus-sepahi.github.io/icy-weasel/ |

## Promotional text (170)

Blocks ads, trackers, pop-ups and YouTube video ads before they load. Built on Apple's WebKit, with no account and no telemetry.

## Description (4,000)

Icy Weasel is a web browser for Mac that stops ads and trackers before they load, hides you from fingerprinting, and refuses insecure connections by default.

WHAT IT BLOCKS
• Ads and trackers, using nearly 250,000 rules from EasyList, EasyPrivacy, uBlock Origin's lists and more, compiled into WebKit's native content blocker
• YouTube video ads: the ad schedule is removed before the player reads it
• Pop-ups that a page opens without your click
• Tracking parameters such as utm_source and fbclid in links
• Third-party cookies
• Canvas and audio fingerprinting, with a different result for every site
• Plain HTTP: every site loads over HTTPS, with a clear warning if it can't

SAFER JAVASCRIPT
By default Icy Weasel runs pages without the JavaScript JIT compiler, the part of a browser most often used in real attacks. Reading sites feel the same. For a heavy web app you trust, switch that one site to Full speed from the shield.

EVERYTHING ELSE
• Tab groups, tab sleeping and session restore
• Private windows that keep nothing
• A page assistant that runs open-source AI models on your own Mac through Ollama
• DuckDuckGo, Startpage, Brave, Kagi, Ecosia and six more search engines, or your own
• Per-site controls for every protection
• History and bookmarks with suggestions that never leave your Mac

PRIVATE BY DESIGN
No account, no analytics, no crash reporting, no advertising. History, bookmarks and settings stay on your Mac.

Icy Weasel uses WebKit, the engine behind Safari, so Chrome extensions are not supported.

## Keywords (100)

ad blocker,privacy,browser,tracker,adblock,secure,web,private,popup,fingerprint,https,anti tracking

## What's new (version 1.0)

First release.

## Age rating

Answer "Unrestricted web access": Yes. Everything else: None. This gives the browser rating Apple requires for unrestricted web access.

## App privacy ("nutrition label")

Data Not Collected. The developer collects no data from this app.

## Export compliance

Already answered in the build (ITSAppUsesNonExemptEncryption = NO): the app only uses Apple's HTTPS and CryptoKit hashing.

## Notes for App Review

Icy Weasel is a WebKit browser. No sign-in is needed. To see blocking, open any news site; the shield in the toolbar shows the estimated number of blocked items, and its panel turns each protection off for one site.

The page assistant (sparkle button) is optional and only works with Ollama installed on the same Mac; without it, the panel explains how to set it up. It connects to localhost only, which is why NSAllowsLocalNetworking is set. NSAllowsArbitraryLoadsInWebContent is set because users can visit any website; the app's own requests use HTTPS.

The app sandbox entitlements are network client (browsing), downloads folder (saving downloads), user-selected files (uploads) and printing.

## Screenshots

Mac: 2880×1800. Uploaded for 1.0 (in `distribution/screenshots/`):
1. New Tab page with blocked count and protections
2. Protection settings
3. Filter lists
4. Search engine and local AI settings

Compose new ones with `swift scripts/compose-screenshot.swift <capture.png> <out.png> "caption"`.
Web pages only render while the browser window is on a visible desktop, so capture
page screenshots (shield panel, tab groups) from a regular desktop, not a full-screen Space.
