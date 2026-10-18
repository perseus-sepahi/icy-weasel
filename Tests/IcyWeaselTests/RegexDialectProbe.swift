import XCTest
import WebKit

/// Maps exactly which regex constructs WebKit's content-rule compiler accepts.
/// Kept as a permanent test: if a future WebKit changes its dialect, this is
/// where it shows up first, rather than as a silently empty rule list.
@MainActor
final class RegexDialectProbe: XCTestCase {

    private func accepts(_ pattern: String) async -> Bool {
        let escaped = pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"[{"trigger":{"url-filter":"\#(escaped)"},"action":{"type":"block"}}]"#
        return await withCheckedContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "probe-\(abs(pattern.hashValue))", encodedContentRuleList: json
            ) { list, _ in c.resume(returning: list != nil) }
        }
    }

    func testDialect() async {
        let cases: [(String, String)] = [
            ("literal", "^https://a\\.com/"),
            ("dot-star", "a.*b"),
            ("plus", "a+b"),
            ("optional", "ab?c"),
            ("char class", "[a-z0-9]"),
            ("negated class", "[^a-zA-Z0-9_.%-]"),
            ("group", "(ab)+"),
            ("optional group", "^https://([^/]+\\.)?a\\.com"),
            ("alternation", "(ab|cd)"),
            ("trailing $", "a\\.js$"),
            ("$ in alternation", "a([:/]|$)"),
            ("$ mid-pattern", "a$b"),
            ("^ mid-pattern", "a^b"),
            ("bounded {n}", "a{2}"),
            ("non-capturing", "(?:ab)"),
            ("lookahead", "a(?=b)"),
            ("\\d shorthand", "a\\d"),
            ("\\w shorthand", "a\\w"),
            ("\\b boundary", "\\ba"),
            ("lazy *?", "a.*?b"),
            ("backreference", "(a)\\1"),
            ("escaped slash", "a\\/b"),
            ("unicode literal", "caf\u{e9}"),
        ]
        var report = "\nWebKit url-filter dialect:\n"
        for (name, pattern) in cases {
            let ok = await accepts(pattern)
            report += "  \(ok ? "ACCEPT" : "reject")  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(pattern)\n"
        }
        print(report)
    }
}
