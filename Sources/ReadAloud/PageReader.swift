import Foundation
import AVFoundation
import WebKit
import NaturalLanguage
import Observation

/// Read Page Aloud: speaks the selected text, or else the page's article, in
/// the page's language. Phonon speaks it when the chosen model knows that
/// language; anything else is read by Apple's voice for it. Nothing leaves
/// the Mac either way.
///
/// Phonon streams audio in 80 ms chunks, so reading starts within a moment.
/// It makes audio much faster than it plays; generation runs at most
/// `PhononSession.aheadSeconds` in front of playback, so a paused or long
/// article never piles up minutes of samples in memory.
@MainActor
@Observable
final class PageReader {

    enum State: Equatable { case idle, starting, reading, paused }

    private(set) var state: State = .idle
    /// Why the last attempt said nothing, for the toolbar's tooltip.
    private(set) var problem: String?
    /// The tab being read, so closing it stops the voice.
    private(set) var tabID: UUID?

    @ObservationIgnored private let settings: BrowserSettings
    @ObservationIgnored private var session: PhononSession?
    @ObservationIgnored private let system = AVSpeechSynthesizer()
    @ObservationIgnored private var systemDelegate: SystemVoiceDelegate?

    static let maximumCharacters = 200_000

    init(settings: BrowserSettings) {
        self.settings = settings
    }

    var isActive: Bool { state != .idle }

    /// Who reads text in `language` ("en", "fr", …).
    struct Plan: Equatable {
        enum Voice: Equatable { case phonon(PhononModel, voice: String), apple }
        let voice: Voice
        let language: String
    }

    /// The chosen Phonon model when it is on this Mac and speaks `language`;
    /// a chosen multilingual model that isn't downloaded yet gives way to the
    /// built-in English one. Everything else is read by Apple's voice.
    func plan(for language: String) -> Plan {
        var models: [PhononModel] = []
        if let chosen = settings.readAloudEngine.model {
            models = [chosen]
            if chosen != .english31m { models.append(.english31m) }
        }
        for model in models where model.isAvailable && model.languages.contains(language) {
            if let voice = PhononEngine.voice(of: model, language: language,
                                               preferred: settings.readAloudVoices[language]) {
                return Plan(voice: .phonon(model, voice: voice), language: language)
            }
        }
        return Plan(voice: .apple, language: language)
    }

    // MARK: Controls

    func read(_ tab: Tab) {
        stop()
        guard let webView = tab.webView else { return }
        state = .starting
        problem = nil
        tabID = tab.id
        Task {
            let page = await Self.readableText(from: webView)
            guard state == .starting, tabID == tab.id else { return }
            guard !page.paragraphs.isEmpty else {
                problem = "There is no text on this page to read."
                finish()
                return
            }
            speak(page.paragraphs, language: Self.language(of: page.paragraphs, declared: page.declaredLanguage))
        }
    }

    /// Speaks `paragraphs` directly: the settings' Listen buttons, and tests.
    /// Without a `language`, it is recognised from the text.
    func speak(_ paragraphs: [String], language: String? = nil) {
        if state == .idle { state = .starting }
        let plan = plan(for: language ?? Self.language(of: paragraphs, declared: nil))
        switch plan.voice {
        case .phonon(let model, let voice):
            startPhonon(paragraphs, model: model, language: plan.language, voice: voice)
        case .apple:
            startSystem(paragraphs, language: plan.language)
        }
    }

    func togglePause() {
        switch state {
        case .reading:
            session?.pause()
            if session == nil { system.pauseSpeaking(at: .word) }
            state = .paused
        case .paused:
            session?.resume()
            if session == nil { system.continueSpeaking() }
            state = .reading
        case .idle, .starting:
            break
        }
    }

    func stop() {
        session?.cancel()
        session = nil
        if system.isSpeaking { system.stopSpeaking(at: .immediate) }
        finish()
    }

    func tabClosed(_ id: UUID) {
        if tabID == id { stop() }
    }

    private func finish() {
        state = .idle
        tabID = nil
    }

    // MARK: Phonon

