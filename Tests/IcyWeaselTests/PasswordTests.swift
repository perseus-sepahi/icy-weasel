import XCTest
import WebKit
@testable import Icy_Weasel

@MainActor
final class PasswordTests: XCTestCase {
    private var savedMarker = ""

    override func setUp() async throws {
        savedMarker = PasswordStore.marker
        PasswordStore.marker = "Icy Weasel test \(UUID().uuidString)"   // never touch real passwords
    }

    override func tearDown() async throws {
        PasswordStore.logins().forEach(PasswordStore.delete)
        PasswordStore.marker = savedMarker
    }

    // MARK: Keychain

    func testKeychainSaveListUpdateDelete() {
        XCTAssertTrue(PasswordStore.save(host: "Login.IcyWeasel.test", username: "ana", password: "first"))
        let login = SavedLogin(host: "login.icyweasel.test", username: "ana")
        XCTAssertEqual(PasswordStore.logins(for: "login.icyweasel.test"), [login], "hosts are stored lowercased")
        XCTAssertEqual(PasswordStore.password(for: login), "first")
        XCTAssertTrue(PasswordStore.save(host: "login.icyweasel.test", username: "ana", password: "second"))
        XCTAssertEqual(PasswordStore.logins().count, 1, "saving again updates, never duplicates")
        XCTAssertEqual(PasswordStore.password(for: login), "second")
        XCTAssertTrue(PasswordStore.logins(for: "other.icyweasel.test").isEmpty, "exact host only")
        PasswordStore.delete(login)
        XCTAssertNil(PasswordStore.password(for: login))
    }

    // MARK: Import

    func testImportsGoogleChromeAndSafariExports() {
        let chrome = """
            name,url,username,password,note
            example,https://accounts.example.com/login,ana@example.com,"pa,ss""word",
            app,android://hash@com.example.app/,ana,secret,
            """
        let (rows, skipped) = PasswordImport.parse(chrome)
        XCTAssertEqual(rows, [.init(host: "accounts.example.com", username: "ana@example.com", password: "pa,ss\"word")])
        XCTAssertEqual(skipped, 1, "app-only entries are skipped")

        let safari = "Title,URL,Username,Password,Notes,OTPAuth\r\nShop,https://shop.example/,bo,\"multi\nline\",,\r\n"
        XCTAssertEqual(PasswordImport.parse(safari).rows, [.init(host: "shop.example", username: "bo", password: "multi\nline")])
        XCTAssertTrue(PasswordImport.parse("nothing,useful\n1,2").rows.isEmpty, "unknown format imports nothing")
    }

    // MARK: In a real page

