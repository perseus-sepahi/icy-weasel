import Foundation
import AppKit
import Security

// MARK: - Sources and models

/// Somewhere a model runs: a local server on this Mac, or a cloud API the user
/// configured with their own key.
struct AISource: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Ollama's native API (`/api/tags`, `/api/chat`).
        case ollama
        /// The OpenAI-style API most servers speak (`/v1/models`, `/v1/chat/completions`):
        /// llama.cpp (Bonsai), MLX, LM Studio, Jan, GPT4All, OpenAI, Gemini, OpenRouter…
        case openAI
        /// Anthropic's Messages API.
        case anthropic
    }

    let id: String
    let name: String
    let kind: Kind
    /// Ollama: server root. OpenAI/Anthropic: API root including `/v1`.
    let baseURL: URL
    let isLocal: Bool
    /// Known to be a model server: Ollama (identified by its own API), an
    /// address the user added, or a cloud provider the user configured.
    /// A server merely answering on a common port (8000, 8080…) could be any
    /// program, so it is listed but never used until the user picks it.
    var isVerified: Bool = true
    /// Where page text actually ends up, when that isn't `baseURL`: Ollama's
    /// cloud models are reached through the local app but run on ollama.com.
    var remoteHost: String? = nil

    /// The host shown to the user as the destination of page text.
    var destinationHost: String { remoteHost ?? baseURL.host ?? name }
}

struct AIModelChoice: Identifiable, Hashable, Sendable {
    let source: AISource
    let model: String
    var sizeBytes: Int64?
    var id: String { "\(source.id)|\(model)" }

    /// llama.cpp reports a model by its file path; show just the model's name.
    var displayName: String {
        var name = (model as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        return name
    }
}

// MARK: - Cloud providers (user's own API key)

enum CloudPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, anthropic, gemini, openRouter, groq, mistral, deepSeek
    /// Hosts of open-source models (Llama, Qwen, DeepSeek, Mistral, Gemma…).
    case ollamaCloud, huggingFace, together, fireworks, deepInfra, cerebras
    case custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .ollamaCloud: return "Ollama Cloud (open models)"
        case .huggingFace: return "Hugging Face (open models)"
        case .together: return "Together AI (open models)"
        case .fireworks: return "Fireworks AI (open models)"
        case .deepInfra: return "DeepInfra (open models)"
        case .cerebras: return "Cerebras (open models)"
        case .custom: return "Other (OpenAI-compatible)"
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .ollamaCloud: return "https://ollama.com"
        case .huggingFace: return "https://router.huggingface.co/v1"
        case .together: return "https://api.together.xyz/v1"
        case .fireworks: return "https://api.fireworks.ai/inference/v1"
        case .deepInfra: return "https://api.deepinfra.com/v1/openai"
        case .cerebras: return "https://api.cerebras.ai/v1"
        case .custom: return ""
        }
    }

    var kind: AISource.Kind {
        switch self {
        case .anthropic: return .anthropic
        case .ollamaCloud: return .ollama
        default: return .openAI
        }
    }
}

struct CloudProviderConfig: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var preset: CloudPreset
    var customName = ""
    var customBaseURL = ""
    /// Used when the provider can't list its models.
    var manualModel = ""

    var name: String {
        guard preset == .custom else { return preset.title }
        return customName.isEmpty ? (baseURL?.host ?? "Custom") : customName
    }

    /// HTTPS only: an API key must never travel in the clear.
    var baseURL: URL? {
        let raw = preset == .custom ? customBaseURL : preset.baseURL
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    var source: AISource? {
        baseURL.map { AISource(id: "cloud:\(id)", name: name, kind: preset.kind, baseURL: $0, isLocal: false) }
    }
}

/// API keys live in the login keychain, never in preferences or on disk.
enum AIKeychain {
    static let service = "com.icyweasel.browser.ai"

