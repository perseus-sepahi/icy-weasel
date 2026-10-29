The first release of Icy Weasel, a private, ad-free browser for Mac built on Apple's WebKit.

**Install:** download `IcyWeasel.dmg`, open it, and drag Icy Weasel into Applications. Signed with a Developer ID and notarized by Apple. Requires macOS 14 Sonoma or later; hardened JavaScript needs macOS 26.4 or later.

**What it does**
- Blocks ads and trackers with nearly 250,000 compiled filter rules, including YouTube video ads
- Blocks pop-ups, tracking parameters in links and third-party cookies
- Defends against canvas and audio fingerprinting
- Loads every site over HTTPS, with a warning page when a site can't
- Runs JavaScript without the JIT compiler by default; give trusted heavy sites full speed from the shield
- Saves passwords in your Mac's keychain and fills them when you click the key in the address bar; imports passwords exported from other browsers
- Tab groups, tab sleeping, session restore, private windows
- A page assistant that finds the AI models running on your Mac (Ollama, Bonsai, LM Studio, llama.cpp and others), with optional cloud models using your own API key; it asks before a page is sent anywhere
- Reads pages aloud with a natural on-device voice (Phonon 31m on Apple silicon with macOS 15 or later, Apple's voices otherwise), in the page's own language

**Build 7 (Oct 29, 2026)**
- Read Page Aloud: the speaker button (⌥⌘R) reads the article or your selection; nothing is sent anywhere
- OpenRouter: the app checks your key, warns about management keys (they can't run models), marks free models and shows how many free requests are left today
- Cloud models are grouped by provider, free ones first; refused requests are explained in plain words

**Build 5 (Oct 22, 2026)**
- The key button now comes back when you go Back or Forward to a sign-in page

No account, no telemetry. Privacy policy: https://perseus-sepahi.github.io/icy-weasel/privacy.html

Checksums are in `SHA256SUMS.txt`.
