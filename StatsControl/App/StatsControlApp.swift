import AppKit
import ServiceManagement
import SwiftUI

@main
struct StatsControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Runtime.headless)) {
            // New identity after every close: settings page and list start fresh again.
            MenuView()
                .id(model.menuGeneration)
                .environment(model)
        } label: {
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Launch modes without a menu bar item: developer snapshots and the self-test run invisibly.
enum Runtime {
    static let arguments = CommandLine.arguments
    static let isSnapshot = arguments.contains("--snapshot")
    static let isSelfTest = arguments.contains("--selftest")
    static let headless = isSnapshot || isSelfTest
    /// Invented, fixed content for promotional images; only together with `--snapshot`, never reads or stores user data.
    static let isDemo = isSnapshot && arguments.contains("--demo")

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let base = Runtime.value(after: "--snapshot") {
            MainActor.assumeIsolated { Snapshot.render(to: base) }
            NSApp.terminate(nil)
        } else if let path = Runtime.value(after: "--selftest") {
            MainActor.assumeIsolated { SelfTest.run(writingTo: path) }
        } else {
            LoginItem.enableOnFirstLaunch()
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { Runtime.isDemo || SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Stats Control: login item failed: \(error)")
        }
    }

    /// Register as a login item automatically on the very first launch.
    static func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// Developer helper: renders the menu content invisibly to PNG files (light and dark) without showing windows.
/// Usage: StatsControl --snapshot /path/base [--tab cpu|gpu|memory] [--settings] [--armed] [--compact cpu|gpu|memory] [--demo]
///                     [--timeline dir]
///   →  base-light.png, base-dark.png, base-symbol.png (menu bar, double resolution);
///      with --compact additionally base-animation.png (transitions of the compact bar frame by frame, fixed values);
///      with --timeline the frames of the README's compact mode animation in dir (see `timeline(to:)`)
enum Snapshot {
    @MainActor
    static func render(to base: String) {
        let model = AppModel.shared
        model.prepareSnapshot(armed: Runtime.arguments.contains("--armed"))
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)!
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.appearance = appearance
            let host = NSHostingView(rootView: MenuView().environment(model))
            host.appearance = appearance
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let size = host.fittingSize
            effect.frame = NSRect(origin: .zero, size: size)
            host.frame = effect.bounds
            effect.addSubview(host)
            let window = NSWindow(contentRect: effect.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = effect
            effect.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { continue }
            effect.cacheDisplay(in: effect.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
        }
        DemoTargets.write(to: "\(base)-targets.json")
        writeBar([model.menuBarImage], to: "\(base)-symbol.png")
        if let dir = Runtime.value(after: "--timeline") { timeline(to: dir) }
        guard Runtime.value(after: "--compact") != nil else { return }
        // One transition per row: all → RAM only (high), swap CPU ↔ RAM, CPU → CPU + RAM.
        let values = [23, 8, 51]
        let steps: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        let rows: [(MenuBarLabel.Layout, MenuBarLabel.Layout)] = [
            (.full, .showing([false, false, true])),
            (.showing([true, false, false]), .showing([false, false, true])),
            (.showing([true, false, false]), .showing([true, false, true])),
        ]
        writeBar(rows.flatMap { from, to in steps.map { MenuBarLabel.image(values, layout: from.blended(to: to, $0)) } },
                 to: "\(base)-animation.png", perRow: steps.count)
    }

    /// Writes the compact mode animation for the README to `dir`: one symbol strip per frame plus frames.json, which
    /// scripts/compose.swift turns into menu bar frames. The values are scripted, but threshold, hysteresis, column choice
    /// and the 0.5 s easing are the app's own, so the animation shows exactly what the menu bar does.
    @MainActor
    static func timeline(to dir: String) {
        struct Frame: Encodable { let symbol: String; let duration: Double; let caption: String; let cursor: [CGFloat]? }
        struct Step { let seconds: Double; let values: [Int]; let caption: String; var cursor: CGPoint? = nil; var hover = false }
        let fps = 25.0, threshold = 50, preferred = Metric.cpu
        // Cursor positions: points left of the symbol strip's right edge and below the screen's top edge.
        let outside = CGPoint(x: 70, y: 76), onItem = CGPoint(x: 8 + MenuBarLabel.width / 6, y: 20)
        let script = [
            Step(seconds: 1, values: [12, 6, 41], caption: "Compact mode: only CPU in the menu bar"),
            Step(seconds: 1, values: [14, 7, 42], caption: "Compact mode: only CPU in the menu bar"),
            Step(seconds: 1, values: [11, 6, 44], caption: "Compact mode: only CPU in the menu bar"),
            Step(seconds: 1.4, values: [13, 6, 58], caption: "Memory crosses the threshold and takes its place"),
            Step(seconds: 1, values: [12, 7, 61], caption: "Memory crosses the threshold and takes its place"),
            Step(seconds: 1.4, values: [63, 8, 60], caption: "Every high value stays visible"),
            Step(seconds: 1, values: [66, 7, 59], caption: "Every high value stays visible"),
            Step(seconds: 1.6, values: [18, 6, 43], caption: "All values back to normal: back to CPU only"),
            Step(seconds: 0.6, values: [16, 6, 42], caption: "Hover to see all three values", cursor: onItem),
            Step(seconds: 2, values: [15, 7, 42], caption: "Hover to see all three values", cursor: onItem, hover: true),
            Step(seconds: 1.2, values: [14, 6, 41], caption: "", cursor: outside),
        ]
        var frames: [Frame] = [], icons: [NSImage] = []
        var hot = Set<Metric>(), cursor: CGPoint? = nil
        var layout = MenuBarLabel.Layout.showing(AppModel.compactColumns(hot: hot, preferred: preferred))
        func add(_ values: [Int], _ shown: MenuBarLabel.Layout, _ seconds: Double, _ caption: String, _ at: CGPoint?) {
            icons.append(MenuBarLabel.image(values, layout: shown))
            frames.append(Frame(symbol: String(format: "frame-%03d-symbol.png", frames.count), duration: (seconds * 100).rounded() / 100,
                                caption: caption, cursor: at.map { [$0.x.rounded(), $0.y.rounded()] }))
        }
        for step in script {
            hot = AppModel.hotMetrics(step.values, previous: hot, threshold: threshold)
            let target = step.hover ? .full : MenuBarLabel.Layout.showing(AppModel.compactColumns(hot: hot, preferred: preferred))
            // Frame by frame while the cursor moves or the columns slide, then one still frame for the rest of the step.
            let moving = step.cursor != cursor && !step.hover, sliding = target != layout
            let count = moving ? Int(0.4 * fps) : sliding ? Int(0.5 * fps) : 0
            for i in 0..<count {
                let t = Double(i + 1) / Double(count), eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                let at = moving ? step.cursor.map { to in
                    let from = cursor ?? outside
                    return CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
                } : cursor
                add(step.values, sliding ? layout.blended(to: target, eased) : layout, 1 / fps, step.caption, at)
            }
            if moving { cursor = step.cursor }
            layout = target
            add(step.values, layout, step.seconds - Double(count) / fps, step.caption, cursor)
            if step.cursor == outside { cursor = nil }
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (frame, icon) in zip(frames, icons) { writeBar([icon], to: "\(dir)/\(frame.symbol)") }
        try? JSONEncoder().encode(frames).write(to: URL(fileURLWithPath: "\(dir)/frames.json"))
    }

    /// Menu bar images on a light and a dark strip, double resolution, `perRow` images per row.
    @MainActor
    private static func writeBar(_ icons: [NSImage], to path: String, perRow: Int = 1) {
        let cell = NSSize(width: MenuBarLabel.width + 16, height: 24)
        let lines = (icons.count + perRow - 1) / perRow
        let size = NSSize(width: cell.width * CGFloat(perRow), height: cell.height * CGFloat(lines))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size.width, height: size.height * 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, background, ink) in [(1, NSColor.white, NSColor.black), (0, NSColor(white: 0.16, alpha: 1), NSColor.white)] {
            let frame = NSRect(x: 0, y: CGFloat(row) * size.height, width: size.width, height: size.height)
            background.setFill()
            frame.fill()
            for (i, icon) in icons.enumerated() {
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceIn)
                    return true
                }
                // Right-aligned as in the bar: items grow to the left.
                let x = cell.width * CGFloat(i % perRow + 1) - 8 - icon.size.width
                let y = frame.maxY - cell.height * CGFloat(i / perRow + 1) + (cell.height - icon.size.height) / 2
                tinted.draw(in: NSRect(x: x, y: y, width: icon.size.width, height: icon.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
