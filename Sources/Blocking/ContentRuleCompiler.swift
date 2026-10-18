import Foundation

// MARK: - WebKit content-rule JSON model

struct ContentRule: Encodable, Hashable {
    struct Trigger: Encodable, Hashable {
        var urlFilter: String
        var urlFilterIsCaseSensitive: Bool?
        var resourceType: [String]?
        var loadType: [String]?
        var ifDomain: [String]?
        var unlessDomain: [String]?
        var ifTopURL: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case ifTopURL = "if-top-url"
        }
    }

    struct Action: Encodable, Hashable {
        var type: String
        var selector: String?
    }

    var trigger: Trigger
    var action: Action
}

struct CompileStats: Codable, Equatable, Sendable {
    var totalLines = 0
    var comments = 0
    var networkRules = 0
    var cosmeticRules = 0
    var exceptionRules = 0
    /// `$generichide` / `$elemhide` / `$document` exceptions, compiled page-scoped.
    var pageExceptions = 0
    var rejected = 0
    var rejectionsByReason: [String: Int] = [:]
    /// Identical rules emitted by more than one list (or by different source
    /// text that translates to the same trigger), removed before compiling.
    var duplicatesRemoved = 0
    /// Block rules already covered by an unconditional `||host^` rule for the
    /// same host or a parent domain.
    var subsumedRemoved = 0

    var converted: Int { networkRules + cosmeticRules + exceptionRules + pageExceptions }

    mutating func note(_ rejection: FilterRejection) {
        switch rejection {
        case .comment, .empty:
            comments += 1
        case .unsupportedOption(let o):
            rejected += 1; rejectionsByReason["option:\(o)", default: 0] += 1
        case .unsupportedSyntax(let s):
            rejected += 1; rejectionsByReason["syntax:\(s)", default: 0] += 1
        case .unsupportedSelector(let s):
            rejected += 1; rejectionsByReason["selector:\(s)", default: 0] += 1
        case .emptyPattern:
            rejected += 1; rejectionsByReason["empty-pattern", default: 0] += 1
        }
    }
}

struct CompiledRuleset {
    /// Each chunk becomes one `WKContentRuleList`.
    var chunks: [[ContentRule]]
    var stats: CompileStats
}

// MARK: - Compiler

/// Translates parsed Adblock filters into WebKit content-blocker rules.
///
/// Two invariants drive the whole design:
///
/// 1. **Ordering.** WebKit evaluates rules top-to-bottom and
///    `ignore-previous-rules` only cancels rules *above* it. So every chunk is
///    laid out as `[block…] + [css-display-none…] + [ignore-previous-rules…]`.
///
/// 2. **Chunk independence.** Rule lists do not see each other, so an exception
///    in list B cannot undo a block in list A. Every chunk therefore carries a
///    full copy of the exception tail. Exceptions are a small share of a typical
///    list, so the duplication is cheap next to silently breaking sites.
struct ContentRuleCompiler {

    /// Expansion for the `^` separator token, which in ABP means "a separator
    /// character *or* the end of the URL". Probed against WebKit at startup.
    ///
    /// As of the WebKit this was built against, alternation is rejected
    /// outright, so `.strict` is unavailable and `.compatible` is used. The
    /// missing end-of-URL case is then covered by emitting a second rule — see
    /// `makeRules(from:)`. The probe stays so a future WebKit that accepts
    /// alternation gets the single-rule form automatically.
    enum SeparatorStyle {
        /// Matches a separator character *or* the end of the URL, in one rule.
        case strict
        /// Character class only; end-of-URL needs a companion rule.
        case compatible

        var pattern: String {
            switch self {
            case .strict:     return "($|[^a-zA-Z0-9_.%-])"
            case .compatible: return "[^a-zA-Z0-9_.%-]"
            }
        }
    }

    var separatorStyle: SeparatorStyle = .strict
    var maxRulesPerChunk: Int = Self.defaultMaxRulesPerChunk

    /// Rules per compiled list. Measured on a real page (SpeedInvestigation):
    /// every list carries its own copy of the exceptions and is consulted on
    /// every resource load, so the default filter set costs +127 ms of parsing
    /// as 8 network lists but +55 ms as 2, and also compiles faster. WebKit
    /// refused a ~213k-rule list on this hardware; lists that are too large for
    /// a given machine are split by ContentBlockerStore rather than dropped.
    static let defaultMaxRulesPerChunk = 110_000

