import Foundation
#if arch(arm64) && canImport(PhononCore)
import CoreML
import PhononCore
#endif

/// The two Phonon models Read Page Aloud can use.
///
/// - **Phonon 31m** (English, Apache 2.0) ships inside the app:
///   `scripts/fetch-phonon.sh` puts it in ThirdParty/Phonon.
/// - **Phonon 40m multilingual** (English, French, German, Spanish and
///   Portuguese) is CC BY-NC 4.0, so it is never part of the app: users
///   download it from Settings (`PhononModelDownload`), with its licence.
enum PhononModel: String, CaseIterable, Identifiable {
    case english31m = "phonon-31m-en"
    case multilingual40m = "phonon-40m-multilingual"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english31m: "Phonon 31M (English)"
        case .multilingual40m: "Phonon 40M multilingual"
        }
    }

    var languages: [String] {
        switch self {
        case .english31m: ["en"]
        case .multilingual40m: ["en", "fr", "de", "es", "pt"]
        }
    }

    /// Where Phonon reads the model from, once it is on this Mac. The bundled
    /// model is copied out of the app first (`PhononEngine.installedModel`),
    /// because Core ML compiles each model beside itself.
    var location: URL? {
        switch self {
        case .english31m:
            return Bundle.main.url(forResource: "PhononModel", withExtension: nil)
        case .multilingual40m:
            let folder = PhononEngine.supportDirectory?.appendingPathComponent(rawValue, isDirectory: true)
            return folder.flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent("bundle.json").path) ? $0 : nil }
        }
    }

    var isAvailable: Bool { PhononEngine.canRun && location != nil }
}

/// One voice of a model, described by Gradium's voice catalog
/// (`voices.jsonl`, shipped beside each model's voices).
struct PhononVoice: Hashable, Identifiable {
    let name: String
    /// "en", "fr", "de", "es" or "pt".
    let language: String
    /// "en-us", "en-gb", "pt-br" and so on; "characters" for the character voices.
    let locale: String
    let gender: String
    var id: String { name }

    /// "Maeve · British", "Grub the Ogre · character".
    var label: String {
        switch locale {
        case "en-us": "\(name) · American"
        case "en-gb": "\(name) · British"
        case "es-mx": "\(name) · Mexican"
        case "pt-br": "\(name) · Brazilian"
        case "characters": "\(name) · character"
        default: name
        }
    }
}

/// Phonon, Gradium's on-device voice, driven through its C library. Without
/// the library, on an Intel Mac (it is arm64 only) or on macOS 14 (the models
/// are Core ML 8 programs), `canRun` is false and Read Page Aloud uses Apple's
/// voices.
///
/// One model is loaded at a time, shared by every window. Every call into it
/// runs on one serial queue: the library is not reentrant.
final class PhononEngine: @unchecked Sendable {
    static let shared = PhononEngine()
    static let sampleRate: Double = 24_000

    static var canRun: Bool {
        #if arch(arm64) && canImport(PhononCore)
        if #available(macOS 15, *) { return true }
        #endif
        return false
    }

