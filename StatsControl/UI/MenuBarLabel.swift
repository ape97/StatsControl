import AppKit
import OSLog

/// Menu bar: three narrow columns – a tiny label above the percentage value.
/// Template image so macOS tints it for light/dark and highlighting itself.
/// As compact as possible, font like the clock, little padding.
enum MenuBarLabel {
    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
    /// Font of the clock in the menu bar (matches its size and weight),
    /// with fixed-width digits so nothing jitters. Number and "%" in the same font.
    private static let valueFont: NSFont = {
        let clock = NSFont.menuBarFont(ofSize: 0)
        let digits = clock.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: digits, size: clock.pointSize) ?? clock
    }()
    private static let gap: CGFloat = 2
    private static let height: CGFloat = 22
    /// Baselines: number at the bottom, label above.
    private static let valueBaseline: CGFloat = 1.5
    private static let labelBaseline: CGFloat = 14.5

    /// Column width for "99%" – two digits fill the column exactly (no gap to the neighboring item);
    /// "100%" is rare and may overhang slightly.
    private static let columnWidth: CGFloat = ceil(valueText("99").size().width)

    static let width: CGFloat = columnWidth * 3 + gap * 2

    /// Position of the three columns (CPU, GPU, RAM) in the image: position and opacity. Compact bar: hidden columns
    /// sit half under the seam to the visible neighbor, so they slide into or out of it when cross-fading.
    struct Layout: Equatable {
        var width: CGFloat
        var x: [CGFloat]
        var alpha: [CGFloat]

        static let full = showing([true, true, true])

        static func showing(_ visible: [Bool]) -> Layout {
            var x: [CGFloat] = [], alpha: [CGFloat] = []
            var edge: CGFloat = 0
            for shown in visible {
                if shown {
                    x.append(edge)
                    edge += columnWidth + gap
                } else {
                    x.append(edge - (columnWidth + gap) / 2)
                }
                alpha.append(shown ? 1 : 0)
            }
            return Layout(width: max(edge - gap, columnWidth), x: x, alpha: alpha)
        }

        /// Intermediate animation state, t = 0…1. Rounded to half points (= device pixels on Retina)
        /// so CoreGraphics does not cache glyphs for arbitrary intermediate positions. Receding columns are
        /// invisible after 60 % of the way, arriving ones appear only afterwards – so the digits barely overlap while sliding in.
        func blended(to target: Layout, _ t: CGFloat) -> Layout {
            func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
            func half(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
            let fade = { (a: CGFloat, b: CGFloat) in mix(a, b, b < a ? min(t / 0.6, 1) : max((t - 0.4) / 0.6, 0)) }
            return Layout(width: half(mix(width, target.width, t)),
                          x: zip(x, target.x).map { half(mix($0, $1, t)) },
                          alpha: zip(alpha, target.alpha).map(fade))
        }
    }

    private static func valueText(_ digits: String, percent: Bool = true, alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: percent ? digits + "%" : digits,
                           attributes: [.font: valueFont, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
    }

    /// Values in the order CPU, GPU, RAM.
    static func image(_ values: [Int?], layout: Layout = .full) -> NSImage {
        let captions = ["CPU", "GPU", "RAM"]
        let image = NSImage(size: NSSize(width: layout.width, height: height), flipped: false) { _ in
            for i in captions.indices where layout.alpha[i] > 0.01 {
                let x = layout.x[i]
                let label: [NSAttributedString.Key: Any] = [.font: labelFont, .kern: 0.4,
                                                            .foregroundColor: NSColor.black.withAlphaComponent(layout.alpha[i])]
                let caption = NSAttributedString(string: captions[i], attributes: label)
                caption.draw(at: NSPoint(x: x + (columnWidth - caption.size().width) / 2, y: labelBaseline + labelFont.descender))
                let text = values[i].map { valueText("\(min(max($0, 0), 100))", alpha: layout.alpha[i]) }
                    ?? valueText("–", percent: false, alpha: layout.alpha[i])
                text.draw(at: NSPoint(x: x + (columnWidth - text.size().width) / 2, y: valueBaseline + valueFont.descender))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CPU \(values[0] ?? 0)%, GPU \(values[1] ?? 0)%, Memory \(values[2] ?? 0)%"
        return image
    }
}

/// MenuBarExtra gives the item a generous margin all around. Set the width here tightly to the image
/// so the values sit close to the neighboring items.
/// macOS gives every item 8 pt of margin per side itself (measured: length 95 → window 111) – as with all symbols.
/// Compact bar: length follows the image width; plus a one-time tracking area for mouse hover.
@MainActor
enum StatusItemFit {
    private static var hover: HoverTracker?

    static func apply(width target: CGFloat) {
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            guard window.responds(to: Selector(("statusItem"))),
                  let item = window.value(forKey: "statusItem") as? NSStatusItem else { continue }
            if item.length != target { item.length = target }
            if hover == nil, let button = item.button {
                let tracker = HoverTracker()
                button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                      owner: tracker, userInfo: nil))
                hover = tracker
            }
        }
    }
}

/// Mouse over the bar item: only enter/exit (no stream of mouse movements), reports to the model.
private final class HoverTracker: NSResponder {
    override func mouseEntered(with event: NSEvent) {
        Logger(subsystem: "io.github.ape97.statscontrol", category: "menu").notice("Mouse over the bar")
        MainActor.assumeIsolated { AppModel.shared.setHovering(true) }
    }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { AppModel.shared.setHovering(false) } }
}
