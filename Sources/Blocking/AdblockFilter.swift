import Foundation

/// Resource categories WebKit's content-blocker engine understands.
///
/// This is deliberately the *stable* set that has existed since the content
/// blocker API shipped. Newer WebKit added `fetch`, `websocket`, `ping` and
/// `other`, but an unrecognised value fails the whole list compile, so we fold
/// those into `raw` the way every production converter does.
/// Resource categories WebKit's content-rule compiler accepts.
///
/// `raw` is WebKit's legacy umbrella for fetch, WebSocket, ping and other. The
/// precise members are used instead (TriggerDialectProbe confirms they compile):
/// mapping `$xmlhttprequest` to `raw` would also block WebSockets and beacons
/// the filter author never mentioned.
enum WebKitResourceType: String, CaseIterable, Sendable {
    case document
    case image
    case styleSheet = "style-sheet"
    case script
    case font
    case svgDocument = "svg-document"
    case media
    case popup
    case fetch
    case websocket
    case ping
    case other
}

/// Exceptions that apply to *pages*, not to requests.
///
/// `@@||bing.com^$generichide` means "on bing.com's own pages, skip generic
/// cosmetic filters". Read as a request-level exception it would instead
/// unblock every request *to* bing.com — including bat.bing.com, its tracker —
/// on every site. These are compiled as page-scoped triggers and positioned so
/// they cancel only the rule layers they are meant to (see ContentRuleCompiler).
enum PageScope: Int, Sendable {
    /// `$generichide` / `$ghide`: generic cosmetic filters off.
    case genericHide
    /// `$elemhide` / `$ehide`, and `$specifichide` / `$shide` (approximated:
    /// WebKit cannot cancel specific cosmetics without the generic ones too).
    case elementHide
    /// `$document` / `$doc`: every rule off for the page.
    case document
}

enum WebKitLoadType: String, Sendable {
    case firstParty = "first-party"
    case thirdParty = "third-party"
}

/// Why a source line did not become a rule. Kept so the UI can show an honest
/// "N of M rules compiled" figure instead of pretending everything converted.
enum FilterRejection: Error, Equatable, Sendable {
    case comment
    case empty
    case unsupportedOption(String)
    case unsupportedSyntax(String)
    case unsupportedSelector(String)
    case emptyPattern
}

// MARK: - Parsed representations

struct NetworkFilter: Equatable, Sendable {
    var pattern: String
    var isException: Bool
    var isRawRegex: Bool
    var domainAnchored: Bool      // leading ||
    var startAnchored: Bool       // leading |
    var endAnchored: Bool         // trailing |
    var resourceTypes: Set<WebKitResourceType>
    var loadType: WebKitLoadType?
    var includeDomains: [String]
    var excludeDomains: [String]
    var matchCase: Bool
    /// Set for exceptions that apply to pages rather than to requests.
    var pageScope: PageScope?
}

struct CosmeticFilter: Equatable, Sendable {
    var selector: String
    var includeDomains: [String]
    var excludeDomains: [String]
    /// `#@#` — unhides a selector on specific domains.
    var isException: Bool
}

enum ParsedFilter: Equatable, Sendable {
    case network(NetworkFilter)
    case cosmetic(CosmeticFilter)
}

// MARK: - Parser

/// Parses Adblock Plus / uBlock Origin filter syntax into a normalised form.
///
/// Anything this parser cannot represent *faithfully* is rejected rather than
/// approximated. An approximated ad-block rule is a silent false negative on a
/// tracker; an approximated exception rule is a silent false positive that
/// breaks a site. Both are worse than a dropped rule we can count and report.
enum AdblockParser {

    static func parse(line rawLine: String) -> Result<ParsedFilter, FilterRejection> {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return .failure(.empty) }
        // `!` and `[Adblock Plus 2.0]` headers are comments. A bare `#` is too,
        // but `##` / `#@#` are cosmetic filters, so check length before assuming.
        if line.hasPrefix("!") || line.hasPrefix("[") { return .failure(.comment) }
        if line.hasPrefix("#") && !line.hasPrefix("##") && !line.hasPrefix("#@#") {
            return .failure(.comment)
        }

        // AdGuard's extended syntax: script injection (`#%#`), extended CSS
        // (`#?#`), CSS injection (`#$#`) and HTML filtering (`$$`), plus their
        // exception forms. None contain `##`, so without this check they fall
        // through to the *network* parser and become nonsense URL rules.
        if let marker = Self.extendedSyntaxMarkers.first(where: { line.contains($0) }) {
            return .failure(.unsupportedSyntax("adguard\(marker)"))
        }

