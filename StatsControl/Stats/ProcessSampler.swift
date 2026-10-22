import AppKit
import Darwin

/// Raw values of a process at one point in time.
struct RawProcess {
    let pid: pid_t
    let uid: uid_t
    /// Responsible process (e.g. Safari for a WebContent process), otherwise its own PID.
    let owner: pid_t
    /// Executable file, empty if unknown.
    let path: String
    let name: String
    /// CPU time consumed since process start in nanoseconds.
    let cpuTime: UInt64
    /// Memory as in Activity Monitor ("Memory" = phys_footprint), otherwise resident memory.
    let memory: UInt64
}

struct RawSample {
    /// Timestamp in nanoseconds since boot.
    let time: UInt64
    let processes: [pid_t: RawProcess]
    /// Accumulated GPU time per process in nanoseconds.
    let gpuTime: [pid_t: UInt64]
}

/// Reads all processes without special privileges. Runs in the background (no AppKit calls).
/// Own processes deliver exact values via proc_pid_rusage; for foreign ones (root, WindowServer, kernel_task)
/// `ps` steps in – as a setuid program it may read all processes (measured: ~10 ms for ~630 processes).
enum ProcessSampler {
    static func sample() -> RawSample {
        let time = DispatchTime.now().uptimeNanoseconds
        let table = psTable()
        var pids = Set(listAllPIDs())
        pids.formUnion(table.keys)
        var result: [pid_t: RawProcess] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids {
            let row = table[pid]
            let usage = rusage(pid)
            guard usage != nil || row != nil else { continue }
            let path = executablePath(pid) ?? ""
            let comm = processName(pid)
            var name = path.isEmpty ? comm : (path as NSString).lastPathComponent
            // Show versioned executables (e.g. node: …/node/versions/20.1.0) under their process name.
            if name.first?.isNumber == true, !comm.isEmpty, comm.first?.isNumber == false { name = comm }
            if name.isEmpty { name = "pid \(pid)" }
            result[pid] = RawProcess(
                pid: pid,
                uid: row?.uid ?? shortUID(pid) ?? 0,
                owner: responsiblePID(pid),
                path: path,
                name: name,
                cpuTime: usage?.cpu ?? row?.cpu ?? 0,
                memory: usage?.memory ?? row?.rss ?? 0
            )
        }
        return RawSample(time: time, processes: result, gpuTime: GPU.timeByPID())
    }

    // MARK: Sources

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    static func listAllPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// CPU time (ns) and memory – only for processes of the current user.
    private static func rusage(_ pid: pid_t) -> (cpu: UInt64, memory: UInt64)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        // Times come in Mach units (Apple Silicon: 125/3 ns).
        let ticks = info.ri_user_time + info.ri_system_time
        return (ticks * timebase.numer / timebase.denom, info.ri_phys_footprint)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func shortUID(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info.pbsi_uid : nil
    }

    struct PSRow {
        let uid: uid_t
        let cpu: UInt64
        let rss: UInt64
    }

    /// Short name from the kernel (name at launch, e.g. "node" instead of the file "20.1.0") – works for all processes.
    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    /// `ps -A`: PID, user, CPU time, resident (KB) – for all processes.
    /// Directly via posix_spawn: Foundation's `Process` cost about 75 ms per call, this way it is ~10 ms.
    static func psTable() -> [pid_t: PSRow] {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return [:] }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // Do not inherit the app's open files to ps.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = ["/bin/ps", "-A", "-o", "pid=,uid=,time=,rss="]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let started = posix_spawn(&child, "/bin/ps", &actions, &attributes, &argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(fds[1])
        defer { close(fds[0]) }
        guard started == 0 else { return [:] }

        var data = [UInt8]()
        data.reserveCapacity(32_768)
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fds[0], &chunk, chunk.count)
            if count > 0 { data.append(contentsOf: chunk[0..<count]) } else if count == 0 || errno != EINTR { break }
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}

        var table: [pid_t: PSRow] = [:]
        table.reserveCapacity(1024)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let uid = uid_t(parts[1]),
                  let cpu = cpuTime(parts[2]), let rss = UInt64(parts[3]) else { continue }
            table[pid] = PSRow(uid: uid, cpu: cpu, rss: rss * 1024)
        }
        return table
    }

    /// "[T-][hh:]mm:ss.ss" → nanoseconds.
    static func cpuTime(_ text: Substring) -> UInt64? {
        var days = 0.0
        var rest = text
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var seconds = 0.0
        for part in rest.split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return UInt64((days * 86400 + seconds) * 1_000_000_000)
    }
}

