# Reply to App Review — Guideline 2.1 Information Needed

Paste everything below the line into the reply in App Store Connect (App Review > macOS
Submission > Messages > Reply), attach the screen recording, and paste the same text into
App Review Information > Notes.

---

Thank you for reviewing Icy Weasel. Here is the information you asked for.

1. Screen recording

The attached recording was made on a physical Mac running macOS 27. It starts by launching the app and shows the typical use: opening websites, ads and trackers being blocked, the per-site shield panel, the page assistant answering a question about the page with a model running on the Mac, saving and filling a password, a private window, and Settings. Icy Weasel has no accounts, no login, no user-generated content and no paid content or in-app purchases.

2. Purpose and target audience

Icy Weasel is a free web browser for Mac, built on Apple's WebKit, for anyone who wants to browse with less tracking and fewer ads. The problem it solves is that ordinary browsing exposes people to ads, trackers, pop-ups, browser fingerprinting and insecure connections. Icy Weasel blocks ads and trackers before they load (using WebKit's built-in content blocker), blocks pop-ups the user didn't ask for, removes tracking parameters from links, blocks third-party cookies, reduces fingerprinting, loads sites over HTTPS only, and runs web pages with a hardened JavaScript engine by default. It also saves passwords in the user's own keychain and includes an optional assistant that answers questions about the current page. The app is for the general public; it collects no data and has no account.

3. Setting up and using the main features

No account, login, credentials or sample files are needed. Launch the app and browse:
- Type an address or a search in the address bar. Every protection is on from the first launch.
- The shield button in the toolbar (Option-Command-P) shows the estimated number of blocked items and lets the user relax any protection for one site.
- Passwords: after signing in to any website, a bar offers to save the password to the Mac's keychain. On the next visit, the key button in the address bar fills it. Settings > Passwords lists saved passwords; showing one requires the Mac's password or Touch ID.
- Page assistant: the sparkle button at the top right. It uses an AI model running on the same Mac, for example the free Ollama app (ollama.com) with a model downloaded through "ollama pull qwen3:1.7b". Without a local model, the panel explains how to set one up; the rest of the browser works fully without it. Optionally, the user can add a cloud AI provider with their own API key in Settings > AI; the app asks for permission before the first page is sent to it.
- Private windows (File > New Private Window) keep nothing after they close.
- Settings (Command-comma) has Protection, Filter Lists, General, AI, Passwords and Data tabs.

4. External services the app uses
- Apple WebKit (system framework) renders web pages, including Apple's fraudulent website warning.
- Ad-blocking filter lists are downloaded from their publishers about every three days: easylist.to, ublockorigin.github.io, pgl.yoyo.org, secure.fanboy.co.nz, and filters.adtidy.org if the user turns on an optional list.
- The search engine the user chooses (DuckDuckGo by default) receives searches typed in the address bar.
- Optional AI: model servers running on the user's own Mac (Ollama, llama.cpp, LM Studio and similar), and, only if the user adds one with their own API key, a cloud AI provider such as OpenAI, Anthropic or Google Gemini.
- There are no accounts, authentication services, payment processors, analytics or developer servers.

5. Regional differences

The app works the same in every region. It has no region-specific features or content; it shows whatever websites the user visits.

6. Regulated industry or third-party material

Icy Weasel is not in a regulated industry and bundles no protected third-party material. Filter lists are downloaded at run time from their publishers under their open-source licenses (GPLv3 or CC BY-SA). The app's source code is public under the Mozilla Public License 2.0 at https://github.com/perseus-sepahi/icy-weasel, and the privacy policy is at https://perseus-sepahi.github.io/icy-weasel/privacy.html.
