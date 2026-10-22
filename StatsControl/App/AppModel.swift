import AppKit
import OSLog
import SwiftUI

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu.fill"
        case .gpu: "cube.fill"
        case .memory: "memorychip.fill"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .purple
        case .memory: .green
        }
    }
}

/// Measures the totals (menu bar) at a fixed interval; the process list every 2 s while open, every 30 s while closed.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    /// Measurement interval in seconds (2 s is enough for the display and saves energy).
    static let interval: TimeInterval = 2
    /// History in the tiles: 60 values = 2 minutes.
    static let historyLength = 60
    /// At most this many rows per list.
    static let maxRows = 50
    /// Refresh the process list only every 30 s while the menu is closed (one measurement costs a few milliseconds).
    static let backgroundInterval: TimeInterval = 30

    private(set) var cpu: Double = 0
    private(set) var gpu: Double?
    private(set) var memoryUsed: UInt64 = 0
    private(set) var history: [Metric: [Double]] = [:]
    /// nil = currently being measured (right after opening).
    private(set) var entries: [ProcessEntry]?
    /// Note on a row, e.g. when macOS refuses to quit a process.
    private(set) var notices: [String: String] = [:]
    /// Row whose quit button is waiting for confirmation.
    private(set) var armedID: String?
    var tab: Metric {
        didSet { if !Runtime.headless { UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab") } }
    }
    private(set) var menuBarImage: NSImage

    /// Compact bar (Settings): only `compactMetric` until a value reaches the threshold; mouse-over shows all three.
    var compactBar: Bool {
        didSet { if !Runtime.headless { UserDefaults.standard.set(compactBar, forKey: "compactBar") }; updateMenuBarImage(force: true) }
    }
    var compactMetric: Metric {
        didSet { if !Runtime.headless { UserDefaults.standard.set(compactMetric.rawValue, forKey: "compactMetric") }; updateMenuBarImage(force: true) }
    }
    /// From this value (in %) another column is added; configurable in Settings.
    static let thresholds = stride(from: 10, through: 90, by: 5)
    var compactThreshold: Int {
        didSet { if !Runtime.headless { UserDefaults.standard.set(compactThreshold, forKey: "compactThreshold") }; updateMenuBarImage(force: true) }
    }

    /// Incremented as soon as the menu window is closed (resets the settings page and the list).
    private(set) var menuGeneration = 0
    private(set) var isMenuOpen = false

    /// Measurements in the background. The UI receives them only while the menu is open (`publish`): otherwise SwiftUI
    /// re-evaluates the invisible menu window on every tick – that was the largest idle cost.
    @ObservationIgnored private var live = Live()
    @ObservationIgnored private(set) var stats = SystemStats()
    @ObservationIgnored let tracker = ProcessTracker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sampling = false
    @ObservationIgnored private var lastSample = Date.distantPast
    @ObservationIgnored private var labelValues: [Int?] = []
    @ObservationIgnored private var hot: Set<Metric> = []
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var barLayout = MenuBarLabel.Layout.full
    @ObservationIgnored private var barTarget = MenuBarLabel.Layout.full
    @ObservationIgnored private var barAnimation: Timer?
    @ObservationIgnored private var disarm: DispatchWorkItem?
    @ObservationIgnored private var closeChecks: Set<ObjectIdentifier> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "io.github.ape97.statscontrol.sampler", qos: .utility)

    private init() {
        let saved = Runtime.headless ? nil : UserDefaults.standard.string(forKey: "selectedTab")
        tab = Runtime.value(after: "--tab").flatMap(Metric.init(rawValue:)) ?? saved.flatMap(Metric.init(rawValue:)) ?? .cpu
        let compact = Runtime.value(after: "--compact").flatMap(Metric.init(rawValue:))
        let defaults = UserDefaults.standard
        compactBar = compact != nil || (!Runtime.headless && defaults.bool(forKey: "compactBar"))
        compactMetric = compact ?? (Runtime.headless ? nil : defaults.string(forKey: "compactMetric").flatMap(Metric.init(rawValue:))) ?? .cpu
        let threshold = Runtime.headless ? 0 : defaults.integer(forKey: "compactThreshold")
        compactThreshold = Self.thresholds.contains(threshold) ? threshold : 50
        menuBarImage = MenuBarLabel.image([nil, nil, nil])
        _ = stats.cpuLoad()
        if !Runtime.headless {
            observeMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { AppModel.shared.tick() } }
            let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.tick() } }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    // MARK: Measuring

    func tick() {
        live.cpu = stats.cpuLoad()
        live.gpu = GPU.load()
        live.memoryUsed = stats.memoryUsed()
        let shares: [Metric: Double] = [.cpu: live.cpu, .gpu: live.gpu ?? 0, .memory: live.memoryShare(of: stats.memoryTotal)]
        for metric in Metric.allCases {
            var values = live.history[metric] ?? []
            values.append(shares[metric] ?? 0)
            if values.count > Self.historyLength { values.removeFirst(values.count - Self.historyLength) }
            live.history[metric] = values
        }
        updateMenuBarImage()
        publishIfVisible()
        // Open: every 2 s. Closed: rarely in the background so the list is there immediately on opening.
        if isMenuOpen || live.entries == nil || Date().timeIntervalSince(lastSample) >= Self.backgroundInterval { sampleProcesses() }
    }

    /// Hand background values to the UI – only if the menu is open (or without a menu bar item: snapshot, self-test).
    private func publishIfVisible() {
        guard isMenuOpen || Runtime.headless else { return }
        cpu = live.cpu
        gpu = live.gpu
        memoryUsed = live.memoryUsed
        history = live.history
        if let list = live.entries { entries = list }
    }

    var memoryTotal: UInt64 { Runtime.isDemo ? Demo.memoryTotal : stats.memoryTotal }
    var cpuCores: Int { Runtime.isDemo ? Demo.cpuCores : stats.cpuCores }
    var gpuCores: Int? { Runtime.isDemo ? Demo.gpuCores : stats.gpuCores }
    var memoryShare: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }

    func value(_ metric: Metric) -> Double? {
        switch metric {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memoryShare
        }
    }

    /// Redraw only when a displayed number or the column selection changes.
    private func updateMenuBarImage(force: Bool = false) {
        let values = [live.cpu, live.gpu, live.memoryShare(of: memoryTotal)].map { $0.map { Int(($0 * 100).rounded()) } }
        hot = Self.hotMetrics(values, previous: hot, threshold: compactThreshold)
        let target = MenuBarLabel.Layout.showing(compactBar && !hovering && !isMenuOpen
            ? Self.compactColumns(hot: hot, preferred: compactMetric) : [true, true, true])
        if target != barTarget {
            barTarget = target
            labelValues = values
            animateBar()
            return
        }
        guard force || values != labelValues else { return }
        labelValues = values
        if barAnimation == nil { drawBar(barLayout) }
    }

    /// From the threshold on, a value counts as high (inclusive: 50 at threshold 50 counts); it falls back only 5 points below
    /// so values at the threshold do not flip back and forth on every tick.
    static func hotMetrics(_ values: [Int?], previous: Set<Metric>, threshold: Int) -> Set<Metric> {
        Set(Metric.allCases.enumerated().compactMap { i, metric in
            let value = values[i] ?? 0
            return value >= threshold || (previous.contains(metric) && value > threshold - 5) ? metric : nil
        })
    }

    /// Visible columns (CPU, GPU, RAM): all high values in their fixed place, otherwise only the selected one.
    static func compactColumns(hot: Set<Metric>, preferred: Metric) -> [Bool] {
        Metric.allCases.map { hot.isEmpty ? $0 == preferred : hot.contains($0) }
    }

    private func drawBar(_ layout: MenuBarLabel.Layout) {
        barLayout = layout
        menuBarImage = MenuBarLabel.image(labelValues, layout: layout)
        guard !Runtime.headless else { return }
        StatusItemFit.apply(width: layout.width)
        // SwiftUI picks up the new image only on the next pass and may reset the length in the process.
        DispatchQueue.main.async { MainActor.assumeIsolated { StatusItemFit.apply(width: layout.width) } }
    }

    /// Columns slide into each other over 0.5 s, identical in both directions, easing in and out (60 frames/s).
    /// The timer runs only during the transition.
    /// Syncing with the neighboring items is not possible: macOS springs the frame itself in another process
    /// (≈ 0.45 s, starts delayed), and when collapsing the window is narrow immediately (tried, discarded).
    private func animateBar() {
        barAnimation?.invalidate()
        let start = barLayout, target = barTarget, begin = Date()
        let duration: TimeInterval = Runtime.headless ? 0 : 0.5
        guard duration > 0, start != target else { barAnimation = nil; drawBar(target); return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                let t = min(Date().timeIntervalSince(begin) / duration, 1)
                let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                if t >= 1 { model.barAnimation?.invalidate(); model.barAnimation = nil }
                model.drawBar(t >= 1 ? target : start.blended(to: target, eased))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        barAnimation = timer
    }

    func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        updateMenuBarImage()
    }

    func sampleProcesses() {
        guard !sampling else { return }
        sampling = true
        lastSample = Date()
        queue.async {
            let raw = ProcessSampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppModel.shared.receive(raw) }
            }
        }
    }

    private func receive(_ raw: RawSample) {
        sampling = false
        if let list = tracker.update(with: raw, cpuCores: stats.cpuCores) { live.entries = list }
        publishIfVisible()
    }

    /// Measure synchronously (snapshot, self-test).
    func sampleProcessesNow() {
        if let list = tracker.update(with: ProcessSampler.sample(), cpuCores: stats.cpuCores) { live.entries = list }
        publishIfVisible()
    }

    /// Rows for a list: descending by usage. CPU/GPU without idle processes.
    func rows(_ metric: Metric) -> [ProcessEntry] {
        guard let entries else { return [] }
        let active = metric == .memory ? entries : entries.filter { $0.value(metric) >= 0.0005 }
        return Array(active.sorted { ($0.value(metric), $1.name) > ($1.value(metric), $0.name) }.prefix(Self.maxRows))
    }

    var entriesByID: [String: ProcessEntry] {
        Dictionary((entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Actions

    func select(_ metric: Metric) {
        tab = metric
        armedID = nil
    }

    /// First click on "Quit": the button turns red and waits 3 s for the second click.
    func arm(_ id: String?) {
        disarm?.cancel()
        armedID = id
        guard id != nil else { return }
        let work = DispatchWorkItem { MainActor.assumeIsolated { withAnimation(.snappy(duration: 0.2)) { AppModel.shared.armedID = nil } } }
        disarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func forceQuit(_ entry: ProcessEntry) {
        arm(nil)
        finish(entry, ok: ProcessActions.forceQuit(entry))
    }

    func quit(_ entry: ProcessEntry) {
        arm(nil)
        finish(entry, ok: ProcessActions.quit(entry))
    }

    private func finish(_ entry: ProcessEntry, ok: Bool) {
        if ok {
            // Remove from the list immediately; the next measurement confirms it.
            if entry.app == nil || entry.app?.isTerminated == true {
                entries?.removeAll { $0.id == entry.id }
                live.entries?.removeAll { $0.id == entry.id }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { AppModel.shared.sampleProcesses() } }
        } else {
            notices[entry.id] = "Denied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { _ = AppModel.shared.notices.removeValue(forKey: entry.id) } }
        }
    }

    // MARK: Menu open / closed

    private func menuOpened() {
        guard !isMenuOpen else { return }
        isMenuOpen = true
        updateMenuBarImage()
        publishIfVisible()
        // The last measured list stays; immediately re-measure (average since the last background measurement).
        sampleProcesses()
    }

    private func menuClosed() {
        isMenuOpen = false
        arm(nil)
        notices = [:]
        menuGeneration += 1
        updateMenuBarImage()
    }

    /// Opened = menu window becomes key; closed = window no longer visible
    /// (mere focus loss through a context menu or tooltip does not count).
    private func observeMenu() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.menuOpened() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { AppModel.shared.awaitClose(window) }
        })
    }

    private func awaitClose(_ window: NSWindow) {
        guard closeChecks.insert(ObjectIdentifier(window)).inserted else { return }
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    guard let window, !window.isKeyWindow else {
                        if let window { model.closeChecks.remove(ObjectIdentifier(window)) }
                        return
                    }
                    if window.isVisible { return check() }
                    model.closeChecks.remove(ObjectIdentifier(window))
                    Logger(subsystem: "io.github.ape97.statscontrol", category: "menu").notice("Menu closed")
                    model.menuClosed()
                }
            }
        }
        check()
    }

    // MARK: Snapshot

    /// For snapshots: measure values as if the menu had been open for a few seconds.
    func prepareSnapshot(armed: Bool) {
        if Runtime.isDemo {
            live.cpu = Demo.cpu
            live.gpu = Demo.gpu
            live.memoryUsed = Demo.memoryUsed
            live.history = Demo.history
            live.entries = Demo.entries
            updateMenuBarImage(force: true)
            publishIfVisible()
            if armed { armedID = rows(tab).first(where: ProcessActions.canKill)?.id }
            return
        }
        _ = stats.cpuLoad()
        sampleProcessesNow()
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            tick()
        }
        sampleProcessesNow()
        if armed { armedID = rows(tab).first(where: ProcessActions.canKill)?.id }
    }
}

/// Latest measurements, unobserved (see `AppModel.live`).
private struct Live {
    var cpu: Double = 0
    var gpu: Double?
    var memoryUsed: UInt64 = 0
    var history: [Metric: [Double]] = [:]
    var entries: [ProcessEntry]?

    func memoryShare(of total: UInt64) -> Double { total > 0 ? Double(memoryUsed) / Double(total) : 0 }
}
