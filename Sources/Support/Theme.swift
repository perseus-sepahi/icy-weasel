import SwiftUI
import AppKit

/// The Icy Weasel look: frosted glass over glacier blues.
///
/// Colours adapt to light and dark mode — light is frost on pale ice, dark is
/// glass over deep arctic water. Accents stay cold: glacier blue, aurora mint.
enum Theme {
    // MARK: Palette

    /// Glacier blue. Focus, security state, the shield.
    static let ice = Color(red: 0.49, green: 0.83, blue: 0.99)
    static let iceDeep = Color(red: 0.16, green: 0.52, blue: 0.78)
    /// Aurora mint: a second cold accent for gradients and glows.
    static let aurora = Color(red: 0.55, green: 0.95, blue: 0.90)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// Pale frost in light mode, deep arctic water in dark mode.
    static let backdropTop = adaptive(light: (0.93, 0.97, 1.00), dark: (0.05, 0.10, 0.17))
    static let backdropBottom = adaptive(light: (0.80, 0.91, 0.99), dark: (0.03, 0.06, 0.12))
    /// Tint laid over the see-through window chrome.
    static let chromeTint = adaptive(light: (0.66, 0.86, 1.00), dark: (0.09, 0.33, 0.56))
    /// Second chrome stop: a greener glacier so the glass has depth, not one flat blue.
    static let chromeTintLow = adaptive(light: (0.78, 0.95, 0.98), dark: (0.05, 0.22, 0.36))
    /// Text on glass: icy navy in light mode, frost white in dark mode.
    static let frostText = adaptive(light: (0.07, 0.20, 0.34), dark: (0.90, 0.96, 1.00))
    /// The bright edge of a pane of ice.
    static let rim = adaptive(light: (1.0, 1.0, 1.0), dark: (0.75, 0.90, 1.00))

    /// Accent that stays visible on both frost and glacier: deeper in light mode.
    static let iceAccent = adaptive(light: (0.13, 0.45, 0.72), dark: (0.49, 0.83, 0.99))
    static let iceGradient = LinearGradient(
        colors: [adaptive(light: (0.22, 0.62, 0.84), dark: (0.55, 0.95, 0.90)),
                 adaptive(light: (0.13, 0.45, 0.72), dark: (0.49, 0.83, 0.99)),
                 adaptive(light: (0.08, 0.30, 0.55), dark: (0.16, 0.52, 0.78))],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Highlight behind selected text on the glass. Text fields take their
    /// selection colour from the app's ice-blue accent, which is too pale under
    /// white text, so fields on glass are tinted with this deep glacier navy.
    /// (Setting the field editor's selectedTextAttributes has no effect: SwiftUI
    /// fields draw the highlight from their tint.)
    static let selectionBackground = NSColor(srgbRed: 0.04, green: 0.19, blue: 0.38, alpha: 1)
    static let selection = Color(nsColor: selectionBackground)

    // MARK: Metrics

    static let tabHeight: CGFloat = 34
    static let toolbarHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 10

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

// MARK: - Glass surfaces

extension View {
    /// A pane of ice. Real Liquid Glass on macOS 26+, frosted material with a
    /// bright rim and cold tint on older systems.
    ///
    /// `tint` colours the glass; `interactive` lets it respond to the pointer.
    @ViewBuilder
    func iceGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil, strength: Double = 1, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0.opacity(0.22 * strength)) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .background(shape.fill((tint ?? Theme.ice).opacity(0.10 * strength)))
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [Theme.rim.opacity(0.55), Theme.rim.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        }
    }

    /// Soft cold halo, for focus and the glowing snowflake.
    func iceGlow(_ color: Color = Theme.ice, radius: CGFloat = 10, active: Bool = true) -> some View {
        shadow(color: active ? color.opacity(0.55) : .clear, radius: radius)
    }
}

/// Groups neighbouring glass so panes blend at their edges (macOS 26+).
struct IceGlassGroup<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Backdrops

/// The glacier behind content pages: cold gradient, two soft auroras and a
/// faint frost sheen. Entirely static — no animation, no per-frame cost.
struct IceBackdrop: View {
    var privateTint = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backdropTop, Theme.backdropBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                Circle()
                    .fill((privateTint ? Color.purple : Theme.aurora).opacity(0.28))
                    .frame(width: w * 0.7, height: w * 0.7)
                    .blur(radius: 90)
                    .position(x: w * 0.18, y: h * 0.12)
                Circle()
                    .fill((privateTint ? Color.indigo : Theme.ice).opacity(0.30))
                    .frame(width: w * 0.6, height: w * 0.6)
                    .blur(radius: 100)
                    .position(x: w * 0.88, y: h * 0.95)
            }
            LinearGradient(colors: [Theme.rim.opacity(0.18), .clear, Theme.rim.opacity(0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .drawingGroup()   // rasterise once; the blurs are the only expensive part
        // Decoration only. Blurred circles look like light but hit-test as
        // filled shapes; with safe-area expansion they reached up over the tab
        // strip and swallowed clicks on the first tab. Never let it take input,
        // and keep it inside the page it decorates.
        .allowsHitTesting(false)
        .clipped()
    }
}

/// Behind-window blur for the chrome, so the tab strip and toolbar are real
/// glass over whatever is behind the window, tinted cold.
///
/// The window must stay OPAQUE. A non-opaque window with a clear background
/// makes the WindowServer pass clicks through every pixel that is transparent in
/// the app's own backing store — and glass and blur are composited by the
/// WindowServer, so to hit-testing they *are* transparent. That broke typing in
/// the address bar and the tab close buttons. Behind-window blending does not
/// need a non-opaque window (Finder's sidebar is the same material).
struct IceWindowChrome: NSViewRepresentable {
    var privateTint = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
