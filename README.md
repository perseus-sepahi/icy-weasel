# Icy Weasel

A macOS browser built for security first, blocking second, and speed close behind.
Native Swift/SwiftUI on WebKit, with a filter compiler, fingerprinting defence and
security policy layer that were each verified against the real engine rather than
written from documentation.

> **Engine: WebKit, not Chromium.** A Chromium fork needs ~70–100 GB of build space
> (this machine had 96 GB free) and hours per build; embedding Chromium via CEF means
> shipping and patching a ~250 MB engine yourself. WebKit is patched by Apple with the
> OS, compiles content-blocking rules to native bytecode, and exposes engine-level
> security switches (no-JIT, Lockdown) that no extension can reach. The trade-off:
> some sites sniff for Chrome, and there is no browser-extension support.

---

## What is verified

Numbers below come from the test suite, not estimates. Network-dependent tests run with
`TEST_RUNNER_IW_NETWORK_TESTS=1` (see [Testing](#testing)).

### Blocking — live A/B experiment (`RealWorldBlockingTests`)

The same page loads 20 real tracker endpoints and 7 legitimate resources, once with
Icy Weasel's lists (A) and once with none (B). B proves each endpoint is reachable, so
a failure under A is attributable to blocking.

| | Result |
|---|---|
| Reachable trackers blocked | **19 / 19** (Google Analytics & Tag Manager, DoubleClick, AdSense, Meta Pixel, Hotjar, Criteo, Taboola, Outbrain, comScore, Pinterest, TikTok, LinkedIn, Clarity, Amazon Ads, Mixpanel, HubSpot, Bing UET, Quantcast) |
| Legitimate resources broken | **0 / 7** (jQuery, lodash, React, htmx, Wikimedia, GitHub, MDN) |
| Requests completed | 27 → 7 |

### Real pages (`RealWorldBlockingTests`, 6 alternating runs per arm, medians)

| Page | Requests | Third-party hosts | DOMContentLoaded | load event |
|---|---|---|---|---|
| speedtest.net | 95 → **25** | 52 → **6** | 608 → 616 ms | 616 → 629 ms |
| cnn.com | 87 → 77 | 15 → 11 | 612 → **466 ms** | 1098 → 1092 ms |
| theguardian.com | 86 → 76 | 4 → 3 | 255 → 369 ms | 414 → 561 ms |

Blocking removes most requests and third-party connections on ad-heavy sites. Its
effect on load *time* is mixed, and reported as measured: faster on CNN, neutral on
Speedtest, and about 0.1 s slower on The Guardian — a lean page with little to block,
where WebKit's per-request rule matching is the dominant cost. See [Speed](#speed).

### How the rules are laid out

WebKit's `ignore-previous-rules` cancels only rules *above* it in the same list, and
lists cannot see each other. The compiler turns that into structure:

- **Two families of lists.** Cosmetic lists: generic hiding → `$generichide`
  exceptions → site-specific hiding → `$elemhide` exceptions → `$document` exceptions.
  Network lists: blocks → request exceptions → `$document` exceptions. A
  `$generichide` exception therefore can never unblock a network request — the bug
  that briefly let `@@||bing.com^$generichide` unblock `bat.bing.com` everywhere.
- **Site-specific hiding is document-scoped**: the site is in the url-filter with
  `resource-type: document`, not `.*` + `if-domain`. A `.*` trigger makes a rule a
  candidate on every resource load; 12k of them cost The Guardian ~120 ms of parsing.
- **Rules are never merged into selector lists.** WebKit's compile-time selector
  validation has gaps (an unterminated `[` compiles), and a merged rule with one such
  selector silently hides nothing.
- **Redundant rules are pruned**: a block covered by an unconditional `||parent^`
  rule is removed; this cannot change any outcome.
- **Bisect on compile failure** drops a bad rule, or splits a list that is merely too
  large — it never discards a chunk.

### Filter compiler (`RealFilterListTests`, `CompilerTests`, `WebKitIntegrationTests`)

| | Result |
|---|---|
| Source lines (7 default lists) | 264,852 |
| Rules active | 230,291 in 3 compiled lists (2 network, 1 cosmetic) |
| Rules WebKit rejected | **0** |
| Unsupported syntax, skipped and counted | 5,879 (mostly 2,786 uBO `+js()` scriptlets) |
| Duplicates removed across lists | 22,662 |
| Redundant rules pruned (covered by a `‖host^` rule) | 7,831 |
| First compile (per list or app update) | ~19 s, in the background, with a bundled seed list active meanwhile |
| **Relaunch with compiled lists cached** | **~5 ms** |
| Compiled lists on disk | ~115 MB (in the app's container) |

### Cost of the defaults (`FingerprintDefenseTests.testInsertionAndInterpreterCost`)

| Workload | Stock WebKit | Icy Weasel default | |
|---|---|---|---|
| 10k-cell table build + layout | 39 ms | 48 ms | 1.23× |
| Fingerprinting shim alone on that render | 39 ms | 42 ms | 1.08× |
| Cosmetic filter stylesheet, style + layout (`StyleCostExperiment`) | 7 ms | 8 ms | ~1 ms |
| 30M integer operations (pure compute) | 7 ms | 647 ms | **~90×** |
| Same, switched per navigation as tabs do (`ProductionPathTests`) | 7 ms | 487 ms | 70× |

That last row is the one real speed cost, and it is deliberate — see
[JavaScript engine](#javascript-engine-the-one-real-trade-off).

---

## Security

### Engine level (cannot be detected or undone by a page)
- **JIT disabled by default** (`securityRestrictionMode = .maximizeCompatibility`,
  macOS 26.4+). JIT compilers turn attacker-supplied script into machine code at run
  time and are the most exploited part of any browser. Also widens memory tagging (MTE)
  on supporting hardware. Per-site override; Lockdown mode available.
- **HTTPS-only** via WebKit's native `.errorOnFailure` policy, plus a `make-https`
  rule for subresources and HSTS-preload upgrades. Failures are classified against
  error codes observed on real hosts (`HTTPSPolicyProbe`): a site without HTTPS gets an
  interstitial with a per-site escape hatch; an offline network or unknown host is
  never blamed on HTTPS. There is deliberately no bypass for invalid certificates.
- **Global Privacy Control** (`Sec-GPC: 1`, macOS 27).
- **Fraudulent-site warnings** (Safe Browsing), popups only from user gestures,
  camera/microphone always prompt.
- **Private windows** each get their own non-persistent data store: tabs in one
  private window share a session; nothing is shared with any other window or written
  to disk.

### Network
- Third-party cookies blocked by rule, in addition to WebKit's ITP.
- Tracking parameters stripped before the request is made (`fbclid`, `gclid`,
  `utm_*`, `mc_eid`, 90+ others; host-scoped ones like YouTube's `si` only on their
  host). Idempotent, so the cancel-and-reload cannot loop.

### Fingerprinting
Scope was set by measuring stock WebKit first (`FingerprintSurfaceProbe`). WebKit
already caps `hardwareConcurrency` at 8, returns the spec-standard plugin list, masks
the GPU as "Apple GPU" and hides local IPs behind mDNS — patching those would make
Icy Weasel users *more* identifiable. What it leaves exposed is readback, so the shim
covers exactly that:

- Canvas (`getImageData`, `toDataURL`, `toBlob`, WebGL `readPixels`) and audio
  (`getChannelData`, `copyFromChannel`, `AnalyserNode`) readback noise.
- Noise is a pure function of (per-launch secret, **top-level site**, pixel/sample
  position): stable within a site so averaging recovers nothing, different across
  sites so trackers cannot link visits, different every launch.
- Idempotent, never touches blank canvases or silent audio, never alters what the
  page drew.
- Same-origin child frames are patched before a page can reach them — including
  `srcdoc`/`blob:` frames, `window[i]` access, `innerHTML`, `replaceChild`, nested and
  parser-inserted frames.
- Resists inspection and tampering: native `toString`/`name`/`length`/descriptors and
  error messages preserved; null-prototype Proxy handlers (inherited traps would leak
  the native function); builtins captured before page scripts run, so a page replacing
  `WeakMap.prototype.get` receives nothing.

### Downloads
Saved to ~/Downloads with the quarantine attribute (Gatekeeper checks before first
open), server-supplied names reduced to a last path component (no `../` escapes),
never overwrite, never auto-open.

### AI assistant
The sparkle button at the top right opens a panel that answers questions about the
current page. Models come from two places (`Sources/Assistant/AIProviders.swift`):

- **On this Mac, found automatically.** The panel asks the ports local AI tools use:
  Ollama (11434), llama.cpp (8080, what Bonsai's `start_llama_server.sh` runs), MLX
  (8081, Bonsai's `start_mlx_server.sh`), LM Studio (1234), Jan (1337), GPT4All (4891)
  and 8000, plus any loopback address added in Settings > AI. Whatever answers is listed
  with its models, so new tools and models appear without an app update. An installed
  but stopped Ollama gets a Start button.
- **Cloud, optional, with your own API key.** OpenAI, Anthropic, Google Gemini,
  OpenRouter, Groq, Mistral, DeepSeek or any OpenAI-compatible HTTPS endpoint. Keys live
  in the keychain and are only ever sent to their own provider over HTTPS. Page text goes
  to a cloud provider only after the user agrees once per provider, the panel always
  says where pages go, and private windows offer local models only.

Page content is handed to the model as untrusted data, and the model has no tools, so a
hostile page can at worst make an answer wrong (`PracticalBrowserTests` plants an
injection in the page and checks the model still answers from the facts).
`AIProviderTests` cover discovery, streaming, consent and key handling; its
Bonsai-style end-to-end test runs against `scripts/fake-ai-server.py`, because the app
sandbox can't host a server itself.

### Pop-ups
WebKit refuses `window.open` without a user gesture; Icy Weasel also blocks the
pop-under pattern — script-opened, cross-site windows fired from any click. Real
`target="_blank"` links and same-site windows open as tabs. Blocked pop-ups are listed
in the address bar (open one, or always allow for the site). Limitation: allowed
pop-ups open as ordinary tabs without `window.opener`, so some "Sign in with…" pop-up
flows need the redirect variant.

### External apps and URL schemes
Handing arbitrary schemes to the system is a real attack surface (`smb://` makes Finder
mount an attacker's share; app URL handlers have a long history of remote-code bugs).
Schemes that reach file systems or shells (`file`, `smb`, `afp`, `nfs`, `ftp`, `ssh`,
`vnc`, …) are never opened from web content. Anything else needs a click in the top
frame — no subframes, no script-driven redirects — and an explicit confirmation whose
default button is Cancel.

### App
App Sandbox (network client, user-selected files, Downloads only), hardened runtime.
The app's own scripts and message handler live in an isolated content world, invisible
to pages.

---

## Look

Frosted glass over glacier blues. The window itself is see-through (blurred, tinted
cold), the selected tab, address bar, cards and assistant are panes of real Liquid
Glass on macOS 26+ with a frosted-material fallback on older systems, and pages like
the new tab sit on a static aurora-and-glacier backdrop (no animation, no per-frame
cost). Settings → General → Appearance offers Match System, Frost (light) and
Glacier (dark); private windows use a violet frost. Palette and glass helpers live in
`Sources/Support/Theme.swift`.

## JavaScript engine: the one real trade-off

| Setting | What it does | Cost |
|---|---|---|
| Full speed | JIT enabled | none |
| **Hardened** (default) | Interpreter only, extended memory tagging, dedicated processes | Content pages ~1.2× on render; pure computation ~90× |
| Lockdown | Apple's Lockdown restrictions | Some sites break |

Content sites barely notice Hardened mode because DOM work runs in native code.
Compute-heavy web apps (Figma, spreadsheets, maps, games) will feel slow — give those
**Full speed** from the shield (⌥⌘P) rather than lowering the global setting, which is
the same per-site approach Microsoft reached for Edge's JIT-less mode.

---

## Speed

### What blocking costs, and what was done about it

The first version made The Guardian's DOMContentLoaded **+470 ms slower** with blocking on.
Ablations on wall-clock time (`SpeedInvestigation`) traced it, step by step:

| Change | Guardian DOMContentLoaded overhead |
|---|---|
| Original compiler (9 lists, `.*` + `if-domain` site cosmetics) | +470 ms |
| Site-specific cosmetics scoped to the site's own document URL | +187 ms |
| Network rules in 2 lists instead of 8 (less exception duplication) | **+119 ms** |

Two findings drove this, both contrary to the obvious guess: 184k host-blocking rules
cost nothing measurable, while 12k site-specific cosmetic rules cost ~120 ms because a
`.*` trigger makes every rule a candidate on every resource load; and the number of
lists matters because each carries its own copy of the exceptions. The remaining cost
is WebKit's per-request rule matching, paid on every resource a page loads.

- Rule lists compile once to WebKit DFA bytecode and load from disk in milliseconds;
  the cache key includes the compiler version so fixes always reach users.
- Filter parsing runs off the main thread; a bundled seed list protects the first
  launch while the full lists compile in the background.
- Idle tabs hibernate (default 10 min): the web view and its content process are
  released and `interactionState` restores history and scroll on return. Background
  tabs are CPU-throttled natively until then.
- Tab switching reparents web views instead of reloading them.

---

## Known limitations

- **YouTube ads are removed, but YouTube makes you wait anyway.** `youtube-adblock.js`
  strips the ad schedule from the player data (the uBlock Origin technique), with an
  instant-skip fallback. Live A/B on three videos (`YouTubeAdTests`): no ad is shown or
  even fetched, but YouTube holds playback back server-side, so the video starts after
  ~4–13 s of blank player instead of 16 s+ of ads. YouTube changes this machinery
  often; that file is the one to update when ads reappear. Other uBO `+js()` scriptlets
  (2,786 rules) are still skipped.
- **Blocking is not free on lean pages.** Sites with little to block (The Guardian)
  load ~0.1 s slower; sites with a lot to block see large request reductions and
  neutral-to-faster timing. Disable blocking per site from the shield if it matters.
- **Web Workers:** OffscreenCanvas readback inside a worker bypasses the fingerprinting
  shim (workers never receive user scripts; an engine-level fix would be required).
- The shim runs in the page world; a determined adversary can detect it via side
  channels (error stack shapes, timing). The target is passive commercial
  fingerprinting.
- `$specifichide` exceptions are approximated as `$elemhide` (WebKit cannot cancel
  site-specific cosmetics without generic ones); uBO entity domains (`site.*`) are
  dropped rather than guessed.
- The toolbar's blocked count is an **estimate**: WebKit does not report content-rule
  blocks to the app, so it counts third-party load failures and hidden elements.
- Per-site settings group sites with Mozilla's full Public Suffix List (bundled, so it
  updates with app releases rather than live).
- DNS uses the system resolver (configure DNS-over-HTTPS system-wide for encrypted DNS).
- **Not Chromium, and no Chrome extensions.** The engine is WebKit. Chrome Web Store
  extensions cannot be installed. macOS 15.4+ does ship a `WKWebExtension` API that can
  load Safari-style WebExtensions (the same manifest format most Chrome extensions use);
  wiring that in is the realistic route to extension support and is not done yet.
- Not yet included: password manager/autofill, sync, reader mode, picture-in-picture
  button, drag-to-reorder tabs, proxy/Tor routing.
  Included: tabs with hibernation, **tab groups** (named, coloured, collapsible; right-click
  a tab, or ⌥⌘G), session restore, reopen closed tab (⇧⌘T), history (⌘Y) and bookmarks
  (⌘D) with local-only address-bar suggestions, 11 search engines plus a custom one,
  private windows, downloads, uploads, JavaScript dialogs, HTTP sign-in prompts, print
  (⌘P), ⌘-click to open in a background tab, links from other apps, fullscreen video,
  find in page (⌘F), zoom, per-site shield panel (⌥⌘P), and the AI assistant (⌥⌘A).

---

## Installing

Download the latest disk image from
[Releases](https://github.com/perseus-sepahi/icy-weasel/releases/latest), open it and
drag Icy Weasel into Applications. Builds are signed with a Developer ID and notarized
by Apple. Data lives in `~/Library/Containers/com.icyweasel.browser/`.

To build and install from source instead:

```bash
xcodegen generate
xcodebuild -project IcyWeasel.xcodeproj -scheme IcyWeasel -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY="-" build
ditto "build/Build/Products/Release/Icy Weasel.app" "/Applications/Icy Weasel.app"
```

## Releasing

```bash
scripts/release.sh direct     # Developer ID: signed, notarized .dmg and .zip in build/release
scripts/release.sh appstore   # Mac App Store .pkg (upload with Transporter or an API key)
```

One-time setup and details are at the top of `scripts/release.sh`. The App Store
listing text is in `distribution/AppStore.md`; the website is in `site/`.

## Building

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project IcyWeasel.xcodeproj -scheme IcyWeasel -configuration Release build
```

Runs on macOS 14+. Hardened JavaScript needs macOS 26.4+, native HTTPS-only 15.2+,
Global Privacy Control 27; on older systems those fall back or are skipped.

## Testing

```bash
# Offline suite: parser, compiler, WebKit integration, fingerprinting, policy
xcodebuild -project IcyWeasel.xcodeproj -scheme IcyWeasel test

# Adds live experiments: real filter lists, real trackers, real sites
TEST_RUNNER_IW_NETWORK_TESTS=1 xcodebuild -project IcyWeasel.xcodeproj -scheme IcyWeasel test

# Performance benchmarks: JavaScript speed per hardening level, user-script
# cost per frame, new-tab latency, history and suggestion costs
TEST_RUNNER_IW_PERF=1 xcodebuild -project IcyWeasel.xcodeproj -scheme IcyWeasel test \
  -only-testing:IcyWeaselTests/PerformanceBenchmarks
```

Probe tests (`RegexDialectProbe`, `TriggerDialectProbe`, `CosmeticMergeProbe`,
`DocumentScopedCosmeticProbe`, `FingerprintSurfaceProbe`, `HTTPSPolicyProbe`) record what
the installed WebKit actually accepts, exposes and does. Several compiler decisions rest
on those observations rather than documentation; when a macOS update changes engine
behaviour, the probes are where it shows up first. `SpeedInvestigation` holds the
page-load ablations behind the speed numbers above.

## Layout

```
Sources/
  App/        entry point, menus, settings
  Browser/    window, tabs, toolbar, shield panel, downloads, find, web view factory
  Blocking/   ABP parser → layered WebKit rule compiler → cached rule-list store
  Security/   site policy, URL sanitiser, script injection
  Support/    settings, theme
Resources/
  JS/         fingerprint-defense.js (page world), block-counter.js (isolated world)
  Seed/       first-launch filter list
Tests/        unit, WebKit integration, probes, live experiments
```

---

## License

Icy Weasel is licensed under the [Mozilla Public License 2.0](LICENSE).
© 2026 Mohammadreza Sepahi.

Filter lists are not bundled; the app downloads them at run time from their publishers,
and each stays under its own license (EasyList and EasyPrivacy: GPLv3 or CC BY-SA 3.0;
uBlock Origin filters: GPLv3; Peter Lowe's list and Fanboy's lists: their publishers'
terms). The bundled Public Suffix List (`Resources/PublicSuffix`) is © Mozilla under
MPL-2.0. Website and privacy policy: [perseus-sepahi.github.io/icy-weasel](https://perseus-sepahi.github.io/icy-weasel/).