    /// Part of the compiled-list cache key. Compiled bytecode is cached by input
    /// hash, so without this a compiler fix would never reach users: unchanged
    /// filter lists would keep hitting bytecode built by the old, buggy compiler.
    /// Combined with the app build number, so any shipped update recompiles once.
    static let outputVersion = 7

    // MARK: Layers

    /// Where a rule sits inside its chunk, and which family of chunks it lives in.
    ///
    /// `ignore-previous-rules` cancels only the rules *above* it, so position is
    /// how each kind of exception is given exactly its intended reach.
    ///
    /// Cosmetic and network rules live in separate lists: they never need to
    /// cancel each other, and measurement showed the cost of `.*`-triggered
    /// exceptions is paid on every resource load in every list that carries
    /// them. Page exceptions that only affect cosmetics therefore exist once, in
    /// the cosmetic family, instead of in every network list.
    enum Layer: Int, CaseIterable, Comparable {
        case genericCosmetic            // `.*`, no conditions: WebKit's fast universal stylesheet
        case conditionedGenericCosmetic // generic with `~domain` / `#@#` exclusions, document-scoped
        case genericHideExceptions
        case specificCosmetic           // document-scoped, one merged rule per site
        case elementHideExceptions
        case networkBlocks
        case networkExceptions
        case documentExceptions

        enum Family: CaseIterable { case cosmetic, network }

        var isException: Bool {
            switch self {
            case .genericHideExceptions, .elementHideExceptions, .networkExceptions, .documentExceptions: return true
            default: return false
            }
        }

        /// `$document` exceptions allowlist the whole page, so both families need them.
        func belongs(to family: Family) -> Bool {
            switch self {
            case .documentExceptions: return true
            case .networkBlocks, .networkExceptions: return family == .network
            default: return family == .cosmetic
            }
        }

        static func < (a: Layer, b: Layer) -> Bool { a.rawValue < b.rawValue }

        init(pageScope: PageScope) {
            switch pageScope {
            case .genericHide: self = .genericHideExceptions
            case .elementHide: self = .elementHideExceptions
            case .document:    self = .documentExceptions
            }
        }
    }

    // MARK: Entry point

    func compile(lines: some Sequence<String>) -> CompiledRuleset {
        var stats = CompileStats()
        var layers: [Layer: [ContentRule]] = [:]
        var cosmetics: [CosmeticFilter] = []
        var cosmeticExceptions: [CosmeticFilter] = []

        var parsed: [ParsedFilter] = []
        for line in lines {
            stats.totalLines += 1
            switch AdblockParser.parse(line: line) {
            case .failure(let reason): stats.note(reason)
            case .success(let filter): parsed.append(filter)
            }
        }
        let coveringHosts = Self.unconditionalBlockedHosts(in: parsed)

        for item in parsed {
            switch item {
            case .network(let filter) where !filter.isException && Self.isSubsumed(filter, by: coveringHosts):
                stats.subsumedRemoved += 1

            case .network(let filter) where filter.isException && filter.pageScope != nil:
                guard let rule = makePageException(from: filter) else {
                    stats.note(.unsupportedSyntax("page-exception-scope")); continue
                }
                layers[Layer(pageScope: filter.pageScope!), default: []].append(rule)
                stats.pageExceptions += 1

            case .network(let filter):
                let rules = makeRules(from: filter)
                guard !rules.isEmpty else {
                    stats.note(.unsupportedSyntax("url-filter")); continue
                }
                if filter.isException {
                    layers[.networkExceptions, default: []] += rules; stats.exceptionRules += 1
                } else {
                    layers[.networkBlocks, default: []] += rules; stats.networkRules += 1
                }

            case .cosmetic(let filter):
                if filter.isException { cosmeticExceptions.append(filter) }
                else { cosmetics.append(filter) }
            }
        }

        let cosmeticRules = makeCosmeticRules(cosmetics, exceptions: cosmeticExceptions, stats: &stats)
        layers[.genericCosmetic, default: []] += cosmeticRules.universal
        layers[.conditionedGenericCosmetic, default: []] += cosmeticRules.conditioned
        layers[.specificCosmetic, default: []] += cosmeticRules.siteSpecific

        var unique: [Layer: [ContentRule]] = [:]
        for (layer, rules) in layers {
            let deduped = Self.deduplicated(rules)
            stats.duplicatesRemoved += rules.count - deduped.count
            unique[layer] = deduped
        }
        return CompiledRuleset(chunks: chunk(unique), stats: stats)
    }

