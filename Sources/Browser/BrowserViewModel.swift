import Foundation
import AppKit
import Observation

/// State for one browser window.
@MainActor
@Observable
final class BrowserViewModel {
    let settings: BrowserSettings
    let policyStore: SitePolicyStore
    let blocking: BlockingEngine
    let downloads: DownloadManager
    let isPrivateWindow: Bool
    let profile: WebViewFactory.Profile
    let library: BrowsingLibrary
    let assistant: PageAssistant

    var suggestionIndex: Int?
    /// History/bookmark matches for what is being typed. Empty unless the user
    /// has actually edited the address bar.
    ///
    /// Several views and key handlers read this per keystroke, so the result is
    /// memoised on (text, library revision). Reading `library.revision` keeps
    /// SwiftUI observing the library even when the cache answers.
    var suggestions: [BrowsingLibrary.Suggestion] {
        guard isOmniboxFocused, omniboxText != (selectedTab?.url?.absoluteString ?? "") else { return [] }
        let revision = library.revision
        if let cached = suggestionCache, cached.text == omniboxText, cached.revision == revision {
            return cached.result
        }
        let result = library.suggestions(for: omniboxText)
        suggestionCache = (omniboxText, revision, result)
        return result
    }
    @ObservationIgnored private var suggestionCache: (text: String, revision: Int, result: [BrowsingLibrary.Suggestion])?

    func moveSuggestion(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { suggestionIndex = nil; return }
        let next = (suggestionIndex ?? (delta > 0 ? -1 : count)) + delta
        suggestionIndex = next < 0 || next >= count ? nil : next
    }

    /// Escape: throw away what was typed and show the page's address again,
    /// like every other browser.
    func cancelOmniboxEdit() {
        omniboxText = selectedTab?.url?.absoluteString ?? ""
        suggestionIndex = nil
        isOmniboxFocused = false
    }

    func open(_ suggestion: BrowsingLibrary.Suggestion) {
        selectedTab?.load(suggestion.url)
        omniboxText = suggestion.url.absoluteString
        isOmniboxFocused = false; suggestionIndex = nil
    }

    func toggleBookmark() {
        guard let tab = selectedTab, let url = tab.url else { return }
        library.toggleBookmark(url: url, title: tab.title)
    }

    var groups: [TabGroup] = []
    var showHistory = false
    var showAssistant = false
    private var closedTabs: [(url: URL, groupID: UUID?)] = []
    private var restoresSession = false

    var tabs: [Tab] = []
    var selectedTabID: Tab.ID?
    var omniboxText = ""
    var isOmniboxFocused = false
    var showSitePanel = false
    var showFindBar = false
    var findText = ""
    var showDownloads = false

    private var hibernationTimer: Timer?
    private var listObserver: NSObjectProtocol?

