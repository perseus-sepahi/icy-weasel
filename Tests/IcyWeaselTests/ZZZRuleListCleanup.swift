import XCTest
import WebKit

/// Runs last (XCTest orders classes alphabetically). Tests execute inside the
/// app's container, and a compiled full ruleset is tens of megabytes, so every
/// list a test created is removed here. Production lists (`iw-content-*`,
/// `iw-seed-*`, `iw-security-*`) are left alone.
@MainActor
final class ZZZRuleListCleanup: XCTestCase {
    func testRemoveListsCreatedByTests() async {
        let store = WKContentRuleListStore.default()!
        let ids: [String] = await withCheckedContinuation { c in
            store.getAvailableContentRuleListIdentifiers { c.resume(returning: $0 ?? []) }
        }
        let doomed = ids.filter { $0.hasPrefix("test-") || $0.hasPrefix("iw-test-") || $0.hasPrefix("iw-realtest-") || $0.hasPrefix("probe-") }
        for id in doomed {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: id) { _ in c.resume() }
            }
        }
        print("Removed \(doomed.count) test rule list(s)")
    }
}