    // MARK: Subsumption

    /// Hosts blocked outright: `||host^` with no options. Such a rule blocks every
    /// request to the host and its subdomains, whatever the type or context.
    static func unconditionalBlockedHosts(in filters: [ParsedFilter]) -> Set<String> {
        var hosts = Set<String>()
        for case .network(let f) in filters
        where !f.isException && f.domainAnchored && !f.isRawRegex && !f.startAnchored && !f.endAnchored
            && f.resourceTypes.isEmpty && f.loadType == nil && f.includeDomains.isEmpty
            && f.excludeDomains.isEmpty && !f.matchCase && f.pattern.hasSuffix("^")
        {
            let host = f.pattern.dropLast()
            if !host.isEmpty, !host.contains(where: { "/*^?:=&|#".contains($0) }) {
                hosts.insert(host.lowercased())
            }
        }
        return hosts
    }

    /// True when a covering `||parent^` rule already blocks everything this rule
    /// could. Removing it cannot change any outcome: a request it matches is
    /// matched by the covering rule too, and any exception that would cancel one
    /// cancels both, because `ignore-previous-rules` cancels every rule above it.
    static func isSubsumed(_ f: NetworkFilter, by hosts: Set<String>) -> Bool {
        guard !hosts.isEmpty, f.domainAnchored, !f.isRawRegex else { return false }
        // The host must be a literal followed by something `^` would match
        // (`/`, `:`, `^` itself). A wildcard or bare end could reach
        // `tracker.com.au`, which `||tracker.com^` does not block.
        guard let end = f.pattern.firstIndex(where: { "/:^*?|=&#".contains($0) }),
              "/:^".contains(f.pattern[end])
        else { return false }
        var host = f.pattern[f.pattern.startIndex..<end].lowercased()
        guard !host.isEmpty else { return false }

        // Never let a rule subsume itself; only a covering rule elsewhere counts.
        let isItselfCovering = f.pattern.hasSuffix("^") && f.pattern.dropLast().lowercased() == host
            && f.resourceTypes.isEmpty && f.loadType == nil && f.includeDomains.isEmpty
            && f.excludeDomains.isEmpty && !f.matchCase && !f.startAnchored && !f.endAnchored
        if !isItselfCovering, hosts.contains(host) { return true }

        // Parent domains: ads.tracker.com is covered by ||tracker.com^.
        while let dot = host.firstIndex(of: ".") {
            host = String(host[host.index(after: dot)...])
            guard host.contains(".") else { break } // never a bare TLD
            if hosts.contains(host) { return true }
        }
        return false
    }

    /// Keeping the first occurrence is safe: order only matters *between* layers.
    private static func deduplicated(_ rules: [ContentRule]) -> [ContentRule] {
        var seen = Set<ContentRule>()
        seen.reserveCapacity(rules.count)
        return rules.filter { seen.insert($0).inserted }
    }

    // MARK: Chunking

    /// Splits each family's content rules across chunks, giving every chunk the
    /// family's complete exception set, laid out in layer order. Rule lists cannot
    /// see one another, so an exception only works on rules in its own chunk.
    private func chunk(_ layers: [Layer: [ContentRule]]) -> [[ContentRule]] {
        Layer.Family.allCases.flatMap { family -> [[ContentRule]] in
            let familyLayers = Layer.allCases.filter { $0.belongs(to: family) }
            let exceptionCount = familyLayers.filter(\.isException).reduce(0) { $0 + (layers[$1]?.count ?? 0) }
            let content: [(Layer, ContentRule)] = familyLayers
                .filter { !$0.isException }
                .flatMap { layer in (layers[layer] ?? []).map { (layer, $0) } }
            // A family with no rules of its own needs no list, even if
            // `$document` exceptions exist: there is nothing for them to cancel.
            guard !content.isEmpty else { return [] }

            let budget = max(1, maxRulesPerChunk - exceptionCount)
            var result: [[ContentRule]] = []
            var index = 0
            while index < content.count {
                let end = min(index + budget, content.count)
                var byLayer: [Layer: [ContentRule]] = [:]
                for (layer, rule) in content[index..<end] { byLayer[layer, default: []].append(rule) }
                result.append(familyLayers.flatMap { layer in
                    layer.isException ? (layers[layer] ?? []) : (byLayer[layer] ?? [])
                })
                index = end
            }
            return result
        }
    }

