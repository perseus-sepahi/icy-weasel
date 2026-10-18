import XCTest
import AppKit
@testable import Icy_Weasel

/// Regression: selecting the address bar text showed white text on a pale
/// ice-blue highlight, which was unreadable on the glass. Fields on glass are
/// tinted with `Theme.selection`; this pins that colour to a readable one.
final class SelectionStyleTests: XCTestCase {

    /// WCAG relative luminance of an sRGB colour.
    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testSelectedTextIsReadable() {
        // WCAG AAA for normal text is 7:1.
        XCTAssertGreaterThanOrEqual(contrast(.white, Theme.selectionBackground), 7)
    }
}