    private func startPhonon(_ paragraphs: [String], model: PhononModel, language: String, voice: String) {
        let session = PhononSession(rate: settings.readAloudRate)
        self.session = session
        session.onFirstAudio = { [weak self, weak session] in
            guard let self, let session, self.session === session, self.state == .starting else { return }
            self.state = .reading
        }
        session.onFinished = { [weak self, weak session] error in
            guard let self, let session, self.session === session else { return }
            self.session = nil
            if let error {
                // Phonon could not run (say, the model failed to compile):
                // read with Apple's voice rather than not at all.
                self.problem = "The Phonon voice failed (\(error)), so Apple's voice is reading."
                self.startSystem(paragraphs, language: language)
            } else {
                self.finish()
            }
        }
        session.start(paragraphs, model: model, language: language, voice: voice)
    }

    // MARK: Apple's voice

    private func startSystem(_ paragraphs: [String], language: String) {
        let delegate = SystemVoiceDelegate { [weak self] in
            guard let self, self.session == nil, self.state != .idle else { return }
            self.finish()
        }
        systemDelegate = delegate
        system.delegate = delegate
        let utterance = AVSpeechUtterance(string: paragraphs.joined(separator: "\n\n"))
        utterance.voice = Self.appleVoice(for: language)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             AVSpeechUtteranceDefaultSpeechRate * Float(settings.readAloudRate))
        system.speak(utterance)
        state = .reading
    }

    /// Apple's best installed voice for `language`: the user's own region
    /// first (so en-GB Macs get a British voice), then any, then English.
    static func appleVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let regional = Locale.current.region.map { "\(language)-\($0.identifier)" }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let best = voices.filter { $0.language == regional } + voices
        return best.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: Page text

    struct PageText { var paragraphs: [String]; var declaredLanguage: String? }

    /// The text's language as a two-letter code. Recognised from the text
    /// itself, which pages get right far more often than their `lang`
    /// attribute (many templates say "en" whatever they hold); the attribute
    /// only decides when the text is too short to tell.
    static func language(of paragraphs: [String], declared: String?) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(paragraphs.joined(separator: " ").prefix(4000)))
        if let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.6 {
            return String(language.rawValue.prefix(2))
        }
        if let declared, declared.count >= 2 { return String(declared.prefix(2)).lowercased() }
        return "en"
    }

    /// The text to read, in paragraphs: the selection when there is one,
    /// otherwise the page's article — `<article>`/`<main>` when the page marks
    /// one, else the block holding the most paragraph text — read from its
    /// headings, paragraphs and list items, skipping navigation, asides,
    /// hidden elements and code. Runs in the isolated world, so the page
    /// cannot see or change it.
    static func readableText(from webView: WKWebView) async -> PageText {
        let raw = try? await webView.callAsyncJavaScript("""
            const lang = document.documentElement.lang || '';
            const selected = String(getSelection ? getSelection() : '').trim();
            if (selected.length > 0) return JSON.stringify({lang, paragraphs: selected.split(/\\n\\s*\\n|\\n/)});
            const skip = 'nav, aside, footer, header nav, form, button, script, style, noscript, pre, code, figure, [aria-hidden=true], [hidden]';
            let root = document.querySelector('article, main, [role=main]');
            if (!root) {
                let best = null, bestLength = 0;
                for (const p of document.querySelectorAll('p')) {
                    const parent = p.parentElement;
                    if (!parent || parent.closest(skip)) continue;
                    let length = 0;
                    for (const child of parent.children) if (child.tagName === 'P') length += child.innerText.length;
                    if (length > bestLength) { best = parent; bestLength = length; }
                }
                root = best || document.body;
            }
            const blocks = root.querySelectorAll('h1, h2, h3, h4, h5, h6, p, li, blockquote, dd, dt, td, figcaption');
            const out = [];
            for (const el of blocks) {
                if (el.closest(skip) && !el.closest('figure figcaption')) continue;
                if (el.querySelector('p, li, blockquote')) continue;   // read the inner blocks instead
                const style = getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') continue;
                const text = el.innerText.replace(/\\s+/g, ' ').trim();
                if (text.length > 1) out.push(text);
            }
            if (out.length === 0 && root.innerText) out.push(...root.innerText.split(/\\n+/));
            return JSON.stringify({lang, paragraphs: out});
            """, arguments: [:], in: nil, contentWorld: ScriptInjector.isolatedWorld) as? String
        guard let raw, let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let list = object["paragraphs"] as? [String] else { return PageText(paragraphs: [], declaredLanguage: nil) }
        let lang = object["lang"] as? String
        return PageText(paragraphs: cleaned(list), declaredLanguage: lang?.isEmpty == false ? lang : nil)
    }

    /// Trims and drops empty entries, and stops once `maximumCharacters` are
    /// collected so a giant page can't stall the reader.
    static func cleaned(_ paragraphs: [String]) -> [String] {
        var result: [String] = []
        var total = 0
        for paragraph in paragraphs {
            let text = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard text.contains(where: \.isLetter) || text.contains(where: \.isNumber) else { continue }
            total += text.count
            if total > maximumCharacters { break }
            result.append(text)
        }
        return result
    }
}