    init(settings: BrowserSettings, policyStore: SitePolicyStore, blocking: BlockingEngine,
         downloads: DownloadManager, isPrivate: Bool = false,
         library: BrowsingLibrary? = nil, restoreSession: Bool = false) {
        self.settings = settings
        let privateWindow = isPrivate || settings.ephemeralByDefault
        // Private windows get a throwaway in-memory library: nothing is recorded.
        self.library = privateWindow ? BrowsingLibrary(directory: nil) : (library ?? BrowsingLibrary(directory: nil))
        self.assistant = PageAssistant(settings: settings)
        self.restoresSession = restoreSession && !privateWindow
        // Same for per-site settings: a private window starts from the saved
        // ones but never writes the sites it visits to disk.
        self.policyStore = privateWindow ? policyStore.ephemeralCopy() : policyStore
        self.blocking = blocking
        self.downloads = downloads
        self.isPrivateWindow = isPrivate || settings.ephemeralByDefault
        self.profile = isPrivateWindow ? .makePrivate() : .standard
        if !(restoresSession && settings.restoreSession && restoreSavedSession()) {
            openTab(url: nil, inBackground: false, isPrivate: isPrivateWindow)
        }
        startHibernationScheduler()
        listObserver = NotificationCenter.default.addObserver(
            forName: BlockingEngine.listsDidChange, object: blocking, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tabs.filter { !$0.isHibernated }.forEach { $0.refreshRuleLists() }
            }
        }
    }

    var selectedTab: Tab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID }
    }

    // MARK: Tabs

    /// `inheritGroupFrom`: a tab opened *from* a grouped tab (a link, ⌘-click)
    /// joins that group, as in Chrome. A plain ⌘T does not.
    func openTab(url: URL?, inBackground: Bool, isPrivate: Bool? = nil, inheritGroupFrom opener: Tab? = nil) {
        let tab = Tab(url: url, isPrivate: isPrivate ?? isPrivateWindow, owner: self)
        tab.groupID = opener?.groupID
        if let anchor = opener ?? selectedTab, let index = tabs.firstIndex(where: { $0.id == anchor.id }) {
            var insertAt = index + 1
            // Never split a group: an ungrouped tab goes after the group's end.
            if tab.groupID == nil, let group = anchor.groupID {
                while insertAt < tabs.count, tabs[insertAt].groupID == group { insertAt += 1 }
            }
            tabs.insert(tab, at: insertAt)
        } else {
            tabs.append(tab)
        }
        if !inBackground { select(tab) }
        sessionChanged()
    }

    func duplicate(_ tab: Tab) {
        guard let url = tab.url else { return }
        openTab(url: url, inBackground: false, isPrivate: tab.isPrivate, inheritGroupFrom: tab)
    }

    func closeOthers(keeping tab: Tab) {
        for other in tabs where other.id != tab.id { close(other) }
    }

    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { return }
        openTab(url: last.url, inBackground: false)
        if let group = last.groupID, groups.contains(where: { $0.id == group }), let tab = selectedTab {
            add(tab, toGroup: group)
        }
    }

    // MARK: Tab groups

    func tabs(in group: TabGroup.ID) -> [Tab] { tabs.filter { $0.groupID == group } }
    func group(for tab: Tab) -> TabGroup? { groups.first { $0.id == tab.groupID } }

    @discardableResult
    func createGroup(with tab: Tab, name: String = "") -> TabGroup {
        let used = Set(groups.map(\.tint))
        let tint = TabGroup.Tint.allCases.first { !used.contains($0) } ?? .blue
        let group = TabGroup(name: name, tint: tint)
        groups.append(group)
        add(tab, toGroup: group.id)
        return group
    }

    func add(_ tab: Tab, toGroup groupID: TabGroup.ID) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.groupID = nil
        tabs.remove(at: from)
        // Land right after the group's last tab so the group stays contiguous.
        let destination = (tabs.lastIndex { $0.groupID == groupID }).map { $0 + 1 } ?? min(from, tabs.count)
        tab.groupID = groupID
        tabs.insert(tab, at: destination)
        pruneEmptyGroups()
        sessionChanged()
    }

    func removeFromGroup(_ tab: Tab) {
        guard let group = tab.groupID, let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: from)
        tab.groupID = nil
        let destination = (tabs.lastIndex { $0.groupID == group }).map { $0 + 1 } ?? min(from, tabs.count)
        tabs.insert(tab, at: destination)
        pruneEmptyGroups()
        sessionChanged()
    }

    func updateGroup(_ id: TabGroup.ID, _ mutate: (inout TabGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[index])
        // Collapsing the group that holds the current tab moves selection out of
        // it, or the visible page would belong to a tab you cannot see.
        if groups[index].isCollapsed, selectedTab?.groupID == id,
           let next = tabs.first(where: { $0.groupID != id }) { select(next) }
        sessionChanged()
    }

    func ungroup(_ id: TabGroup.ID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        pruneEmptyGroups(); sessionChanged()
    }

    func closeGroup(_ id: TabGroup.ID) {
        for tab in tabs(in: id) { close(tab) }
    }

    private func pruneEmptyGroups() {
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
    }

    // MARK: Session

    /// Restored tabs stay asleep until selected, so a 40-tab session costs
    /// nothing at launch beyond the one tab you are looking at.
    private func restoreSavedSession() -> Bool {
        guard let saved = library.loadSession(), saved.tabs.contains(where: { $0.url != nil }) else { return false }
        groups = saved.groups
        for item in saved.tabs {
            let tab = Tab(url: item.url, isPrivate: false, owner: self)
            tab.title = item.title
            tab.groupID = groups.contains { $0.id == item.groupID } ? item.groupID : nil
            tabs.append(tab)
        }
        pruneEmptyGroups()
        select(tabs[min(max(0, saved.selectedIndex), tabs.count - 1)])
        return true
    }

    func sessionChanged() {
        guard restoresSession else { return }
        let index = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        library.saveSession(SavedSession(
            tabs: tabs.map { .init(url: $0.url, title: $0.title, groupID: $0.groupID) },
            groups: groups, selectedIndex: index))
    }

    func select(_ tab: Tab) {
        selectedTabID = tab.id
        if let group = tab.groupID, let i = groups.firstIndex(where: { $0.id == group }) { groups[i].isCollapsed = false }
        tab.activate()
        omniboxText = tab.url?.absoluteString ?? ""
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasSelected = tab.id == selectedTabID
        if let url = tab.url, !tab.isPrivate {
            closedTabs.append((url, tab.groupID))
            if closedTabs.count > 25 { closedTabs.removeFirst() }
        }
        tab.discard()
        tabs.remove(at: index)
        pruneEmptyGroups()
        sessionChanged()

        if tabs.isEmpty {
            openTab(url: nil, inBackground: false)
            return
        }
        if wasSelected {
            select(tabs[min(index, tabs.count - 1)])
        }
    }

    func closeSelectedTab() {
        if let tab = selectedTab { close(tab) }
    }

    func selectTab(offset: Int) {
        guard let current = selectedTab,
              let index = tabs.firstIndex(where: { $0.id == current.id }),
              !tabs.isEmpty
        else { return }
        let next = (index + offset + tabs.count) % tabs.count
        select(tabs[next])
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        // Cmd-9 is "last tab" in every mainstream browser, not "ninth tab".
        let index = number == 9 ? tabs.count - 1 : min(number - 1, tabs.count - 1)
        select(tabs[index])
    }

    // MARK: Omnibox

    func submitOmnibox() {
        if let index = suggestionIndex, suggestions.indices.contains(index) { open(suggestions[index]); return }
        let input = omniboxText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let tab = selectedTab else { return }
        guard let destination = Self.resolve(input: input, searchEngine: settings.searchEngine,
                                             customTemplate: settings.customSearchTemplate) else { return }
        tab.load(destination)
        omniboxText = destination.absoluteString
        isOmniboxFocused = false
    }

    /// Decides whether omnibox text is a URL or a search.
    ///
    /// The ordering is deliberate. A typed `example.com` must go to HTTPS, and
    /// anything with a space is a search even if it contains a dot — otherwise
    /// "node.js tutorial" would try to resolve a hostname and leak the query to
    /// the DNS resolver instead of the search engine.
    nonisolated static func resolve(input: String, searchEngine: SearchEngine, customTemplate: String = "") -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file"].contains(scheme) {
            return url
        }

        let looksLikeHost = !text.contains(" ")
            && (text.contains(".") || text.hasPrefix("localhost"))
            && !text.hasSuffix(".")
            && text.first != "."

        if looksLikeHost {
            let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
            let scheme = isLocal ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(text)"), url.host != nil {
                return url
            }
        }
        return searchEngine.searchURL(for: text, customTemplate: customTemplate)
    }

    // MARK: Site policy

    func updateSitePolicy(_ mutate: (inout SiteOverride) -> Void) {
        guard let tab = selectedTab else { return }
        policyStore.update(url: tab.url, settings: settings, mutate)
        // Every tab on the same site must pick up the change, not just this one.
        let site = PublicSuffix.registrableDomain(of: tab.url)
        for other in tabs where PublicSuffix.registrableDomain(of: other.url) == site {
            other.applyPolicyChange()
        }
    }

    func resetSitePolicy() {
        guard let tab = selectedTab else { return }
        policyStore.clear(url: tab.url)
        let site = PublicSuffix.registrableDomain(of: tab.url)
        for other in tabs where PublicSuffix.registrableDomain(of: other.url) == site {
            other.applyPolicyChange()
        }
    }

    /// True when this site's overrides make it *weaker* than the global posture.
    /// An override that tightens protection is not a warning.
    var isSiteRelaxed: Bool {
        guard let url = selectedTab?.url, policyStore.override(for: url) != nil else { return false }
        let site = policyStore.resolve(url: url, settings: settings)
        let strength: [JavaScriptHardening: Int] = [.standard: 0, .hardened: 1, .lockdown: 2]
        return (settings.blockAds && !site.blockAds)
            || (settings.httpsOnly && !site.httpsOnly)
            || (settings.resistFingerprinting && !site.resistFingerprinting)
            || (settings.blockThirdPartyCookies && !site.blockThirdPartyCookies)
            || strength[site.javaScriptHardening]! < strength[settings.javaScriptHardening]!
    }

    func reapplyGlobalPolicy() {
        for tab in tabs { tab.applyPolicyChange() }
    }

    // MARK: Zoom

    func zoom(by step: Double) {
        guard let webView = selectedTab?.webView else { return }
        webView.pageZoom = min(3, max(0.5, (webView.pageZoom + step).rounded(toPlaces: 2)))
    }

    func resetZoom() { selectedTab?.webView?.pageZoom = 1 }

    // MARK: History

    func recordVisit(tab: Tab) {
        // The address bar follows the page in every window, private or not.
        if tab.id == selectedTabID, !isOmniboxFocused {
            omniboxText = tab.url?.absoluteString ?? ""
        }
        guard !tab.isPrivate else { return }
        if let url = tab.url { library.recordVisit(url: url, title: tab.title) }
        sessionChanged()
    }

    // MARK: Hibernation

    private func startHibernationScheduler() {
        hibernationTimer?.invalidate()
        hibernationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hibernateIdleTabs() }
        }
    }

    /// The Mac is short of memory: put every background tab to sleep now,
    /// whatever its idle time, except ones playing media or using the camera.
    func relieveMemoryPressure() {
        guard settings.hibernateTabs else { return }
        for tab in tabs where tab.id != selectedTabID && !tab.isHibernated {
            tab.hibernateIfQuiet()
        }
    }

    func hibernateIdleTabs() {
        guard settings.hibernateTabs else { return }
        let threshold = TimeInterval(max(1, settings.hibernateAfterMinutes) * 60)
        let now = Date()
        for tab in tabs where tab.id != selectedTabID && !tab.isHibernated {
            if now.timeIntervalSince(tab.lastActive) > threshold {
                tab.hibernateIfQuiet()
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
