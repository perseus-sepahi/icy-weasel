import XCTest
import WebKit
@testable import Icy_Weasel

/// Records what *stock* WebKit exposes, with no shim installed. Every patch in
/// fingerprint-defense.js must justify itself against this baseline: patching a
/// value WebKit already normalises only adds a detectable difference.
@MainActor
final class FingerprintSurfaceProbe: XCTestCase {

    static let surfaceScript = """
    (async function () {
      const out = {};
      const d = (o, k) => Object.getOwnPropertyDescriptor(o, k);
      out.hardwareConcurrency = navigator.hardwareConcurrency;
      out.hcOwnOnInstance = Object.prototype.hasOwnProperty.call(navigator, 'hardwareConcurrency');
      out.hcGetterToString = (d(Navigator.prototype, 'hardwareConcurrency') || {}).get?.toString();
      out.deviceMemoryPresent = 'deviceMemory' in navigator;
      out.plugins = Array.from(navigator.plugins || []).map(p => p.name);
      out.pluginsIsPluginArray = typeof PluginArray !== 'undefined' && navigator.plugins instanceof PluginArray;
      out.webdriver = navigator.webdriver;
      out.getBatteryPresent = 'getBattery' in navigator;
      out.connectionPresent = 'connection' in navigator;
      out.getGamepadsPresent = 'getGamepads' in navigator;
      out.screen = [screen.width, screen.height, screen.colorDepth];
      out.getImageDataToString = CanvasRenderingContext2D.prototype.getImageData.toString();
      out.toDataURLToString = HTMLCanvasElement.prototype.toDataURL.toString();
      try {
        const gl = document.createElement('canvas').getContext('webgl');
        const ext = gl && gl.getExtension('WEBGL_debug_renderer_info');
        out.glVendor = gl && gl.getParameter(gl.VENDOR);
        out.glRenderer = gl && gl.getParameter(gl.RENDERER);
        out.glUnmaskedVendor = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : null;
        out.glUnmaskedRenderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : null;
        out.glDebugExtListed = gl ? gl.getSupportedExtensions().includes('WEBGL_debug_renderer_info') : null;
      } catch (e) { out.glError = String(e); }
      out.windowOwnProps = Object.getOwnPropertyNames(window).length;
      out.webkitHandlers = window.webkit && window.webkit.messageHandlers
        ? Object.getOwnPropertyNames(window.webkit.messageHandlers) : null;
      out.referrerMeta = !!document.querySelector('meta[name=referrer]');

      // WebRTC: gather local candidates and look for raw host IPs.
      out.rtc = await new Promise(resolve => {
        try {
          const pc = new RTCPeerConnection({ iceServers: [] });
          const cands = [];
          pc.onicecandidate = e => { if (e.candidate) cands.push(e.candidate.candidate); };
          pc.createDataChannel('probe');
          pc.createOffer().then(o => pc.setLocalDescription(o)).catch(err => resolve({ error: String(err) }));
          setTimeout(() => {
            const sdp = pc.localDescription ? pc.localDescription.sdp : '';
            const ipv4 = /(^|\\s)(\\d{1,3}\\.){3}\\d{1,3}\\s/;
            resolve({
              candidates: cands,
              hostCandidates: cands.filter(c => / typ host/.test(c)),
              rawIPInCandidates: cands.some(c => / typ host/.test(c) && ipv4.test(c)),
              mdnsCandidates: cands.filter(c => /\\.local /.test(c)).length,
              rawIPInSDP: /a=candidate.* typ host/.test(sdp) && ipv4.test(sdp.split('\\n').filter(l => l.startsWith('a=candidate')).join(' '))
            });
            pc.close();
          }, 2500);
        } catch (e) { resolve({ error: String(e) }); }
      });
      return JSON.stringify(out);
    })()
    """

    static func run(_ script: String, userScripts: [WKUserScript] = []) async throws -> [String: Any] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        userScripts.forEach(config.userContentController.addUserScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<html><head></head><body></body></html>", baseURL: URL(string: "https://probe.test/")!)
        try await waiter.wait()
        let raw = try await webView.callAsyncJavaScript(
            "return await \(script);", arguments: [:], in: nil, contentWorld: .page
        ) as? String
        let data = try XCTUnwrap(raw?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStockWebKitSurface() async throws {
        let surface = try await Self.run(Self.surfaceScript)
        let pretty = try JSONSerialization.data(withJSONObject: surface, options: [.prettyPrinted, .sortedKeys])
        print("\n=== STOCK WEBKIT FINGERPRINT SURFACE ===\n\(String(decoding: pretty, as: UTF8.self))\n")
    }
}
