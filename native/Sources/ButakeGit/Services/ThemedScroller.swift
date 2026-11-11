import AppKit

/// Scroll bars in the theme's colors. Themes with their own palette (Drácula) get a knob tinted with the accent
/// and no gray track; with system backgrounds the standard scroller is drawn untouched.
final class ThemedScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { self == ThemedScroller.self }
    private var themed: Bool { Brand.theme.surface != nil }
    private var vertical: Bool { bounds.height >= bounds.width }

    override func drawKnob() {
        guard themed else { super.drawKnob(); return }
        let knob = rect(for: .knob).insetBy(dx: vertical ? 3 : 2, dy: vertical ? 2 : 3)
        guard knob.width > 0, knob.height > 0 else { return }
        let radius = min(knob.width, knob.height) / 2
        Brand.theme.accent.ns.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius).fill()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard themed else { super.drawKnobSlot(in: slotRect, highlight: flag); return }
        // No track: the knob floats over the theme's own background instead of the system gray strip.
    }

    /// Every scroll view of the app (AppKit and the ones SwiftUI creates for lists and scroll views) gets themed
    /// scrollers: `tile()` runs whenever a scroll view lays out its scrollers, so later-created ones are covered.
    @MainActor static func install() {
        guard !installed,
              let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
              let replacement = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.butake_tile)) else { return }
        installed = true
        method_exchangeImplementations(original, replacement)
    }
    @MainActor private static var installed = false
}

extension NSScrollView {
    @objc fileprivate func butake_tile() {
        // Swapped with `tile()`: this call runs the original implementation.
        butake_tile()
        if let scroller = verticalScroller, type(of: scroller) == NSScroller.self { verticalScroller = ThemedScroller.replacing(scroller) }
        if let scroller = horizontalScroller, type(of: scroller) == NSScroller.self { horizontalScroller = ThemedScroller.replacing(scroller) }
    }
}

extension ThemedScroller {
    fileprivate static func replacing(_ scroller: NSScroller) -> ThemedScroller {
        let themed = ThemedScroller(frame: scroller.frame)
        themed.scrollerStyle = scroller.scrollerStyle; themed.controlSize = scroller.controlSize; themed.knobStyle = scroller.knobStyle
        return themed
    }
}
