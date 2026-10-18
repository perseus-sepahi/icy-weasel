import XCTest
import WebKit
@testable import Icy_Weasel

/// Proves the properties fingerprint-defense.js claims, against real WebKit.
@MainActor
final class FingerprintDefenseTests: XCTestCase {

    // MARK: Harness

    private final class Page {
        let webView: WKWebView
        init(webView: WKWebView) { self.webView = webView }

        func eval(_ body: String) async throws -> Any? {
            try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        }

        func json(_ body: String) async throws -> [String: Any] {
            let raw = try await eval(body) as? String
            let data = try XCTUnwrap(raw?.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    /// `shielded` uses the production configuration builder, so the isolated
    /// world, message handler and script set are exactly what ships.
    private func page(shielded: Bool, origin: String = "https://fp.test/",
                      hardening: JavaScriptHardening = .hardened) async throws -> Page {
        let config: WKWebViewConfiguration
        if shielded {
            let policy = ResolvedSitePolicy(blockAds: false, httpsOnly: false, javaScript: true,
                                            resistFingerprinting: true, blockThirdPartyCookies: false,
                                            javaScriptHardening: hardening, isCustomised: false)
            config = WebViewFactory.makeConfiguration(
                profile: .makePrivate(), policy: policy, ruleLists: [], messageHandler: nil,
                topLevelURL: URL(string: origin))
        } else {
            config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            if #available(macOS 26.4, *), hardening == .hardened {
                config.defaultWebpagePreferences.securityRestrictionMode = .maximizeCompatibility
            }
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<html><head></head><body></body></html>", baseURL: URL(string: origin)!)
        try await waiter.wait()
        return Page(webView: webView)
    }

    private static let drawScene = #"""
        function scene(c) {
          const x = c.getContext('2d');
          const g = x.createLinearGradient(0, 0, c.width, c.height);
          g.addColorStop(0, '#1b6'); g.addColorStop(1, '#e32');
          x.fillStyle = g; x.fillRect(0, 0, c.width, c.height);
          x.font = '18px -apple-system, Helvetica'; x.fillStyle = '#fff';
          x.fillText('Icy Weasel \u{1F98A} fingerprint', 6, 40);
          x.beginPath(); x.arc(160, 90, 40, 0, Math.PI * 1.7); x.stroke();
          return c;
        }
        function fresh() { const c = document.createElement('canvas'); c.width = 240; c.height = 140; return scene(c); }
        function hashArray(a) { let h = 0; for (let i = 0; i < a.length; i++) h = (Math.imul(h, 31) + a[i]) | 0; return h; }
    """#

    // MARK: Undetectability

    private static let seamsProbe = #"""
        const targets = [
          [Node.prototype, 'appendChild'],
          [Node.prototype, 'insertBefore'],
          [Element.prototype, 'append'],
          [Element.prototype, 'innerHTML', 'set'],
          [HTMLIFrameElement.prototype, 'contentWindow', 'get'],
          [CanvasRenderingContext2D.prototype, 'getImageData'],
          [HTMLCanvasElement.prototype, 'toDataURL'],
          [HTMLCanvasElement.prototype, 'toBlob'],
          [WebGLRenderingContext.prototype, 'readPixels'],
          [AudioBuffer.prototype, 'getChannelData'],
          [AudioBuffer.prototype, 'copyFromChannel'],
          [AnalyserNode.prototype, 'getFloatFrequencyData'],
          [Function.prototype, 'toString'],
        ];
        const out = {};
        for (const [proto, key, part] of targets) {
          const d = Object.getOwnPropertyDescriptor(proto, key);
          const fn = d[part || 'value'];
          let caller;
          try { caller = 'ok:' + typeof fn.caller; } catch (e) { caller = 'throws:' + e.name; }
          let constructs;
          try { new fn(); constructs = 'ok'; } catch (e) { constructs = e.name; }
          out[key + (part ? ':' + part : '')] = {
            toString: Function.prototype.toString.call(fn),
            name: fn.name, length: fn.length, caller, constructs,
            ownNames: Object.getOwnPropertyNames(fn).sort().join(','),
            hasPrototype: 'prototype' in fn,
            writable: d.writable, enumerable: d.enumerable, configurable: d.configurable,
            enumeratedOnProto: Object.keys(proto).includes(key)
          };
        }
        // Wrong-arity and wrong-receiver errors must match native exactly.
        const errorOf = f => { try { f(); return 'no error'; } catch (e) { return e.name + ': ' + e.message; } };
        out.errors = {
          appendNoArgs: errorOf(() => document.body.appendChild()),
          appendBadThis: errorOf(() => Node.prototype.appendChild.call({}, document.createElement('b'))),
          insertOneArg: errorOf(() => document.body.insertBefore(document.createElement('b'))),
          innerHTMLBadThis: errorOf(() => Object.getOwnPropertyDescriptor(Element.prototype, 'innerHTML').set.call({}, 'x'))
        };
        out.windowOwnProps = Object.getOwnPropertyNames(window).sort().join(',');
        out.handlers = (window.webkit && window.webkit.messageHandlers)
          ? Object.getOwnPropertyNames(window.webkit.messageHandlers) : null;
        out.hardwareConcurrencyOwn = Object.prototype.hasOwnProperty.call(navigator, 'hardwareConcurrency');
        out.plugins = navigator.plugins.length;
        return JSON.stringify(out);
    """#

    func testPatchedFunctionsAreIndistinguishableFromNativeByCommonChecks() async throws {
        let stock = try await page(shielded: false, hardening: .standard).json(Self.seamsProbe)
        let shielded = try await page(shielded: true).json(Self.seamsProbe)

        for key in ["appendChild", "insertBefore", "append", "innerHTML:set", "contentWindow:get",
                    "getImageData", "toDataURL", "toBlob", "readPixels",
                    "getChannelData", "copyFromChannel", "getFloatFrequencyData", "toString"] {
            let a = try XCTUnwrap(stock[key] as? [String: Any], key)
            let b = try XCTUnwrap(shielded[key] as? [String: Any], key)
            XCTAssertEqual(NSDictionary(dictionary: a), NSDictionary(dictionary: b),
                           "\(key) differs from native: stock=\(a) shielded=\(b)")
        }
        XCTAssertEqual(NSDictionary(dictionary: try XCTUnwrap(stock["errors"] as? [String: Any])),
                       NSDictionary(dictionary: try XCTUnwrap(shielded["errors"] as? [String: Any])),
                       "error names and messages must match native")
        XCTAssertEqual(stock["windowOwnProps"] as? String, shielded["windowOwnProps"] as? String,
                       "the shim must not add any global")
        XCTAssertTrue(shielded["handlers"] is NSNull,
                      "no message handler may be visible to the page world: \(shielded["handlers"] ?? "")")
        XCTAssertEqual(shielded["hardwareConcurrencyOwn"] as? Bool, false)
        XCTAssertEqual(stock["plugins"] as? Int, shielded["plugins"] as? Int,
                       "plugin list must stay the spec-standard one")
    }

    // MARK: Canvas

    func testCanvasNoiseIsConsistentNonDestructiveAndReal() async throws {
        let body = Self.drawScene + #"""
            const out = {};
            const c = fresh(), ctx = c.getContext('2d');
            const full1 = ctx.getImageData(0, 0, c.width, c.height).data;
            const full2 = ctx.getImageData(0, 0, c.width, c.height).data;
            out.repeatReadsEqual = hashArray(full1) === hashArray(full2);

            // Every pixel read alone must match the same pixel in the full read.
            let mismatches = 0;
            for (let y = 0; y < c.height; y += 7) for (let x = 0; x < c.width; x += 5) {
              const one = ctx.getImageData(x, y, 1, 1).data, i = (y * c.width + x) * 4;
              for (let k = 0; k < 4; k++) if (one[k] !== full1[i + k]) mismatches++;
            }
            out.regionMismatches = mismatches;

            out.dataURLStable = c.toDataURL() === c.toDataURL();

            // Five exports must not touch the visible canvas.
            const exported = fresh();
            for (let i = 0; i < 5; i++) exported.toDataURL();
            const untouched = fresh();
            out.exportIsNonDestructive =
              hashArray(exported.getContext('2d').getImageData(0, 0, 240, 140).data) ===
              hashArray(untouched.getContext('2d').getImageData(0, 0, 240, 140).data);

            // A transparent canvas must read back as all zeros.
            const blank = document.createElement('canvas'); blank.width = 50; blank.height = 50;
            out.blankStaysBlank = blank.getContext('2d').getImageData(0, 0, 50, 50).data.every(v => v === 0);

            // toDataURL on a context-less canvas must not claim it for 2D.
            const virgin = document.createElement('canvas');
            virgin.toDataURL();
            out.webglStillAvailable = !!virgin.getContext('webgl');

            out.hash = hashArray(full1);
            out.dataURL = c.toDataURL();
            return JSON.stringify(out);
        """#

        let shielded = try await page(shielded: true).json(body)
        let stock = try await page(shielded: false, hardening: .standard).json(body)

        XCTAssertEqual(shielded["repeatReadsEqual"] as? Bool, true, "averaging repeated reads must not work")
        XCTAssertEqual(shielded["regionMismatches"] as? Int, 0, "region reads must agree with full reads")
        XCTAssertEqual(shielded["dataURLStable"] as? Bool, true)
        XCTAssertEqual(shielded["exportIsNonDestructive"] as? Bool, true, "toDataURL must never degrade the canvas")
        XCTAssertEqual(shielded["blankStaysBlank"] as? Bool, true, "noise on a blank canvas is itself a tell")
        XCTAssertEqual(shielded["webglStillAvailable"] as? Bool, true)

        XCTAssertNotEqual(shielded["hash"] as? Int, stock["hash"] as? Int, "noise must actually change readback")
        XCTAssertNotEqual(shielded["dataURL"] as? String, stock["dataURL"] as? String, "and the exported image")
        XCTAssertEqual(stock["regionMismatches"] as? Int, 0, "control: stock WebKit is self-consistent too")
    }

    func testCanvasFingerprintDiffersAcrossSitesButNotWithinOne() async throws {
        let body = Self.drawScene + "return String(hashArray(fresh().getContext('2d').getImageData(0,0,240,140).data));"
        let siteA1 = try await page(shielded: true, origin: "https://news.example/").eval(body) as? String
        let siteA2 = try await page(shielded: true, origin: "https://news.example/").eval(body) as? String
        let siteB = try await page(shielded: true, origin: "https://shop.example/").eval(body) as? String

        XCTAssertEqual(siteA1, siteA2, "same site, same session: stable, so the site cannot detect noise")
        XCTAssertNotEqual(siteA1, siteB, "different sites see different values, so they cannot link you")
    }

    // MARK: Audio

    /// The classic OfflineAudioContext fingerprint: triangle oscillator through
    /// a compressor, summing |samples| over 4500..5000.
    private static let audioFingerprint = #"""
        const ctx = new OfflineAudioContext(1, 44100, 44100);
        const osc = ctx.createOscillator(); osc.type = 'triangle'; osc.frequency.value = 10000;
        const comp = ctx.createDynamicsCompressor();
        comp.threshold.value = -50; comp.knee.value = 40; comp.ratio.value = 12;
        comp.attack.value = 0; comp.release.value = 0.25;
        osc.connect(comp); comp.connect(ctx.destination); osc.start(0);
        const buffer = await ctx.startRendering();
        const sum = d => { let s = 0; for (let i = 4500; i < 5000; i++) s += Math.abs(d[i]); return s; };
        const first = sum(buffer.getChannelData(0));
        const second = sum(buffer.getChannelData(0));
        const copied = new Float32Array(buffer.length); buffer.copyFromChannel(copied, 0);
        return JSON.stringify({ first, second, copied: sum(copied) });
    """#

    func testClassicAudioFingerprintIsChangedAndStable() async throws {
        let shielded = try await page(shielded: true).json(Self.audioFingerprint)
        let stock = try await page(shielded: false, hardening: .standard).json(Self.audioFingerprint)

        let s1 = try XCTUnwrap(shielded["first"] as? Double)
        let s2 = try XCTUnwrap(shielded["second"] as? Double)
        let sc = try XCTUnwrap(shielded["copied"] as? Double)
        let native = try XCTUnwrap(stock["first"] as? Double)

        XCTAssertEqual(s1, s2, "repeated getChannelData must not accumulate noise")
        XCTAssertEqual(s1, sc, "copyFromChannel must agree with getChannelData")
        XCTAssertNotEqual(s1, native, "the 4500..5000 window must actually be perturbed")
        XCTAssertLessThan(abs(s1 - native), 1e-3, "…by an inaudible amount")
    }

    // MARK: WebRTC

    func testWebRTCDoesNotExposeRawLocalAddresses() async throws {
        let surface = try await FingerprintSurfaceProbe.run(
            FingerprintSurfaceProbe.surfaceScript,
            userScripts: [try XCTUnwrap(ScriptInjector.fingerprintDefense(topLevelURL: URL(string: "https://probe.test/")))]
        )
        let rtc = try XCTUnwrap(surface["rtc"] as? [String: Any])
        XCTAssertNil(rtc["error"])
        XCTAssertEqual(rtc["rawIPInCandidates"] as? Bool, false, "host candidates must be mDNS names: \(rtc)")
        XCTAssertEqual(rtc["rawIPInSDP"] as? Bool, false)
    }

    // MARK: Child realms

    /// A page can borrow pristine prototypes from a same-origin child frame it
    /// creates itself. If our script is not present in that realm, the whole
    /// canvas defence is bypassed with three lines of code.
    private static let realmBypass = drawScene + #"""
        const read = (win) => {
          const c = fresh();
          const data = win.CanvasRenderingContext2D.prototype.getImageData.call(c.getContext('2d'), 0, 0, 240, 140).data;
          return hashArray(data);
        };
        const make = (setup) => new Promise(resolve => {
          const f = document.createElement('iframe');
          setup(f);
          document.body.appendChild(f);
          // Synchronous access right after insertion: the fastest a real script can be.
          let sync = null;
          try { sync = read(f.contentWindow); } catch (e) { sync = 'error:' + e; }
          setTimeout(() => {
            let later = null;
            try { later = read(f.contentWindow); } catch (e) { later = 'error:' + e; }
            resolve({ sync, later });
          }, 300);
        });
        const out = { top: read(window) };
        out.aboutBlank = await make(f => {});
        out.srcdoc = await make(f => { f.srcdoc = '<p>x</p>'; });
        out.blobURL = await make(f => {
          f.src = URL.createObjectURL(new Blob(['<p>x</p>'], { type: 'text/html' }));
        });
        out.innerHTML = await new Promise(resolve => {
          const host = document.createElement('div');
          document.body.appendChild(host);
          host.innerHTML = '<iframe srcdoc="<p>x</p>"></iframe>';
          try { resolve({ sync: read(window[window.length - 1]), later: null }); }
          catch (e) { resolve({ sync: 'error:' + e, later: null }); }
        });
        out.replaceChild = await new Promise(resolve => {
          const old = document.createElement('iframe');
          document.body.appendChild(old);
          const index = window.length - 1;
          const swap = document.createElement('iframe');
          swap.srcdoc = '<p>swap</p>';
          document.body.replaceChild(swap, old);
          try { resolve({ sync: read(window[index]), later: null }); }
          catch (e) { resolve({ sync: 'error:' + e, later: null }); }
        });
        out.nested = await new Promise(resolve => {
          const outer = document.createElement('iframe');
          document.body.appendChild(outer);
          const innerDoc = outer.contentWindow.document;
          const inner = innerDoc.createElement('iframe');
          inner.srcdoc = '<p>inner</p>';
          innerDoc.body ? innerDoc.body.appendChild(inner) : innerDoc.documentElement.appendChild(inner);
          try { resolve({ sync: read(outer.contentWindow[0]), later: null }); }
          catch (e) { resolve({ sync: 'error:' + e, later: null }); }
        });
        out.windowIndex = await new Promise(resolve => {
          const f = document.createElement('iframe');
          document.body.appendChild(f);
          try { resolve({ sync: read(window[window.length - 1]), later: null }); }
          catch (e) { resolve({ sync: 'error:' + e, later: null }); }
        });
        return JSON.stringify(out);
    """#

    func testChildFrameRealmsCannotBypassNoise() async throws {
        let shielded = try await page(shielded: true).json(Self.realmBypass)
        let stock = try await page(shielded: false, hardening: .standard).json(Self.realmBypass)
        print("\n=== REALM BYPASS ===\nshielded: \(shielded)\nstock: \(stock)\n")

        let stockTop = try XCTUnwrap(stock["top"] as? Int)
        XCTAssertNotEqual(shielded["top"] as? Int, stockTop, "precondition: top frame is noised")

        for vector in ["aboutBlank", "srcdoc", "blobURL", "windowIndex", "innerHTML", "replaceChild", "nested"] {
            let result = try XCTUnwrap(shielded[vector] as? [String: Any], vector)
            for timing in ["sync", "later"] {
                guard let value = result[timing], !(value is NSNull) else { continue }
                if let hash = value as? Int {
                    XCTAssertNotEqual(hash, stockTop, "\(vector) (\(timing)) returned pristine, un-noised pixels")
                }
            }
        }
    }

    /// Parser-inserted frames never pass through a JS insertion method; the
    /// next inline script must still see a patched realm.
    func testParserInsertedFrameIsPatchedBeforeNextInlineScript() async throws {
        let html = #"""
            <html><body>
            <iframe srcdoc="<p>parsed</p>"></iframe>
            <script>
              \#(Self.drawScene)
              try {
                const c = fresh();
                window.__parsed = hashArray(frames[0].CanvasRenderingContext2D.prototype.getImageData
                  .call(c.getContext('2d'), 0, 0, 240, 140).data);
                window.__top = hashArray(c.getContext('2d').getImageData(0, 0, 240, 140).data);
              } catch (e) { window.__parsed = 'error:' + e; }
            </script>
            </body></html>
            """#
        func load(shielded: Bool) async throws -> (Any?, Any?) {
            let page = try await page(shielded: shielded)
            let waiter = NavigationWaiter()
            page.webView.navigationDelegate = waiter
            page.webView.loadHTMLString(html, baseURL: URL(string: "https://fp.test/")!)
            try await waiter.wait()
            return (try await page.eval("return window.__parsed"), try await page.eval("return window.__top"))
        }
        let (shieldedParsed, shieldedTop) = try await load(shielded: true)
        let (stockParsed, _) = try await load(shielded: false)
        XCTAssertNotEqual(shieldedParsed as? Int, stockParsed as? Int,
                          "parser-inserted frame leaked pristine pixels: \(String(describing: shieldedParsed))")
        XCTAssertEqual(shieldedParsed as? Int, shieldedTop as? Int,
                       "child frame and top frame must agree, or the noise is detectable by comparison")
    }

    // MARK: Attacks on the shim itself

    /// Inherited Proxy traps: if a handler had Object.prototype in its chain,
    /// defining e.g. Object.prototype.getPrototypeOf would make the Proxy hand
    /// the page the native target.
    func testProxyHandlersCannotBeHijackedThroughObjectPrototype() async throws {
        let body = Self.drawScene + #"""
            const leaks = [];
            const traps = ['getPrototypeOf', 'get', 'has', 'ownKeys', 'getOwnPropertyDescriptor',
                           'construct', 'defineProperty', 'set', 'deleteProperty', 'isExtensible'];
            for (const t of traps) Object.prototype[t] = function (target) { leaks.push(t); return Reflect[t](...arguments); };
            const fn = CanvasRenderingContext2D.prototype.getImageData;
            try { Object.getPrototypeOf(fn); } catch (e) {}
            try { fn.name; 'x' in fn; Reflect.ownKeys(fn); Object.getOwnPropertyDescriptor(fn, 'name'); } catch (e) {}
            try { new fn(); } catch (e) {}
            try { Object.defineProperty(fn, 'x', { value: 1, configurable: true }); delete fn.x; Object.isExtensible(fn); } catch (e) {}
            for (const t of traps) delete Object.prototype[t];
            return JSON.stringify({ leaks });
        """#
        let result = try await page(shielded: true).json(body)
        XCTAssertEqual((result["leaks"] as? [String]) ?? ["?"], [], "a Proxy consulted Object.prototype for a trap")
    }

    /// Builtin spying: a page replacing WeakMap.prototype.get must not receive
    /// the shim's private map (which maps proxies back to pristine natives).
    func testReplacedBuiltinsDoNotReceiveShimInternals() async throws {
        let body = Self.drawScene + #"""
            const seen = [];
            const realGet = WeakMap.prototype.get, realHas = WeakSet.prototype.has, realImul = Math.imul;
            WeakMap.prototype.get = function (k) { seen.push('WeakMap.get'); return realGet.call(this, k); };
            WeakSet.prototype.has = function (k) { seen.push('WeakSet.has'); return realHas.call(this, k); };
            Math.imul = function (a, b) { seen.push('Math.imul'); return realImul(a, b); };
            CanvasRenderingContext2D.prototype.getImageData.toString();
            const c = fresh();
            c.getContext('2d').getImageData(0, 0, 240, 140);
            c.toDataURL();
            const f = document.createElement('iframe'); f.srcdoc = 'x'; document.body.appendChild(f); f.contentWindow;
            WeakMap.prototype.get = realGet; WeakSet.prototype.has = realHas; Math.imul = realImul;
            return JSON.stringify({ seen: [...new Set(seen)] });
        """#
        let result = try await page(shielded: true).json(body)
        XCTAssertEqual((result["seen"] as? [String]) ?? ["?"], [], "shim called a page-replaceable builtin at run time")
    }

    /// A page can count how often its argument's valueOf runs; native runs it once.
    func testArgumentCoercionHappensExactlyOnce() async throws {
        let body = Self.drawScene + #"""
            let calls = 0;
            const ctx = fresh().getContext('2d');
            ctx.getImageData({ valueOf() { calls++; return 0; } }, 0, 10, 10);
            return JSON.stringify({ calls });
        """#
        let stock = try await page(shielded: false, hardening: .standard).json(body)
        let shielded = try await page(shielded: true).json(body)
        XCTAssertEqual(shielded["calls"] as? Int, stock["calls"] as? Int)
    }

    // MARK: Partitioning & policy wiring

    func testPartitionSeedIsPerSiteNotPerOrigin() {
        let news = ScriptInjector.partitionSeed(forTopLevel: URL(string: "https://www.news.example/a"))
        let newsSub = ScriptInjector.partitionSeed(forTopLevel: URL(string: "https://live.news.example/b"))
        let shop = ScriptInjector.partitionSeed(forTopLevel: URL(string: "https://shop.example/"))
        XCTAssertEqual(news, newsSub, "one site, one partition")
        XCTAssertNotEqual(news, shop, "different sites must not share noise")
    }

    func testFingerprintScriptFollowsSitePolicy() {
        let controller = WKUserContentController()
        var policy = ResolvedSitePolicy(blockAds: true, httpsOnly: true, javaScript: true,
                                        resistFingerprinting: false, blockThirdPartyCookies: true, isCustomised: true)
        WebViewFactory.installUserScripts(into: controller, policy: policy, topLevelURL: URL(string: "https://a.example"))
        XCTAssertFalse(controller.userScripts.contains { $0.source.contains("fingerprinting defence") },
                       "toggle off must remove the shim")
        policy.resistFingerprinting = true
        WebViewFactory.installUserScripts(into: controller, policy: policy, topLevelURL: URL(string: "https://a.example"))
        XCTAssertEqual(controller.userScripts.filter { $0.source.contains("fingerprinting defence") }.count, 1,
                       "toggle on installs exactly one copy")
    }

    // MARK: Cost

    /// Separates the two costs the default configuration pays: the shim's DOM
    /// hooks and running without a JIT. Measured, not assumed.
    func testInsertionAndInterpreterCost() async throws {
        let body = #"""
            const root = document.createElement('div'); document.body.appendChild(root);
            const nodes = []; for (let i = 0; i < 1000; i++) nodes.push(document.createElement('span'));
            const dom = () => {
              const t0 = performance.now();
              for (let r = 0; r < 200; r++) { for (let i = 0; i < 1000; i++) root.appendChild(nodes[i]); root.textContent = ''; }
              return performance.now() - t0;
            };
            const compute = () => {
              const t0 = performance.now();
              let x = 0; for (let i = 0; i < 3e7; i++) x = (x + Math.imul(i, 2654435761)) | 0;
              return performance.now() - t0;
            };
            // A realistic shape: build a 2,000-row table cell by cell, then force
            // style and layout, as a framework's first render would.
            const table = () => {
              const t0 = performance.now();
              const t = document.createElement('table');
              for (let r = 0; r < 2000; r++) {
                const tr = document.createElement('tr');
                for (let c = 0; c < 5; c++) {
                  const td = document.createElement('td');
                  td.textContent = 'r' + r + 'c' + c;
                  tr.appendChild(td);
                }
                t.appendChild(tr);
              }
              document.body.appendChild(t);
              void t.offsetHeight;
              t.remove();
              return performance.now() - t0;
            };
            dom(); compute(); table();
            const out = { dom: Math.min(dom(), dom(), dom()), compute: Math.min(compute(), compute()),
                          table: Math.min(table(), table(), table()) };
            const f = document.createElement('iframe'); f.srcdoc = 'x'; document.body.appendChild(f);
            out.domWithFrame = Math.min(dom(), dom(), dom());
            return JSON.stringify(out);
        """#
        var results: [String: [String: Double]] = [:]
        for (label, shim, hardening) in [("JIT", false, JavaScriptHardening.standard),
                                         ("JIT + shim", true, .standard),
                                         ("no-JIT", false, .hardened),
                                         ("no-JIT + shim", true, .hardened)] {
            let r = try await page(shielded: shim, hardening: hardening).json(body)
            results[label] = r.compactMapValues { $0 as? Double }
        }
        func v(_ label: String, _ key: String) -> Double { max(results[label]?[key] ?? 0, 0.1) }
        var report = "\n=== COST MATRIX (min of runs, ms) ===\n"
        report += "  config           200k inserts  +1 iframe  10k-cell table+layout  30M int ops\n"
        for label in ["JIT", "JIT + shim", "no-JIT", "no-JIT + shim"] {
            report += String(format: "  %-15@ %12.1f %10.1f %22.1f %12.1f\n", label as NSString,
                             v(label, "dom"), v(label, "domWithFrame"), v(label, "table"), v(label, "compute"))
        }
        let shimMicro = v("JIT + shim", "dom") / v("JIT", "dom")
        let shimTable = v("JIT + shim", "table") / v("JIT", "table")
        let defaultTable = v("no-JIT + shim", "table") / v("JIT", "table")
        report += String(format: "  shim: %.2fx on raw inserts, %.2fx on table render | shipped default vs stock on table: %.2fx | no-JIT on compute: %.1fx\n",
                         shimMicro, shimTable, defaultTable, v("no-JIT", "compute") / v("JIT", "compute"))
        print(report)

        // The realistic workload is the one that has to stay cheap.
        XCTAssertLessThan(shimTable, 1.5, "the shim must not materially slow a real render")
    }
}