        if let range = cosmeticSeparatorRange(in: line) {
            return parseCosmetic(line: line, separator: range)
        }
        return parseNetwork(line: line)
    }

    private static let extendedSyntaxMarkers = ["#@%#", "#%#", "#@$#", "#$#", "#@?#", "#?#", "$@$", "$$"]

    // MARK: Cosmetic

    /// Finds the `##` / `#@#` separator, rejecting uBO's procedural variants
    /// (`#?#`, `#$#`, `#%#`) which have no WebKit equivalent.
    private static func cosmeticSeparatorRange(in line: String) -> (Range<String.Index>, Bool)? {
        for marker in ["#@#", "##"] {
            if let r = line.range(of: marker) {
                // Guard against `||a.com/foo##bar` style false hits: the marker
                // must not sit inside what is clearly a URL path.
                if line[line.startIndex..<r.lowerBound].contains("$") { return nil }
                return (r, marker == "#@#")
            }
        }
        return nil
    }

    private static func parseCosmetic(
        line: String,
        separator: (Range<String.Index>, Bool)
    ) -> Result<ParsedFilter, FilterRejection> {
        let (range, isException) = separator
        let domainPart = String(line[line.startIndex..<range.lowerBound])
        let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)

        guard !selector.isEmpty else { return .failure(.emptyPattern) }
        if let bad = unsupportedSelectorToken(in: selector) {
            return .failure(.unsupportedSelector(bad))
        }

        var include: [String] = []
        var exclude: [String] = []
        for token in domainPart.split(separator: ",") where !token.isEmpty {
            let t = token.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("~") {
                exclude.append(String(t.dropFirst()))
            } else {
                include.append(t)
            }
        }

        return .success(.cosmetic(CosmeticFilter(
            selector: selector,
            includeDomains: include,
            excludeDomains: exclude,
            isException: isException
        )))
    }

    /// uBO procedural selectors and scriptlet injections. `:has()` is *allowed*
    /// through — modern WebKit implements it natively as real CSS.
    private static let proceduralTokens = [
        "+js(", ":has-text(", ":xpath(", ":style(", ":matches-css",
        ":min-text-length(", ":upward(", ":watch-attr(", ":remove(",
        ":nth-ancestor(", ":others(", ":matches-path(", ":matches-attr(",
        ":matches-prop(", ":contains("
    ]

    private static func unsupportedSelectorToken(in selector: String) -> String? {
        proceduralTokens.first { selector.contains($0) }
    }

    // MARK: Network

    /// Options that change behaviour in ways `block` / `ignore-previous-rules`
    /// cannot express. Carrying the rule anyway would misrepresent it.
    private static let unsupportedOptions: Set<String> = [
        "csp", "redirect", "redirect-rule", "removeparam", "removeheader",
        "replace", "cookie", "stealth", "empty", "mp4", "genericblock",
        "inline-script", "inline-font", "jsinject", "urlblock", "content",
        "extension", "app", "network", "badfilter", "webrtc", "denyallow",
        "to", "method", "header", "permissions", "hls", "jsonprune"
    ]

    private static func resourceType(for option: String) -> WebKitResourceType? {
        switch option {
        case "script":                      return .script
        case "image":                       return .image
        case "stylesheet", "css":           return .styleSheet
        case "font":                        return .font
        case "media":                       return .media
        case "popup":                       return .popup
        case "document", "doc":             return .document
        // WebKit has no iframe category; `document` is the closest and is what
        // every mainstream converter uses for `$subdocument`.
        case "subdocument", "frame":        return .document
        case "xmlhttprequest", "xhr":       return .fetch
        case "websocket":                   return .websocket
        case "ping", "beacon":              return .ping
        case "other", "object", "object-subrequest": return .other
        default:                            return nil
        }
    }

    private static func parseNetwork(line: String) -> Result<ParsedFilter, FilterRejection> {
        var body = line
        var isException = false
        if body.hasPrefix("@@") {
            isException = true
            body = String(body.dropFirst(2))
        }

        // Split options off the tail. A `$` inside a `/regex/` literal is not an
        // option separator, so find the last `$` that sits outside the regex.
        var optionString = ""
        if let dollar = lastOptionSeparatorIndex(in: body) {
            optionString = String(body[body.index(after: dollar)...])
            body = String(body[body.startIndex..<dollar])
        }

        var resourceTypes: Set<WebKitResourceType> = []
        var excludedTypes: Set<WebKitResourceType> = []
        var loadType: WebKitLoadType?
        var include: [String] = []
        var exclude: [String] = []
        var matchCase = false
        var pageScope: PageScope?
        func widen(to scope: PageScope) {
            if (pageScope?.rawValue ?? -1) < scope.rawValue { pageScope = scope }
        }

        for rawOption in optionString.split(separator: ",") where !rawOption.isEmpty {
            var opt = rawOption.trimmingCharacters(in: .whitespaces).lowercased()
            var negated = false
            if opt.hasPrefix("~") { negated = true; opt = String(opt.dropFirst()) }

            if opt.hasPrefix("domain=") {
                for d in opt.dropFirst("domain=".count).split(separator: "|") {
                    let name = d.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { continue }
                    if name.hasPrefix("~") { exclude.append(String(name.dropFirst())) }
                    else { include.append(name) }
                }
                continue
            }

            switch opt {
            case "third-party", "3p":
                loadType = negated ? .firstParty : .thirdParty
            case "first-party", "1p":
                loadType = negated ? .thirdParty : .firstParty
            case "match-case":
                matchCase = true
            case "important", "all":
                // Priority hint / "every type" — both are safe to ignore because
                // an empty resource-type set already means "all types".
                continue
            case "generichide", "ghide":
                guard isException, !negated else { return .failure(.unsupportedOption(opt)) }
                widen(to: .genericHide)
            case "elemhide", "ehide", "specifichide", "shide":
                guard isException, !negated else { return .failure(.unsupportedOption(opt)) }
                widen(to: .elementHide)
            case "document", "doc":
                // Same word, opposite meanings. On an exception it allowlists the
                // page; on a block rule (uBO's badware lists) it blocks navigating
                // to the page. Conflating them turns a malware block into an
                // allowlist for the malware.
                if isException {
                    guard !negated else { return .failure(.unsupportedOption(opt)) }
                    widen(to: .document)
                } else if negated {
                    excludedTypes.insert(.document)
                } else {
                    resourceTypes.insert(.document)
                }
            default:
                if unsupportedOptions.contains(opt) {
                    return .failure(.unsupportedOption(opt))
                }
                guard let type = resourceType(for: opt) else {
                    return .failure(.unsupportedOption(opt))
                }
                if negated { excludedTypes.insert(type) } else { resourceTypes.insert(type) }
            }
        }

        // `~script,~image` means "everything except these".
        if resourceTypes.isEmpty && !excludedTypes.isEmpty {
            resourceTypes = Set(WebKitResourceType.allCases).subtracting(excludedTypes)
            // `popup` is never implied by a negation; it would over-block.
            resourceTypes.remove(.popup)
        }

        // Anchors
        var isRawRegex = false
        var domainAnchored = false
        var startAnchored = false
        var endAnchored = false

        if body.count > 1 && body.hasPrefix("/") && body.hasSuffix("/") {
            isRawRegex = true
            body = String(body.dropFirst().dropLast())
        } else {
            if body.hasPrefix("||") {
                domainAnchored = true
                body = String(body.dropFirst(2))
            } else if body.hasPrefix("|") {
                startAnchored = true
                body = String(body.dropFirst())
            }
            if body.hasSuffix("|") {
                endAnchored = true
                body = String(body.dropLast())
            }
        }

        guard !body.isEmpty else { return .failure(.emptyPattern) }

        return .success(.network(NetworkFilter(
            pattern: body,
            isException: isException,
            isRawRegex: isRawRegex,
            domainAnchored: domainAnchored,
            startAnchored: startAnchored,
            endAnchored: endAnchored,
            resourceTypes: resourceTypes,
            loadType: loadType,
            includeDomains: include.map { $0.lowercased() },
            excludeDomains: exclude.map { $0.lowercased() },
            matchCase: matchCase,
            // A page scope makes resource types meaningless for the exception.
            pageScope: pageScope
        )))
    }

    /// The `$` that introduces options, ignoring any `$` inside a regex literal.
    private static func lastOptionSeparatorIndex(in body: String) -> String.Index? {
        if body.hasPrefix("/"), let closing = body.lastIndex(of: "/"), closing != body.startIndex {
            // Options may only follow the closing slash of a regex literal.
            let tail = body[body.index(after: closing)...]
            guard let dollar = tail.firstIndex(of: "$") else { return nil }
            return dollar
        }
        return body.lastIndex(of: "$")
    }
}