    @discardableResult
    static func save(_ key: String, for account: String) -> Bool {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Local discovery

/// Finds model servers running on this Mac by asking the ports local AI tools
/// use. Anything that answers is listed with its models, so a newly installed
/// tool or model appears without an app update.
enum LocalAIDiscovery {
    struct Candidate: Sendable {
        let port: Int
        let name: String
        let kind: AISource.Kind
    }

    static let candidates: [Candidate] = [
        .init(port: 11434, name: "Ollama", kind: .ollama),
        .init(port: 1234, name: "LM Studio", kind: .openAI),
        .init(port: 8080, name: "llama.cpp server", kind: .openAI),   // Bonsai's start_llama_server.sh, AI Navigator
        .init(port: 8081, name: "MLX server", kind: .openAI),         // Bonsai's start_mlx_server.sh
        .init(port: 9931, name: "llama.cpp server", kind: .openAI),   // llama.cpp's announced new default
        .init(port: 1337, name: "Jan", kind: .openAI),
        .init(port: 4891, name: "GPT4All", kind: .openAI),
        .init(port: 8000, name: "Local server", kind: .openAI),
    ]

    /// Apps whose server we can start for the user when it isn't running.
    struct StartableApp: Hashable, Sendable { let name: String; let bundleID: String; let port: Int }
    static let startableApps: [StartableApp] = [
        .init(name: "Ollama", bundleID: "com.electron.ollama", port: 11434),
    ]

    /// Installed apps whose server isn't answering right now.
    @MainActor
    static func stoppedApps(running: Set<Int>) -> [StartableApp] {
        startableApps.filter {
            !running.contains($0.port) && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Loopback only: custom local endpoints can never point off this Mac.
    static func loopbackURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        else { return nil }
        return url
    }

    /// Probes every known port plus the user's own local addresses, in parallel.
    /// `launcherPorts`: ports of servers the user set up a start script for,
    /// which makes them known rather than "something on a common port".
    static func discover(customEndpoints: [String], launcherPorts: Set<Int> = []) async -> [AIModelChoice] {
        var targets: [(AISource, Bool)] = candidates.map { c in
            let root = URL(string: "http://127.0.0.1:\(c.port)")!
            let base = c.kind == .ollama ? root : root.appendingPathComponent("v1")
            return (AISource(id: "local:\(c.port)", name: c.name, kind: c.kind, baseURL: base, isLocal: true,
                             isVerified: c.kind == .ollama || launcherPorts.contains(c.port)), false)
        }
        for raw in customEndpoints {
            guard var url = loopbackURL(raw) else { continue }
            if url.path.isEmpty || url.path == "/" { url = url.appendingPathComponent("v1") }
            let id = "local:\(url.absoluteString)"
            if targets.contains(where: { $0.0.baseURL == url }) { continue }
            targets.append((AISource(id: id, name: "\(url.host ?? "localhost"):\(url.port ?? 80)", kind: .openAI,
                                     baseURL: url, isLocal: true), true))
        }
        return await withTaskGroup(of: [AIModelChoice].self) { group in
            for (source, _) in targets {
                group.addTask { await models(at: source, apiKey: nil) }
            }
            var all: [AIModelChoice] = []
            for await found in group { all += found }
            return all.sorted { ($0.source.name, $0.model) < ($1.source.name, $1.model) }
        }
    }

    /// Lists a source's chat models. Empty if it doesn't answer.
    static func models(at source: AISource, apiKey: String?) async -> [AIModelChoice] {
        do {
            switch source.kind {
            case .ollama:
                let (data, response) = try await probeSession.data(from: source.baseURL.appendingPathComponent("api/tags"))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
                struct Tags: Decodable {
                    struct Model: Decodable { let name: String; let size: Int64?; let remote_host: String? }
                    let models: [Model]
                }
                // Ollama's "cloud" models are listed by the local app but run on
                // ollama.com: they're cloud models for privacy purposes.
                let cloudSource = AISource(id: "\(source.id):cloud", name: "Ollama Cloud", kind: .ollama,
                                           baseURL: source.baseURL, isLocal: false, isVerified: true,
                                           remoteHost: "ollama.com")
                return try JSONDecoder().decode(Tags.self, from: data).models
                    .filter { isChatModel($0.name) }
                    .map { m in
                        let remote = source.isLocal && (m.remote_host != nil || isOllamaCloudModel(m.name))
                        return AIModelChoice(source: remote ? cloudSource : source, model: m.name,
                                             sizeBytes: remote ? nil : m.size)
                    }
            case .openAI, .anthropic:
                var request = URLRequest(url: source.baseURL.appendingPathComponent("models"))
                request.timeoutInterval = source.isLocal ? 1.5 : 10
                AIClient.authorize(&request, source: source, apiKey: apiKey)
                let session = source.isLocal ? probeSession : AIClient.session
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
                struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
                let ids = try JSONDecoder().decode(List.self, from: data).data.map(\.id)
                    .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }   // Gemini
                    .filter(isChatModel)
                // Name a generic llama.cpp/MLX server after the model it serves.
                let renamed = source.isLocal && ids.contains { $0.lowercased().contains("bonsai") }
                    ? AISource(id: source.id, name: "Bonsai", kind: source.kind, baseURL: source.baseURL, isLocal: true,
                               isVerified: source.isVerified, remoteHost: nil)
                    : source
                return ids.map { AIModelChoice(source: renamed, model: $0) }
            }
        } catch {
            return []
        }
    }

    static func isOllamaCloudModel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("-cloud") || lower.hasSuffix(":cloud") || lower.contains("-cloud:")
    }

    /// Excludes models that can't chat (embeddings, speech, image generation).
    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "audio-preview",
                 "imagen", "image-generation", "rerank"].contains { lower.contains($0) }
    }
}

