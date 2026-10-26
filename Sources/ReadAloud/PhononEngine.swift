import Foundation
#if arch(arm64) && canImport(PhononCore)
import CoreML
import PhononCore
#endif

/// Phonon 31m, Gradium's on-device voice (Apache 2.0), driven through its C
/// library. `scripts/fetch-phonon.sh` puts the library and the model in
/// ThirdParty/Phonon; without them, or on an Intel Mac (the library is arm64
/// only) or macOS 14 (the models are Core ML 8 programs), `isSupported` is
/// false and Read Page Aloud uses Apple's voices.
///
/// The model loads once per app and is shared by every window. Every call
/// into it runs on one serial queue: the library is not reentrant.
final class PhononEngine: @unchecked Sendable {
    static let shared = PhononEngine()
    static let sampleRate: Double = 24_000

    /// The voices in the bundled model, named by their files: Gradium's
    /// English narrators, American then British, then its character voices.
    /// The model's own "default" duplicates one of them and is left out.
    static let voices: [String] = [
        "Zoey", "Juniper", "Everly", "Harper", "Hadley", "Delia",
        "Easton", "Micah", "Trevor", "Russell", "Preston", "Miles",
        "Maeve", "Freya", "Pippa", "Elodie-Rose", "Imogen", "Lottie", "Bryony",
        "Alfie", "Hugh", "Edwin", "Spencer", "Toby", "Teddy",
        "Captain Silas Blackwater", "Fairy Godmother", "Fennick the Young Elf", "Grub the Ogre",
        "Master Aldric", "Morwenna of the Deep", "Old Mortlake", "Sir Bramwell", "The Snow Queen",
        "The Thing Under the Stairs", "Vyrmathrax the Ancient", "Azgorath",
    ]
    static let defaultVoice = "Zoey"

    /// The model folder copied into the app from ThirdParty/Phonon.
    static var bundledModel: URL? {
        Bundle.main.url(forResource: "PhononModel", withExtension: nil)
    }

    static var isSupported: Bool {
        #if arch(arm64) && canImport(PhononCore)
        if #available(macOS 15, *) { return bundledModel != nil }
        #endif
        return false
    }

    private let queue = DispatchQueue(label: "com.icyweasel.phonon", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var currentVoice: String?
    private var loadError: String?

    // MARK: Model files

    /// Core ML compiles each model beside itself, so the bundle is copied out
    /// of the read-only app into Application Support once per model version
    /// (`built` in bundle.json changes with every export). Excluded from
    /// backup: it can always be copied again.
    static func installedModel(from source: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent("PhononModel", isDirectory: true)
        func built(_ folder: URL) -> Int? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("bundle.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["built"] as? Int
        }
        guard let wanted = built(source) else {
            throw EngineError("The bundled voice model has no readable bundle.json.")
        }
        if built(destination) == wanted { return destination }
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = destination
        try? url.setResourceValues(values)
        return destination
    }

    struct EngineError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: Speaking

    /// Speaks `text` in `voice`, handing each 80 ms chunk of 24 kHz mono audio
    /// to `onAudio` as soon as it is made, on the engine's queue. Generation
    /// stops early when `onAudio` returns false. The first call loads the
    /// model, and the very first after an install compiles it for this Mac
    /// (a few seconds).
    func speak(_ text: String, voice: String, onAudio: @escaping ([Float]) -> Bool,
               completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            do {
                try speakNow(text, voice: voice, onAudio: onAudio)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private func speakNow(_ text: String, voice: String, onAudio: @escaping ([Float]) -> Bool) throws {
        #if arch(arm64) && canImport(PhononCore)
        guard #available(macOS 15, *) else { throw EngineError("Phonon needs macOS 15.") }
        let handle = try loaded()
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
    private func loaded() throws -> OpaquePointer {
        dispatchPrecondition(condition: .onQueue(queue))
        if let handle { return handle }
        if let loadError { throw EngineError(loadError) }
        do {
            guard let source = Self.bundledModel,
                  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else { throw EngineError("The voice model is not in this build.") }
            let model = try Self.installedModel(from: source, into: support.appendingPathComponent("Phonon", isDirectory: true))
            // The library finds Core ML's classes by name at run time, and the
            // linker drops a framework nothing calls. Making one object keeps
            // Core ML linked and loaded before the library looks.
            _ = MLModelConfiguration()
            guard let made = model.path.withCString({ path in
                "en".withCString { ptts_new(path, UInt32(PTTS_UNIT_ANE), $0) }
            }) else { throw lastError(nil) }
            handle = made
            return made
        } catch {
            // A model that failed to load fails the same way next time; say so
            // at once instead of copying and compiling again on every page.
            loadError = String(describing: error)
            throw error
        }
    }

    private func lastError(_ handle: OpaquePointer?) -> EngineError {
        EngineError(ptts_last_error(handle).map { String(cString: $0) } ?? "Phonon failed without saying why.")
    }
    #endif
}
