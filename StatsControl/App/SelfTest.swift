import AppKit

/// Invisible self-test (scripts/check.sh): measures, groups and quits its own test process.
/// No window, no focus, no foreign processes – nothing the user would notice.
@MainActor
enum SelfTest {
    private static var failures: [String] = []
    private static var report: [String: Any] = [:]
    private static var child: Process?

    static func run(writingTo path: String) {
        let model = AppModel.shared
        model.tick()
        model.sampleProcessesNow()

        // Own throwaway process: a program from /bin must not be grouped into an app.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1000"]
        do { try sleeper.run(); child = sleeper } catch { failures.append("sleep start: \(error)") }

        after(0.6) {
            model.tick()
            model.sampleProcessesNow()
            checkValues(model)
            checkProcesses(model, sleeper: sleeper)
            after(0.7) { finish(model, sleeper: sleeper, path: path) }
        }
    }

    private static func checkValues(_ model: AppModel) {
        if !(0...1).contains(model.cpu) { failures.append("cpu out of range: \(model.cpu)") }
        if !(0...1).contains(model.memoryShare) || model.memoryUsed == 0 { failures.append("memory: \(model.memoryShare)") }
        if let gpu = model.gpu, !(0...1).contains(gpu) { failures.append("gpu out of range: \(gpu)") }
        if model.menuBarImage.size.width < 40 { failures.append("menu bar image too small") }
        checkCompactBar()
        report["cpu"] = model.cpu
        report["gpu"] = model.gpu ?? NSNull()
        report["memory"] = model.memoryShare
        report["gpuCores"] = model.stats.gpuCores ?? 0
        // Cost of one process measurement (background every 30 s, open every 2 s) – should stay in the millisecond range.
        let start = Date()
        for _ in 0..<5 { _ = ProcessSampler.sample() }
        let sampleMs = Date().timeIntervalSince(start) * 1000 / 5
        report["sampleMs"] = (sampleMs * 10).rounded() / 10
        func ms(_ work: () -> Void) -> Double {
            let t = Date(); for _ in 0..<5 { work() }
            return (Date().timeIntervalSince(t) * 1000 / 5 * 10).rounded() / 10
        }
        report["sampleParts"] = [
            "ps": ms { _ = ProcessSampler.psTable() },
            "gpu": ms { _ = GPU.timeByPID() },
            "paths": ms { for pid in ProcessSampler.listAllPIDs() { _ = ProcessSampler.executablePath(pid) } },
            "owners": ms { for pid in ProcessSampler.listAllPIDs() { _ = responsiblePID(pid) } },
        ]
        if sampleMs > 250 { failures.append("process sample too slow: \(Int(sampleMs)) ms") }
    }

    /// Compact bar: column selection, inclusive threshold with fall-back 5 points below, widths.
    private static func checkCompactBar() {
        func columns(_ values: [Int?], hot: Set<Metric> = [], _ preferred: Metric = .cpu, threshold: Int = 50) -> [Bool] {
            AppModel.compactColumns(hot: AppModel.hotMetrics(values, previous: hot, threshold: threshold), preferred: preferred)
        }
        let cases: [(String, [Bool], [Bool])] = [
            ("all low → preferred", columns([20, 5, 40], .memory), [false, false, true]),
            ("RAM 51 swaps with CPU", columns([20, 5, 51]), [false, false, true]),
            ("50 counts at threshold 50", columns([20, nil, 50]), [false, false, true]),
            ("49 is below", columns([20, nil, 49]), [true, false, false]),
            ("threshold 80: RAM 70 stays hidden", columns([20, 5, 70], threshold: 80), [true, false, false]),
            ("threshold 30: both high", columns([35, 5, 30], threshold: 30), [true, false, true]),
            ("two high side by side", columns([60, 5, 51]), [true, false, true]),
            ("all high", columns([90, 70, 51]), [true, true, true]),
            ("stays high at 47", columns([20, 5, 47], hot: [.memory]), [false, false, true]),
            ("stays high at 46", columns([20, 5, 46], hot: [.memory]), [false, false, true]),
            ("falls back at 45", columns([20, 5, 45], hot: [.memory]), [true, false, false]),
        ]
        for (name, got, expected) in cases where got != expected { failures.append("compact \(name): \(got)") }
        let one = MenuBarLabel.Layout.showing([false, true, false]), all = MenuBarLabel.Layout.full
        if abs(one.width * 3 + 4 - all.width) > 0.01 { failures.append("compact width \(one.width) vs \(all.width)") }
        if all.blended(to: one, 1) != one || all.blended(to: one, 0) != all { failures.append("compact blend endpoints") }
    }

    private static func checkProcesses(_ model: AppModel, sleeper: Process) {
        guard let entries = model.entries else { failures.append("no process list"); return }
        report["processes"] = entries.reduce(0) { $0 + $1.processCount }
        report["rows"] = entries.count
        report["groupedApps"] = entries.filter { $0.processCount > 1 }.map { "\($0.name) (\($0.processCount))" }.sorted()
        report["topCPU"] = model.rows(.cpu).prefix(3).map { "\($0.name) \(finePercent($0.cpu))" }
        report["topMemory"] = model.rows(.memory).prefix(3).map { "\($0.name) \(bytes($0.memory))" }

        let byID = model.entriesByID
        if byID["pid:\(sleeper.processIdentifier)"] == nil { failures.append("sleep not listed as own row") }
        guard let me = entries.first(where: { $0.pids.contains(getpid()) }) else { failures.append("own process missing"); return }
        if ProcessActions.canKill(me) { failures.append("own process killable") }
        if let launchd = entries.first(where: { $0.pids.contains(1) }), ProcessActions.canKill(launchd) { failures.append("launchd killable") }
        if let ws = entries.first(where: { $0.name == "WindowServer" }), ProcessActions.canKill(ws) { failures.append("WindowServer killable") }
        if model.rows(.memory).isEmpty { failures.append("memory list empty") }
    }

    private static func finish(_ model: AppModel, sleeper: Process, path: String) {
        // Quit via the same path as the button in the list.
        if let entry = model.entriesByID["pid:\(sleeper.processIdentifier)"] {
            model.forceQuit(entry)
        }
        after(0.7) {
            let alive = kill(sleeper.processIdentifier, 0) == 0 && sleeper.isRunning
            report["killTest"] = alive ? "failed" : "ok"
            if alive { failures.append("sleep survived force quit"); sleeper.terminate() }
            report["ok"] = failures.isEmpty
            report["failures"] = failures
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }
}