/// Returns the process ID of the "responsible" app.
let responsiblePID: (pid_t) -> pid_t = {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return { $0 }
    }
    let fn = unsafeBitCast(sym, to: Fn.self)
    return { pid in
        let r = fn(pid)
        return r > 0 ? r : pid
    }
}()

// MARK: Apps and processes

/// One row of the list: an app with its helper processes or a single process.
struct ProcessEntry: Identifiable {
    let id: String
    let name: String
    let pid: pid_t
    let uid: uid_t
    let app: NSRunningApplication?
    /// App bundle or executable file (empty if unknown).
    let path: String
    private(set) var pids: [pid_t] = []
    /// Share of total CPU or GPU (0…1).
    private(set) var cpu: Double = 0
    private(set) var gpu: Double = 0
    private(set) var memory: UInt64 = 0

    init(id: String, name: String, pid: pid_t, uid: uid_t, app: NSRunningApplication?, path: String) {
        self.id = id
        self.name = name
        self.pid = pid
        self.uid = uid
        self.app = app
        self.path = path
    }

    mutating func add(pid: pid_t, cpu: Double, gpu: Double, memory: UInt64) {
        pids.append(pid)
        self.cpu += cpu
        self.gpu += gpu
        self.memory += memory
    }

    var processCount: Int { pids.count }

    func value(_ metric: Metric) -> Double {
        switch metric {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: Double(memory)
        }
    }
}

/// Derives shares from two measurements and groups processes into apps.
/// A process belongs to an app if the app is responsible for it AND it comes from its bundle or from macOS
/// itself (helper processes, XPC services, WebContent). Programs started in a terminal remain separate rows,
/// so that e.g. a hung `node` can be quit on its own without hitting the terminal.
@MainActor
final class ProcessTracker {
    private var previous: RawSample?

    func reset() { previous = nil }

    /// nil on the first call (no reference value yet).
    func update(with sample: RawSample, cpuCores: Int) -> [ProcessEntry]? {
        defer { previous = sample }
        guard let prev = previous, sample.time > prev.time else { return nil }
        let interval = Double(sample.time - prev.time)
        let capacity = interval * Double(max(cpuCores, 1))

        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.bundleURL != nil && app.activationPolicy != .prohibited {
            apps[app.processIdentifier] = app
        }

        var byID: [String: ProcessEntry] = [:]
        for p in sample.processes.values {
            let cpu = prev.processes[p.pid].map { p.cpuTime >= $0.cpuTime ? Double(p.cpuTime - $0.cpuTime) / capacity : 0 } ?? 0
            let gpuNow = sample.gpuTime[p.pid] ?? 0
            let gpu = prev.gpuTime[p.pid].map { gpuNow >= $0 ? Double(gpuNow - $0) / interval : 0 } ?? 0
            if let app = Self.app(for: p, in: apps) {
                let id = "app:\(app.processIdentifier)"
                var entry = byID[id] ?? ProcessEntry(
                    id: id, name: app.localizedName ?? p.name, pid: app.processIdentifier,
                    uid: sample.processes[app.processIdentifier]?.uid ?? getuid(), app: app, path: app.bundleURL?.path ?? ""
                )
                entry.add(pid: p.pid, cpu: cpu, gpu: gpu, memory: p.memory)
                byID[id] = entry
            } else {
                var entry = ProcessEntry(id: "pid:\(p.pid)", name: p.name, pid: p.pid, uid: p.uid, app: nil, path: p.path)
                entry.add(pid: p.pid, cpu: cpu, gpu: gpu, memory: p.memory)
                byID[entry.id] = entry
            }
        }
        return Array(byID.values)
    }

    static func app(for p: RawProcess, in apps: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        if let app = apps[p.pid] { return app }
        guard p.owner != p.pid, let app = apps[p.owner], let bundle = app.bundleURL?.path else { return nil }
        let path = p.path
        if path.hasPrefix(bundle + "/") || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.contains(".xpc/") {
            return app
        }
        return nil
    }
}

/// Load icons only when needed (visible rows only).
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for entry: ProcessEntry) -> NSImage {
        let key = entry.app.map { "app:\($0.bundleIdentifier ?? entry.path)" }
            ?? entry.path.range(of: ".app/").map { String(entry.path[..<$0.lowerBound]) }
            ?? "exec"   // all other processes share one icon instead of one per path
        if let hit = cache[key] { return hit }
        let image: NSImage
        if let icon = entry.app?.icon {
            image = icon
        } else if let range = entry.path.range(of: ".app/") {
            image = NSWorkspace.shared.icon(forFile: String(entry.path[..<range.lowerBound]) + ".app")
        } else {
            // Like Activity Monitor: a uniform program icon (file icons would show a document for "20.1.0").
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        let fixed = IconRaster.fixed(image, points: 20)
        cache[key] = fixed
        return fixed
    }
}