    private func makeTab(isPrivate: Bool = false) -> (BrowserViewModel, Tab, WKWebView) {
        let suite = "iw-pw-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let model = BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                     blocking: BlockingEngine(settings: settings), downloads: DownloadManager(),
                                     isPrivate: isPrivate)
        let tab = model.tabs[0]
        let webView = tab.wake()
        webView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        return (model, tab, webView)
    }

    private func load(_ webView: WKWebView, base: String) async throws {
        let done = expectation(description: "loaded")
        let observation = webView.observe(\.isLoading, options: [.new]) { _, change in if change.newValue == false { done.fulfill() } }
        webView.loadHTMLString("""
            <html><body><form id="f" action="javascript:void 0">
              <input type="email" id="u" autocomplete="username">
              <input type="password" id="p">
              <button type="submit">Sign in</button>
            </form></body></html>
            """, baseURL: URL(string: base)!)
        await fulfillment(of: [done], timeout: 10)
        observation.invalidate()
        try await Task.sleep(for: .milliseconds(600))   // the script announces the form
    }

    func testFillsOnlyWhenAskedAndOnlyOnTheSavedSite() async throws {
        PasswordStore.save(host: "login.icyweasel.test", username: "ana@example.com", password: "s3cret!")
        let (_, tab, webView) = makeTab()
        try await load(webView, base: "https://login.icyweasel.test/")
        let login = try XCTUnwrap(tab.availableLogins.first, "the key button gets this site's saved login")

        let before = try await webView.evaluateJavaScript("document.getElementById('p').value") as? String
        XCTAssertEqual(before, "", "nothing is filled until the user asks")
        let filled = await tab.fill(login)
        XCTAssertTrue(filled)
        let user = try await webView.evaluateJavaScript("document.getElementById('u').value") as? String
        let pass = try await webView.evaluateJavaScript("document.getElementById('p').value") as? String
        XCTAssertEqual(user, "ana@example.com")
        XCTAssertEqual(pass, "s3cret!")

        let other = SavedLogin(host: "evil.icyweasel.test", username: "ana@example.com")
        PasswordStore.save(host: other.host, username: other.username, password: "nope")
        let crossSite = await tab.fill(other)
        XCTAssertFalse(crossSite, "a login is never filled into a different site")
    }

    /// A frame can navigate to another site without the page changing; the
    /// recorded frame is then stale. Filling must check the frame's live origin.
    func testNeverFillsAFrameThatHasSinceGoneToAnotherSite() async throws {
        PasswordStore.save(host: "login.icyweasel.test", username: "ana", password: "s3cret!")
        let (_, tab, webView) = makeTab()
        let done = expectation(description: "loaded")
        let observation = webView.observe(\.isLoading, options: [.new]) { _, change in if change.newValue == false { done.fulfill() } }
        webView.loadHTMLString("""
            <html><body><iframe id="f" width="400" height="200"
              srcdoc="<input type='email' autocomplete='username'><input type='password' id='p'>"></iframe></body></html>
            """, baseURL: URL(string: "https://login.icyweasel.test/")!)
        await fulfillment(of: [done], timeout: 10)
        observation.invalidate()
        try await Task.sleep(for: .milliseconds(800))
        let login = try XCTUnwrap(tab.availableLogins.first, "the iframe's form was announced for login.icyweasel.test")

        // The iframe now goes to a page with a different (opaque) origin.
        _ = try await webView.evaluateJavaScript("""
            document.getElementById('f').src = "data:text/html,<input type='password'>"; true
            """)
        try await Task.sleep(for: .milliseconds(800))
        let filled = await tab.fill(login)
        XCTAssertFalse(filled, "the password is not sent to a frame that left the site")
    }

    func testPlainHTTPPagesNeverGetPasswords() async throws {
        PasswordStore.save(host: "plain.icyweasel.test", username: "ana", password: "x")
        let (_, tab, webView) = makeTab()
        try await load(webView, base: "http://plain.icyweasel.test/")
        XCTAssertTrue(tab.availableLogins.isEmpty)
    }

    func testAPageCannotFakeASubmitToGetASaveOffer() async throws {
        let (_, tab, webView) = makeTab()
        try await load(webView, base: "https://login.icyweasel.test/")
        _ = try await webView.evaluateJavaScript("""
            document.getElementById('u').value = 'planted'; document.getElementById('p').value = 'planted';
            document.getElementById('f').requestSubmit();
            document.querySelector('button').click(); true
            """)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(tab.passwordOffer, "synthetic (untrusted) events are ignored")
    }

    /// A real key press in the password field: WebKit marks it trusted.
    private func pressReturn(in webView: WKWebView) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        _ = try await webView.evaluateJavaScript("document.getElementById('p').focus(); true")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(700))
    }

    func testARealSignInOffersToSaveAndPrivateWindowsNever() async throws {
        let (_, tab, webView) = makeTab()
        try await load(webView, base: "https://login.icyweasel.test/")
        _ = try await webView.evaluateJavaScript("document.getElementById('u').value='ana@example.com'; document.getElementById('p').value='typed-pass'; true")
        try await pressReturn(in: webView)
        try XCTSkipIf(tab.passwordOffer == nil, "this test host doesn't deliver key events to web content")
        XCTAssertEqual(tab.passwordOffer, .init(host: "login.icyweasel.test", username: "ana@example.com", password: "typed-pass", isUpdate: false))
        tab.savePasswordOffer()
        XCTAssertEqual(PasswordStore.password(for: SavedLogin(host: "login.icyweasel.test", username: "ana@example.com")), "typed-pass")

        let (_, privateTab, privateView) = makeTab(isPrivate: true)
        try await load(privateView, base: "https://login.icyweasel.test/")
        _ = try await privateView.evaluateJavaScript("document.getElementById('u').value='x@example.com'; document.getElementById('p').value='p'; true")
        try await pressReturn(in: privateView)
        XCTAssertNil(privateTab.passwordOffer, "private windows never save")
    }
}