// MARK: - Streaming chat

enum AIClient {
    struct ChatMessage: Sendable { var role: String; var content: String }

    enum Failure: LocalizedError {
        case http(Int, String)
        case model(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let message): return message.isEmpty ? "The model server returned HTTP \(code)." : message
            case .model(let message): return message
            }
        }
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// The key goes only to the cloud provider it belongs to, and only over HTTPS.
    static func authorize(_ request: inout URLRequest, source: AISource, apiKey: String?) {
        guard !source.isLocal, let apiKey, !apiKey.isEmpty,
              request.url?.scheme == "https", request.url?.host == source.baseURL.host else { return }
        switch source.kind {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI, .ollama:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Streams the reply, calling `onText` with the full text so far.
    static func stream(_ messages: [ChatMessage], system: String, choice: AIModelChoice, apiKey: String?,
                       onText: @escaping @MainActor (String) -> Void) async throws {
        let source = choice.source
        var request: URLRequest
        var body: [String: Any]
        switch source.kind {
        case .ollama:
            request = URLRequest(url: source.baseURL.appendingPathComponent("api/chat"))
            body = ["model": choice.model, "stream": true, "think": false,
                    "messages": [["role": "system", "content": system]] + messages.map { ["role": $0.role, "content": $0.content] },
                    "options": ["num_ctx": 8192, "temperature": 0.3]]
        case .openAI:
            request = URLRequest(url: source.baseURL.appendingPathComponent("chat/completions"))
            body = ["model": choice.model, "stream": true, "temperature": 0.3,
                    "messages": [["role": "system", "content": system]] + messages.map { ["role": $0.role, "content": $0.content] }]
        case .anthropic:
            request = URLRequest(url: source.baseURL.appendingPathComponent("messages"))
            body = ["model": choice.model, "stream": true, "max_tokens": 2048, "system": system,
                    "messages": alternating(messages).map { ["role": $0.role, "content": $0.content] }]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, source: source, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line; if raw.count > 4_000 { break } }
            throw Failure.http(status, errorMessage(raw))
        }

        var reply = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let payload: String
            if source.kind == .ollama { payload = line }
            else if line.hasPrefix("data:") { payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else { continue }
            if payload == "[DONE]" { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let message = errorText(object) { throw Failure.model(message) }
            if let piece = textPiece(object, kind: source.kind), !piece.isEmpty {
                reply += piece
                await onText(reply)
            }
        }
    }

    static func textPiece(_ object: [String: Any], kind: AISource.Kind) -> String? {
        switch kind {
        case .ollama:
            return (object["message"] as? [String: Any])?["content"] as? String
        case .openAI:
            let choice = (object["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        case .anthropic:
            guard object["type"] as? String == "content_block_delta",
                  let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        }
    }

    static func errorText(_ object: [String: Any]) -> String? {
        if let message = object["error"] as? String { return message }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String ?? "The model reported an error." }
        return nil
    }

    static func errorMessage(_ raw: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            return String(raw.prefix(300))
        }
        return errorText(object) ?? String(raw.prefix(300))
    }

    /// Anthropic needs user/assistant turns to alternate, starting with the user.
    static func alternating(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for message in messages where !message.content.isEmpty {
            if let last = out.last, last.role == message.role {
                out[out.count - 1].content += "\n\n" + message.content
            } else {
                out.append(message)
            }
        }
        while out.first?.role == "assistant" { out.removeFirst() }
        return out
    }
}

// MARK: - Start scripts

/// A model server that starts from a script rather than an app, such as
/// Bonsai's `start_llama_server.sh`. The browser is sandboxed and can't see
/// those files on its own, so the user picks the script once; a security-scoped
/// bookmark remembers it, and "Start" hands it to Terminal to run.
struct LocalAILauncher: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var bookmark: Data
    /// Where the server listens once started.
    var port: Int

    /// Bonsai's scripts: llama.cpp on 8080, MLX on 8081.
    static func defaults(for script: URL) -> (name: String, port: Int) {
        let path = script.path.lowercased()
        let name = path.contains("bonsai") ? "Bonsai" : script.deletingPathExtension().lastPathComponent
        return (name, path.contains("mlx") ? 8081 : 8080)
    }

    func resolvedURL() -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// Opens the script in Terminal, which runs it in a window the user can see and stop.
    @MainActor
    func start() -> Bool {
        guard let url = resolvedURL(),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { _, _ in
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return true
    }
}
