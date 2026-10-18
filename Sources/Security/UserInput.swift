import AppKit

/// Remembers the last real click or key press the app received.
///
/// WebKit reports a script's synthetic `element.click()` (even one carrying
/// `metaKey: true`) as a `.linkActivated` navigation with the Command modifier.
/// Trusting that let any page open unlimited background tabs, skipping the
/// pop-up blocker. Events that come through AppKit's event queue can only come
/// from the user, so actions that need a real gesture check this first.
@MainActor
enum UserInput {
    struct Activation: Equatable {
        let time: TimeInterval
        let windowNumber: Int
        let modifiers: NSEvent.ModifierFlags
    }

    private(set) static var last: Activation?
    private static var monitor: Any?

    /// Called once at launch.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .otherMouseUp, .keyDown]) { event in
            record(event)
            return event
        }
    }

    static func record(_ event: NSEvent) {
        if event.type == .keyDown {
            // Return or Space activates a focused link or button.
            guard [36, 76, 49].contains(event.keyCode) else { return }
        }
        last = Activation(time: event.timestamp, windowNumber: event.windowNumber,
                          modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    /// The real activation behind a navigation, if the user clicked or pressed
    /// a key in `window` within the last second.
    static func recentActivation(in window: NSWindow?, within seconds: TimeInterval = 1.0,
                                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Activation? {
        guard let last, let window, last.windowNumber == window.windowNumber,
              now - last.time >= 0, now - last.time <= seconds else { return nil }
        return last
    }
}
