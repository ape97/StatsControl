import SwiftUI

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = Runtime.arguments.contains("--settings")

    var body: some View {
        VStack(spacing: 8) {
            if showSettings {
                SettingsPage { withAnimation(.snappy(duration: 0.25)) { showSettings = false } }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 8) {
                    MetricTiles()
                    ProcessModule()
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            FooterBar(showSettings: $showSettings)
        }
        .padding(10)
        .frame(width: 380)
    }
}

// MARK: Tiles

/// CPU, GPU, Memory side by side – a click selects the list below.
struct MetricTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Metric.allCases) { metric in
                MetricTile(metric: metric, value: model.value(metric), history: model.history[metric] ?? [],
                           selected: model.tab == metric) {
                    withAnimation(.snappy(duration: 0.25)) { model.select(metric) }
                }
            }
        }
    }
}

struct MetricTile: View {
    let metric: Metric
    let value: Double?
    let history: [Double]
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let dark = scheme == .dark
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    DeviceBadge(symbol: metric.symbol, size: 18, tint: metric.tint)
                    Text(metric.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(value.map(percent) ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                Sparkline(values: history, tint: metric.tint)
                    .frame(height: 16)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(metric.tint.opacity(dark ? 0.22 : 0.13))
                                 : AnyShapeStyle(.primary.opacity((dark ? 0.06 : 0.045) + (hover ? 0.03 : 0))), in: shape)
            .overlay(shape.strokeBorder(selected ? AnyShapeStyle(metric.tint.opacity(0.6)) : AnyShapeStyle(.primary.opacity(dark ? 0.08 : 0.05)),
                                        lineWidth: selected ? 1 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Apps by \(metric.title)")
    }
}

/// History of the last two minutes, right-aligned (newest value on the right).
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(AppModel.historyLength - 1)
            let start = size.width - step * CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                let v = min(max(values[i], 0), 1)
                return CGPoint(x: start + step * CGFloat(i), y: size.height - 1 - (size.height - 2) * v)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: List

struct ProcessModule: View {
    @Environment(AppModel.self) private var model
    /// Order while the mouse is over the list: values keep updating but nothing jumps away under the pointer.
    @State private var frozen: [String]?
    /// Highest row count since opening or tab change (a new menu = new identity, starts at 0).
    @State private var slots = 0

    static let rowHeight: CGFloat = 28
    static let visibleRows = 11

    var body: some View {
        let metric = model.tab
        let rows = displayed(metric)
        Module(spacing: 6) {
            HStack(spacing: 6) {
                Text("Apps by \(metric.title)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(summary(metric))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            Group {
                if model.entries == nil {
                    placeholder(symbol: "hourglass", text: "Measuring…")
                } else if rows.isEmpty {
                    placeholder(symbol: metric.symbol, text: "Nothing is using the \(metric.title) right now.")
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            // Rows by position, not by process: when the order changes only the content changes, the
                            // rows themselves (with hover/tooltip areas) stay in place. Every structural change makes
                            // macOS reset the mouse pointer – with a customized accessibility pointer ~40–60 ms each time.
                            // List height only grows (slots without a process stay empty): every new document height of the
                            // ScrollView rebuilt the mouse areas – with a fluctuating process count on every tick.
                            ForEach(0..<max(slots, rows.count), id: \.self) { index in
                                let used = index < rows.count
                                ProcessRow(entry: rows[min(index, rows.count - 1)], metric: metric)
                                    .opacity(used ? 1 : 0)
                                    .allowsHitTesting(used)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .mask(ScrollFade(active: max(slots, rows.count) > Self.visibleRows))
                    .onHover { inside in frozen = inside ? rows.map(\.id) : nil }
                    .onChange(of: rows.count, initial: true) { slots = max(slots, rows.count) }
                }
            }
            .frame(height: Self.rowHeight * CGFloat(Self.visibleRows))
        }
        .onChange(of: metric) { frozen = nil; slots = 0 }
    }

    private func displayed(_ metric: Metric) -> [ProcessEntry] {
        let live = model.rows(metric)
        guard let frozen else { return live }
        let all = model.entriesByID
        let kept = frozen.compactMap { all[$0] }
        let known = Set(frozen)
        return kept + live.filter { !known.contains($0.id) }
    }

    private func summary(_ metric: Metric) -> String {
        switch metric {
        case .cpu: "\(model.cpuCores) cores"
        case .gpu: model.gpuCores.map { "\($0) cores" } ?? ""
        case .memory: "\(bytes(model.memoryUsed)) of \(Int((Double(model.memoryTotal) / 1_073_741_824).rounded())) GB"
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProcessRow: View {
    let entry: ProcessEntry
    let metric: Metric
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let armed = model.armedID == entry.id
        let canKill = ProcessActions.canKill(entry)
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(for: entry))   // pre-rendered at 20 pt
                .frame(width: 20, height: 20)
            Text(entry.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path.isEmpty ? "PID \(entry.pid)" : "PID \(entry.pid) · \(entry.path)")
            if entry.processCount > 1 {
                CountBadge(count: entry.processCount)
                    .help("\(entry.processCount) processes")
            }
            Spacer(minLength: 4)
            // Quit only – no "bring to front", no "show in Finder".
            // Always present, only invisible: showing/hiding via `if` changed the structure for every row under the mouse –
            // macOS then reset the pointer each time (main cost with the menu open, measured).
            KillButton(armed: armed) {
                withAnimation(.snappy(duration: 0.2)) {
                    if armed { model.forceQuit(entry) } else { model.arm(entry.id) }
                }
            }
            .opacity((hover || armed) && canKill ? 1 : 0)
            .allowsHitTesting(canKill)
            Text(model.notices[entry.id] ?? valueText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(model.notices[entry.id] != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: ProcessModule.rowHeight)
        .background(hover ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in
            // No animation, like Apple's menus: every mouse movement over the list would otherwise redraw many frames.
            hover = inside
            if !inside && armed { withAnimation(.snappy(duration: 0.2)) { model.arm(nil) } }
        }
        .contextMenu {
            if canKill {
                Button("Quit") { model.quit(entry) }
                    .help("Ask the app to quit, like Quit in its own menu")
                Button("Force Quit") { model.forceQuit(entry) }
                    .help("Force the app to quit immediately; unsaved work is lost")
            }
        }
    }

    private var valueText: String {
        metric == .memory ? bytes(entry.memory) : finePercent(entry.value(metric))
    }
}

/// Two-step: the first click turns the button red ("Force Quit"), only the second one quits.
/// Deliberately not a `Button`: SwiftUI creates a focus ring as an AppKit view per button and re-attaches it on every tick –
/// that made macOS constantly reset the pointer with the menu open (measured). Looks like `RoundIconButton`.
struct KillButton: View {
    let armed: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Group {
            if armed {
                Text("Force Quit")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Color.red.gradient, in: Capsule())
                    .contentShape(Capsule())
                    .help("Click again to force quit")
                    // Cross-fade only: every intermediate size of a text animation is stored by CoreGraphics as separate glyph bitmaps
                    // that are never released (hence no `.numericText()` either – memory grew beyond 100 MB).
                    .transition(.opacity)
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hover ? Color.primary : Color.secondary)
                    .frame(width: 20, height: 20)
                    .background(.primary.opacity(hover ? 0.12 : 0.07), in: Circle())
                    .contentShape(Circle())
                    .help("Force Quit")
            }
        }
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: Footer

struct FooterBar: View {
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Stats Control")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            RoundIconButton(symbol: "waveform.path.ecg", size: 24, help: "Open Activity Monitor") {
                SystemLinks.openActivityMonitor()
            }
            RoundIconButton(symbol: "gearshape.fill", size: 24, active: showSettings, help: "Settings") {
                withAnimation(.snappy(duration: 0.25)) { showSettings.toggle() }
            }
            RoundIconButton(symbol: "power", size: 24, help: "Quit Stats Control") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 4)
    }
}
