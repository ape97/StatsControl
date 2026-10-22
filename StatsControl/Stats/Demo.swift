import AppKit

/// Invented, fixed values for promotional images (`--snapshot … --demo`): nothing here is measured or read from the system.
enum Demo {
    static let cpuCores = 10
    static let gpuCores: Int? = 16
    static let memoryTotal: UInt64 = 16 << 30
    static let cpu = 0.34
    static let gpu: Double? = 0.27
    static let memoryUsed: UInt64 = 10 << 30

    /// 2 minutes of plausible, smooth curves; a closed formula keeps every run identical.
    static var history: [Metric: [Double]] {
        func curve(_ base: Double, _ swing: Double, _ phase: Double, last: Double) -> [Double] {
            let n = 60   // = AppModel.historyLength
            var values = (0..<n).map { i -> Double in
                let t = Double(i)
                return max(0.02, min(0.98, base + swing * (0.6 * sin(t / 5 + phase) + 0.4 * sin(t / 2.3 + phase * 2))))
            }
            values[n - 1] = last
            return values
        }
        return [.cpu: curve(0.30, 0.14, 0.4, last: cpu),
                .gpu: curve(0.22, 0.12, 2.1, last: gpu ?? 0),
                .memory: curve(0.60, 0.03, 4.0, last: Double(memoryUsed) / Double(memoryTotal))]
    }

    /// Well-known Apple apps, resolved by bundle ID only for their icons; shares are of total capacity.
    static var entries: [ProcessEntry] {
        let rows: [(name: String, bundle: String?, uid: uid_t, procs: Int, cpu: Double, gpu: Double, gigabytes: Double)] = [
            ("Safari", "com.apple.Safari", getuid(), 6, 0.092, 0.061, 1.9),
            ("Xcode", "com.apple.dt.Xcode", getuid(), 3, 0.071, 0.018, 2.4),
            ("Music", "com.apple.Music", getuid(), 2, 0.034, 0.022, 0.6),
            ("Photos", "com.apple.Photos", getuid(), 2, 0.026, 0.047, 1.1),
            ("Mail", "com.apple.mail", getuid(), 2, 0.018, 0.004, 0.5),
            ("Messages", "com.apple.MobileSMS", getuid(), 1, 0.012, 0.003, 0.4),
            ("Finder", "com.apple.finder", getuid(), 1, 0.008, 0.006, 0.2),
            ("Notes", "com.apple.Notes", getuid(), 2, 0.007, 0.012, 0.35),
            ("Calendar", "com.apple.iCal", getuid(), 1, 0.006, 0.002, 0.25),
            ("Preview", "com.apple.Preview", getuid(), 1, 0.005, 0.024, 0.3),
            ("Terminal", "com.apple.Terminal", getuid(), 1, 0.004, 0.001, 0.15),
            ("System Settings", "com.apple.systempreferences", getuid(), 1, 0.003, 0.002, 0.2),
            ("Maps", "com.apple.Maps", getuid(), 1, 0.002, 0.015, 0.45),
        ]
        return rows.enumerated().map { i, row in
            let path = row.bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path } ?? ""
            let pid = pid_t(1000 + i * 10)
            var entry = ProcessEntry(id: row.name, name: row.name, pid: pid, uid: row.uid, app: nil, path: path.isEmpty ? "" : path + "/")
            for p in 0..<row.procs {
                let n = Double(row.procs)
                entry.add(pid: pid + pid_t(p), cpu: row.cpu / n, gpu: row.gpu / n, memory: UInt64(row.gigabytes / n * 1_073_741_824))
            }
            return entry
        }
    }
}
