#if DEBUG || BUTAKE_QA
import AppKit
import QuartzCore

/// QA-only: scrolls the largest scroll view of the key window frame by frame, like a trackpad flick,
/// and reports frame pacing. Main-thread stalls show up as late display-link callbacks.
@MainActor final class ScrollBenchmark: NSObject {
    private var link: CADisplayLink?
    private weak var scroll: NSScrollView?
    private var last: CFTimeInterval = 0
    private var deltas: [Double] = []
    private var expected: Double = 1.0 / 60
    private var direction: CGFloat = 1
    private var remaining = 0
    private var speed: CGFloat = 36
    private var label = ""
    private var completion: (() -> Void)?
    private var stalls: [Double] = []

    func run(label: String, frames: Int = 480, pointsPerFrame: CGFloat = 36, completion: @escaping () -> Void) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let content = window.contentView,
              // The visible list under the middle of the detail area (hidden panes stay mounted but don't hit-test).
              let target = (content.hitTest(NSPoint(x: content.bounds.width * 0.42, y: content.bounds.height * 0.5))?.enclosingScrollView)
                ?? ScrollBenchmark.scrollViews(in: content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
            NSLog("BUTAKE_QA scroll label=%@ error=no-scroll-view", label); completion(); return
        }
        self.label = label; scroll = target; stalls = []; remaining = frames; speed = pointsPerFrame; deltas = []; last = 0; direction = 1; self.completion = completion
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        expected = link.targetTimestamp - link.timestamp
        if last > 0 { deltas.append(link.timestamp - last) }
        if last > 0, link.timestamp - last > 0.025 { NSLog("BUTAKE_QA stall ms=%.0f", (link.timestamp - last) * 1000) }
        last = link.timestamp
        guard remaining > 0 else { finish(); return }
        remaining -= 1
        if link.timestamp - last > 0, let previous = deltas.last, previous > expected * 1.5 { stalls.append(previous) }
        guard speed > 0, let scroll, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        var y = clip.bounds.origin.y + speed * direction
        if y >= maxY { y = maxY; direction = -1 } else if y <= 0 { y = 0; direction = 1 }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private func finish() {
        link?.invalidate(); link = nil
        let sorted = deltas.sorted()
        let average = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
        let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        let hitches = deltas.filter { $0 > expected * 1.5 }.count
        let hitchTime = deltas.filter { $0 > expected * 1.5 }.reduce(0) { $0 + ($1 - expected) }
        let duration = deltas.reduce(0, +)
        NSLog("BUTAKE_QA scroll label=%@ frames=%d refresh=%.1fHz avg=%.2fms p95=%.2fms max=%.2fms hitches=%d hitchRatio=%.1fms/s doc=%.0fpt",
              label, deltas.count, 1 / max(expected, 0.001), average * 1000, p95 * 1000, (sorted.last ?? 0) * 1000, hitches,
              duration > 0 ? hitchTime * 1000 / duration : 0, scroll?.documentView?.frame.height ?? 0)
        if !stalls.isEmpty { NSLog("BUTAKE_QA stalls label=%@ ms=%@", label, stalls.map { String(format: "%.0f", $0 * 1000) }.joined(separator: ",")) }
        completion?(); completion = nil
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scroll = view as? NSScrollView, scroll.documentView != nil { result.append(scroll) }
        for child in view.subviews { result += scrollViews(in: child) }
        return result
    }
}
#endif