    static var supportDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Phonon", isDirectory: true)
    }

    // MARK: Voices

    private static let voiceCache = NSCache<NSString, NSArray>()

    /// The model's voices in the catalog's order (its best voices first),
    /// limited to the ones whose files the model actually has.
    static func voices(of model: PhononModel) -> [PhononVoice] {
        guard let folder = model.location else { return [] }
        let key = folder.path as NSString
        if let cached = voiceCache.object(forKey: key) as? [PhononVoice] { return cached }
        let voices = catalog(in: folder)
        voiceCache.setObject(voices as NSArray, forKey: key)
        return voices
    }

    /// After a model is downloaded or removed.
    static func reloadVoices() { voiceCache.removeAllObjects() }

    static func catalog(in folder: URL) -> [PhononVoice] {
        let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("voices").path)) ?? [])
            .map { ($0 as NSString).deletingPathExtension })
        guard let text = try? String(contentsOf: folder.appendingPathComponent("voices.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = row["name"] as? String, present.contains(name),
                  let language = row["language"] as? String else { return nil }
            return PhononVoice(name: name, language: language,
                               locale: row["locale"] as? String ?? "", gender: row["gender"] as? String ?? "")
        }
    }

    /// The voice to read `language` with: the one chosen in Settings if the
    /// model has it, else the catalog's first voice for the language.
    static func voice(of model: PhononModel, language: String, preferred: String?) -> String? {
        let candidates = voices(of: model).filter { $0.language == language }
        if let preferred, candidates.contains(where: { $0.name == preferred }) { return preferred }
        return candidates.first?.name
    }

    // MARK: Model files

    /// Copies the bundled model out of the read-only app into Application
    /// Support once per model version (`built` in bundle.json changes with
    /// every export). Excluded from backup: it can always be copied again.
    static func installedModel(from source: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("PhononModel", isDirectory: true)
        guard let wanted = built(source) else {
            throw EngineError("The bundled voice model has no readable bundle.json.")
        }
        if built(destination) == wanted { return destination }
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        excludeFromBackup(destination)
        return destination
    }

    static func built(_ folder: URL) -> Int? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("bundle.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["built"] as? Int
    }

    static func excludeFromBackup(_ folder: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try? url.setResourceValues(values)
    }

    struct EngineError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Speaking

    private let queue = DispatchQueue(label: "com.icyweasel.phonon", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var loadedModel: PhononModel?
    private var currentVoice: String?
    private var currentLanguage: String?
    private var loadErrors: [PhononModel: String] = [:]

    /// Speaks `text` in `voice`, normalising numbers and symbols as
    /// `language`, handing each 80 ms chunk of 24 kHz mono audio to `onAudio`
    /// as soon as it is made, on the engine's queue. Generation stops early
    /// when `onAudio` returns false. Switching model frees the other one; the
    /// very first load after an install compiles the model (a few seconds).
    func speak(_ text: String, model: PhononModel, language: String, voice: String,
               onAudio: @escaping ([Float]) -> Bool, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                try speakNow(text, model: model, language: language, voice: voice, onAudio: onAudio)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Frees the loaded model, so a removed download is not held open.
    func unload(_ model: PhononModel) {
        queue.async { [self] in
            guard loadedModel == model else { return }
            #if arch(arm64) && canImport(PhononCore)
            if let handle { ptts_free(handle) }
            #endif
            handle = nil
            loadedModel = nil
            loadErrors[model] = nil
        }
    }

    private func speakNow(_ text: String, model: PhononModel, language: String, voice: String,
                          onAudio: @escaping ([Float]) -> Bool) throws {
        #if arch(arm64) && canImport(PhononCore)
        guard #available(macOS 15, *) else { throw EngineError("Phonon needs macOS 15.") }
        let handle = try loaded(model)
        if currentLanguage != language {
            guard language.withCString({ ptts_set_language(handle, $0) }) else { throw lastError(handle) }
            currentLanguage = language
        }
        if currentVoice != voice {
            guard voice.withCString({ ptts_set_voice(handle, $0) }) else { throw lastError(handle) }
            currentVoice = voice
        }
        final class Sink { let onAudio: ([Float]) -> Bool; init(_ f: @escaping ([Float]) -> Bool) { onAudio = f } }
        let sink = Unmanaged.passRetained(Sink(onAudio))
        defer { sink.release() }
        var result = PttsResult()
        let ok = text.withCString { cText in
            ptts_speak(handle, cText, { pcm, count, user in
                guard let pcm, let user else { return false }
                let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
                return sink.onAudio(Array(UnsafeBufferPointer(start: pcm, count: count)))
            }, sink.toOpaque(), &result)
        }
        guard ok else { throw lastError(handle) }
        #else
        throw EngineError("Phonon is not part of this build.")
        #endif
    }

    #if arch(arm64) && canImport(PhononCore)
    private func loaded(_ model: PhononModel) throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(queue))
        if let handle, loadedModel == model { return handle }
        if let error = loadErrors[model] { throw EngineError(error) }
        if let handle {
            ptts_free(handle)
            self.handle = nil
            loadedModel = nil
        }
        do {
            guard let source = model.location, let support = Self.supportDirectory
            else { throw EngineError("\(model.title) is not on this Mac.") }
            let folder = model == .english31m ? try Self.installedModel(from: source, into: support) : source
            // The library finds Core ML's classes by name at run time, and the
            // linker drops a framework nothing calls. Making one object keeps
            // Core ML linked and loaded before the library looks.
            _ = MLModelConfiguration()
            guard let made = folder.path.withCString({ path in
                "en".withCString { ptts_new(path, UInt32(PTTS_UNIT_ANE), $0) }
            }) else { throw lastError(nil) }
            handle = made
            loadedModel = model
            currentVoice = nil
            currentLanguage = "en"
            return made
        } catch {
            // A model that failed to load fails the same way next time; say so
            // at once instead of copying and compiling again on every page.
            loadErrors[model] = String(describing: error)
            throw error
        }
    }

    private func lastError(_ handle: OpaquePointer?) -> EngineError {
        EngineError(ptts_last_error(handle).map { String(cString: $0) } ?? "Phonon failed without saying why.")
    }
    #endif
}

/// Read Page Aloud's voice setting.
enum ReadAloudEngine: String, CaseIterable, Identifiable {
    case phonon31m = "phonon-31m-en"
    case phonon40mMultilingual = "phonon-40m-multilingual"
    case apple = "system"

    var id: String { rawValue }

    /// The choices Settings shows: the multilingual model only once its
    /// download has been published (`PhononModelDownload.isPublished`).
    @MainActor static var offered: [ReadAloudEngine] {
        allCases.filter { $0 != .phonon40mMultilingual || PhononModelDownload.isPublished || PhononModel.multilingual40m.location != nil }
    }

    var model: PhononModel? {
        switch self {
        case .phonon31m: .english31m
        case .phonon40mMultilingual: .multilingual40m
        case .apple: nil
        }
    }

    var title: String { model?.title ?? "Apple's voices" }
}
