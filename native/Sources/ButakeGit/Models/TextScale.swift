import SwiftUI
import Observation

/// Text size chosen with ⌘+ / ⌘− / ⌘0, applied to the whole window (lists, diff, editor) and remembered.
/// Views read `factor` while rendering their fonts, so a change re-renders exactly the text that uses it.
@MainActor @Observable final class TextScale {
    static let shared = TextScale()
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5]
    private(set) var factor: Double
    /// Mirror of `factor` readable from AppKit drawing code that is not bound to the main actor.
    nonisolated(unsafe) private static var current: Double = 1
    private init() {
        let stored = UserDefaults.standard.double(forKey: "textScale")
        factor = TextScale.steps.contains(stored) ? stored : 1.0
        TextScale.current = factor
    }
    private var index: Int { TextScale.steps.firstIndex(of: factor) ?? 2 }
    var canIncrease: Bool { index < TextScale.steps.count - 1 }
    var canDecrease: Bool { index > 0 }
    func increase() { set(TextScale.steps[min(index + 1, TextScale.steps.count - 1)]) }
    func decrease() { set(TextScale.steps[max(index - 1, 0)]) }
    func reset() { set(1.0) }
    private func set(_ value: Double) {
        guard value != factor else { return }
        factor = value; TextScale.current = value; UserDefaults.standard.set(value, forKey: "textScale")
    }
    /// A point size at the current scale (AppKit fonts and metrics that must grow with the text).
    nonisolated static func points(_ size: CGFloat) -> CGFloat { size * CGFloat(current) }
}

@MainActor extension Font {
    /// `Font.system(size:)` at the user's text size.
    static func ui(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: size * CGFloat(TextScale.shared.factor), weight: weight, design: design)
    }
    private static func scaled(_ font: Font, _ size: CGFloat, _ weight: Font.Weight? = nil) -> Font {
        TextScale.shared.factor == 1 ? font : .system(size: TextScale.points(size), weight: weight)
    }
    // The system text styles at the user's text size (macOS point sizes).
    static var uiBody: Font { scaled(.body, 13) }
    static var uiCallout: Font { scaled(.callout, 12) }
    static var uiCaption: Font { scaled(.caption, 10) }
    static var uiCaption2: Font { scaled(.caption2, 10, .medium) }
    static var uiHeadline: Font { scaled(.headline, 13, .bold) }
    static var uiTitle2: Font { scaled(.title2, 17) }
    static var uiTitle3: Font { scaled(.title3, 15) }
}