    // MARK: Page-scoped exceptions

    /// Builds the trigger for an exception that applies to whole pages.
    ///
    /// The page is identified by `if-domain` when the filter names only hosts
    /// (`@@||bing.com^$generichide`, `@@*$ghide,domain=web.de`), or by
    /// `if-top-url` when it names a path (`@@||bing.com/search?$generichide`).
    /// WebKit rejects both keys together, so a filter needing both is dropped
    /// rather than widened — a wider `$document` exception disables blocking on
    /// pages its author never listed.
    func makePageException(from filter: NetworkFilter) -> ContentRule? {
        let include = normalise(include: filter.includeDomains)
        let exclude = normalise(exclude: filter.excludeDomains)
        guard case let includeList = include, includeList != .unrepresentable,
              case let excludeList = exclude, excludeList != .unrepresentable
        else { return nil }

        var trigger = ContentRule.Trigger(
            urlFilter: ".*", urlFilterIsCaseSensitive: nil, resourceType: nil,
            loadType: nil, ifDomain: nil, unlessDomain: nil
        )

        let stem = filter.pattern.hasSuffix("^") || filter.pattern.hasSuffix("|")
            ? String(filter.pattern.dropLast()) : filter.pattern
        let matchesEverything = !filter.isRawRegex && filter.pattern.allSatisfy { $0 == "*" }
        let isPureHost = filter.domainAnchored && !stem.isEmpty
            && !stem.contains(where: { "/?*^:=&#|".contains($0) })

        if matchesEverything {
            if case .domains(let d) = includeList { trigger.ifDomain = d }
            if case .domains(let d) = excludeList { trigger.unlessDomain = d }
            if trigger.ifDomain != nil && trigger.unlessDomain != nil { return nil }
        } else if isPureHost {
            guard includeList == .unconstrained, excludeList == .unconstrained,
                  stem.allSatisfy(\.isASCII)
            else { return nil }
            trigger.ifDomain = ["*" + stem.lowercased()]
        } else {
            guard includeList == .unconstrained, excludeList == .unconstrained else { return nil }
            var patterns: [String] = []
            if let primary = urlFilterRegex(for: filter) { patterns.append(primary) }
            if needsEndOfURLCompanion(filter), let companion = urlFilterRegex(for: filter, trailingSeparatorAsEnd: true) {
                patterns.append(companion)
            }
            guard !patterns.isEmpty else { return nil }
            trigger.ifTopURL = patterns
        }

        return ContentRule(trigger: trigger, action: .init(type: "ignore-previous-rules", selector: nil))
    }

    // MARK: Cosmetic rules

    private func makeCosmeticRules(
        _ filters: [CosmeticFilter],
        exceptions: [CosmeticFilter],
        stats: inout CompileStats
    ) -> (universal: [ContentRule], conditioned: [ContentRule], siteSpecific: [ContentRule]) {
        // `#@#` unhides a selector on a domain. WebKit has no cosmetic
        // exception, but a generic hide rule can carry `unless-domain`.
        var unhideDomains: [String: [String]] = [:]
        for ex in exceptions {
            unhideDomains[ex.selector, default: []].append(contentsOf: ex.includeDomains)
        }

        var universal: [ContentRule] = []
        var conditioned: [ContentRule] = []
        var siteSpecific: [ContentRule] = []

        for filter in filters {
            let include = normalise(include: filter.includeDomains)
            var unless = filter.excludeDomains
            if include == .unconstrained { unless += unhideDomains[filter.selector] ?? [] }
            let exclude = normalise(exclude: unless)

            switch (include, exclude) {
            case (.unrepresentable, _), (_, .unrepresentable):
                stats.note(.unsupportedSyntax("domain-list")); continue

            case (.unconstrained, .unconstrained):
                // Unconditional: WebKit folds these into one universal stylesheet.
                universal.append(ContentRule(
                    trigger: .init(urlFilter: ".*", urlFilterIsCaseSensitive: nil, resourceType: nil,
                                   loadType: nil, ifDomain: nil, unlessDomain: nil),
                    action: .init(type: "css-display-none", selector: filter.selector)))

            case (.unconstrained, .domains(let excluded)):
                // A condition removes the universal fast path, so scope it to
                // document loads: it is then not a candidate on every subresource.
                conditioned.append(ContentRule(
                    trigger: .init(urlFilter: ".*", urlFilterIsCaseSensitive: nil, resourceType: ["document"],
                                   loadType: nil, ifDomain: nil, unlessDomain: excluded),
                    action: .init(type: "css-display-none", selector: filter.selector)))

            case (.domains(let included), let excludeList):
                // Site-specific rules match the site's own document URL rather
                // than `.*` + if-domain. Measured on a real page, 12k `.*` +
                // if-domain rules cost ~120 ms of parsing: `.*` makes every rule a
                // candidate on every resource load. A url-filter naming the site
                // is a candidate only on that site's documents.
                //
                // Rules are deliberately NOT merged per site. WebKit's compile-time
                // selector validation has gaps (an unterminated `[` compiles), and
                // a merged rule with one such selector silently hides nothing —
                // losing hundreds of filters instead of one.
                var excluded: [String]? = nil
                if case .domains(let d) = excludeList { excluded = d }
                var emitted = false
                for domain in included {
                    guard let urlFilter = Self.documentURLFilter(forHost: String(domain.drop(while: { $0 == "*" }))) else {
                        continue
                    }
                    siteSpecific.append(ContentRule(
                        trigger: .init(urlFilter: urlFilter, urlFilterIsCaseSensitive: nil, resourceType: ["document"],
                                       loadType: nil, ifDomain: nil, unlessDomain: excluded),
                        action: .init(type: "css-display-none", selector: filter.selector)))
                    emitted = true
                }
                guard emitted else { stats.note(.unsupportedSyntax("cosmetic-domain")); continue }
            }
            stats.cosmeticRules += 1
        }
        return (universal, conditioned, siteSpecific)
    }