private final class SystemVoiceDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: @MainActor () -> Void
    init(onFinish: @escaping @MainActor () -> Void) { self.onFinish = onFinish }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in onFinish() }
    }
}

/// One reading with Phonon: generation on the engine's queue, playback on an
/// audio engine, and the bookkeeping between them. Callbacks arrive on the
/// main thread.
final class PhononSession: @unchecked Sendable {
    static let aheadSeconds: Double = 20

    var onFirstAudio: (@MainActor () -> Void)?
    var onFinished: (@MainActor (Error?) -> Void)?

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PhononEngine.sampleRate, channels: 1)!

    /// Guards the fields below: generation, playback completions and the
    /// main thread all touch them.
    private let lock = NSCondition()
    private var queuedFrames = 0
    private var cancelled = false
    private var startedPlaying = false

    init(rate: Double) {
        audio.attach(player)
        audio.attach(timePitch)
        audio.connect(player, to: timePitch, format: format)
        audio.connect(timePitch, to: audio.mainMixerNode, format: format)
        // Phonon speaks at its own pace; other speeds stretch the audio. The
        // unit is bypassed at 1× because even "no change" softens transients.
        timePitch.rate = Float(min(max(rate, 0.5), 3))
        timePitch.bypass = abs(rate - 1) < 0.01
    }

    func start(_ paragraphs: [String], model: PhononModel, language: String, voice: String) {
        do {
            try audio.start()
        } catch {
            finish(error)
            return
        }
        player.play()
        speak(paragraphs, from: 0, model: model, language: language, voice: voice)
    }

    private func speak(_ paragraphs: [String], from index: Int, model: PhononModel, language: String, voice: String) {
        guard index < paragraphs.count, !isCancelled else {
            // Everything is queued: finish once the last of it has played.
            enqueue([], last: true)
            return
        }
        PhononEngine.shared.speak(paragraphs[index], model: model, language: language, voice: voice, onAudio: { [self] samples in
            enqueue(samples, last: false)
            return waitForRoom()
        }, completion: { [self] error in
            if let error, !isCancelled {
                finish(error)
                return
            }
            // A beat between paragraphs, as a person reading aloud would leave.
            enqueue([Float](repeating: 0, count: Int(PhononEngine.sampleRate * 0.35)), last: false)
            speak(paragraphs, from: index + 1, model: model, language: language, voice: voice)
        })
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Blocks generation while `aheadSeconds` of audio wait to be played.
    /// Returns false once the reading is cancelled, which stops Phonon.
    private func waitForRoom() -> Bool {
        let limit = Int(Self.aheadSeconds * PhononEngine.sampleRate)
        lock.lock(); defer { lock.unlock() }
        while queuedFrames > limit && !cancelled { lock.wait() }
        return !cancelled
    }

    private func enqueue(_ samples: [Float], last: Bool) {
        guard !isCancelled else { return }
        let count = max(samples.count, last ? 1 : 0)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        if samples.isEmpty {
            channel[0] = 0
        } else {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: count) }
        }
        lock.lock()
        queuedFrames += count
        let first = !startedPlaying
        startedPlaying = true
        lock.unlock()
        if first, let onFirstAudio { Task { @MainActor in onFirstAudio() } }

        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [self] _ in
            lock.lock()
            queuedFrames -= count
            lock.broadcast()
            let done = cancelled
            lock.unlock()
            if last && !done { finish(nil) }
        }
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.broadcast()
        lock.unlock()
        player.stop()
        audio.stop()
    }

    private func finish(_ error: Error?) {
        let callback = onFinished
        Task { @MainActor in
            self.player.stop()
            self.audio.stop()
            callback?(error)
        }
    }
}