    /// `^scheme://(subdomain.)?host[:/]` — the host and its subdomains. A canonical
    /// http(s) URL always has a path, so the host is always followed by `:` or `/`.
    static func documentURLFilter(forHost host: String) -> String? {
        guard !host.isEmpty, host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }
        return "^[a-z][a-z0-9+.-]*://([^/?#]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
    }

    // MARK: Domain lists

    enum DomainList: Equatable {
        case unconstrained
        case domains([String])
        /// Contains something WebKit cannot express faithfully.
        case unrepresentable
    }

    /// Normalises a domain list WebKit-style (lowercase, `*` prefix to include
    /// subdomains).
    ///
    /// uBO entity syntax (`gmx.*`) and regex domains compile in WebKit but match
    /// nothing, so they are removed. Removing an *include* entry only narrows the
    /// rule; if nothing remains the rule is dropped rather than left unscoped.
    func normalise(include domains: [String]) -> DomainList {
        guard !domains.isEmpty else { return .unconstrained }
        let usable = domains.compactMap(Self.webKitDomain)
        return usable.isEmpty ? .unrepresentable : .domains(usable)
    }

    /// Removing an *exclude* entry would widen the rule onto a site its author
    /// deliberately exempted, so any unrepresentable entry drops the rule.
    func normalise(exclude domains: [String]) -> DomainList {
        guard !domains.isEmpty else { return .unconstrained }
        let usable = domains.compactMap(Self.webKitDomain)
        return usable.count == domains.count ? .domains(usable) : .unrepresentable
    }

    private static func webKitDomain(_ raw: String) -> String? {
        let d = raw.lowercased()
        guard !d.isEmpty, d.allSatisfy(\.isASCII),
              !d.contains("/"), !d.dropFirst().contains("*"), !d.hasSuffix(".")
        else { return nil }
        return d.hasPrefix("*") ? d : "*" + d
    }

    // MARK: Network rules

    /// Converts one network filter into one or two WebKit rules.
    ///
    /// Two are needed when the pattern ends in `^` and WebKit cannot express
    /// "separator or end of URL" in a single regex: one rule ends in the
    /// separator class, the other in `$`. Pure host patterns (`||ads.com^`) skip
    /// the companion, because a canonical http(s) URL always has a path and so
    /// the host is always followed by `/` or `:` — the `$` form could never match.
    func makeRules(from filter: NetworkFilter) -> [ContentRule] {
        guard let primary = urlFilterRegex(for: filter) else { return [] }
        var ifDomain: [String]?
        var unlessDomain: [String]?
        switch (normalise(include: filter.includeDomains), normalise(exclude: filter.excludeDomains)) {
        case (.unrepresentable, _), (_, .unrepresentable):
            return []
        case (.domains, .domains):
            // Both keys in one trigger is rejected by WebKit. Dropping the
            // excludes would widen the rule past what its author wrote.
            return []
        case (.domains(let d), .unconstrained): ifDomain = d
        case (.unconstrained, .domains(let d)): unlessDomain = d
        case (.unconstrained, .unconstrained): break
        }

        let types = filter.resourceTypes.isEmpty
            ? nil
            : filter.resourceTypes.map(\.rawValue).sorted()

        func rule(_ urlFilter: String) -> ContentRule {
            ContentRule(
                trigger: .init(
                    urlFilter: urlFilter,
                    urlFilterIsCaseSensitive: filter.matchCase ? true : nil,
                    resourceType: types,
                    loadType: filter.loadType.map { [$0.rawValue] },
                    ifDomain: ifDomain,
                    unlessDomain: unlessDomain
                ),
                action: .init(
                    type: filter.isException ? "ignore-previous-rules" : "block",
                    selector: nil
                )
            )
        }

        var rules = [rule(primary)]
        if needsEndOfURLCompanion(filter),
           let companion = urlFilterRegex(for: filter, trailingSeparatorAsEnd: true) {
            rules.append(rule(companion))
        }
        return rules
    }

    private func needsEndOfURLCompanion(_ filter: NetworkFilter) -> Bool {
        guard separatorStyle == .compatible,
              !filter.isRawRegex, !filter.endAnchored,
              filter.pattern.hasSuffix("^")
        else { return false }
        let stem = filter.pattern.dropLast()
        let isPureHost = filter.domainAnchored
            && !stem.contains(where: { "/?*^:#".contains($0) })
        return !isPureHost
    }

    // MARK: Pattern → regex

    func urlFilterRegex(for filter: NetworkFilter, trailingSeparatorAsEnd: Bool = false) -> String? {
        if filter.isRawRegex {
            return Self.isWebKitCompatible(regex: filter.pattern) ? filter.pattern : nil
        }

        var regex = ""
        if filter.domainAnchored {
            // scheme, `://`, then an optional run of subdomain labels.
            regex += "^[a-z][a-z0-9+.-]*://([^/?#]+\\.)?"
        } else if filter.startAnchored {
            regex += "^"
        }

        let characters = Array(filter.pattern)
        for (index, character) in characters.enumerated() {
            let isLast = index == characters.count - 1
            switch character {
            case "*": regex += ".*"
            case "^":
                regex += (isLast && trailingSeparatorAsEnd) ? "$" : separatorStyle.pattern
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "$", "|", "\\":
                regex += "\\" + String(character)
            default:
                guard character.isASCII else { return nil }
                regex.append(character)
            }
        }

        if filter.endAnchored { regex += "$" }
        guard !regex.isEmpty, regex != ".*" || filter.isException else { return nil }
        return regex
    }

    /// Whether WebKit's content-rule compiler will accept `regex` *and* give it
    /// the meaning ICU would.
    ///
    /// Derived from `RegexDialectProbe`, not from documentation. Two kinds of
    /// construct are refused: ones WebKit rejects (which fail the whole list),
    /// and ones it accepts but cannot honour — a DFA has no backreferences, so an
    /// accepted `\\1` must silently mean something other than what was written.
    static func isWebKitCompatible(regex: String) -> Bool {
        guard !regex.isEmpty, regex.allSatisfy(\.isASCII) else { return false }

        let banned = ["(?", "{", "}", "|",
                      "\\d", "\\w", "\\s", "\\D", "\\W", "\\S", "\\b", "\\B",
                      "\\1", "\\2", "\\3", "\\4", "\\5", "\\6", "\\7", "\\8", "\\9"]
        guard banned.allSatisfy({ !regex.contains($0) }) else { return false }

        // `^` is only an anchor at index 0; elsewhere it must be `[^` negation.
        // `$` is only allowed as the final character. Escaped forms are literals.
        let chars = Array(regex)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "[" { inClass = true }
            else if c == "]" { inClass = false }
            else if c == "^" && i != 0 && !(inClass && chars[i - 1] == "[") { return false }
            else if c == "$" && !inClass && i != chars.count - 1 { return false }
            i += 1
        }
        return true
    }
}

// MARK: - Serialisation

extension CompiledRuleset {
    static func encode(_ rules: [ContentRule]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(rules)
        return String(decoding: data, as: UTF8.self)
    }
}
