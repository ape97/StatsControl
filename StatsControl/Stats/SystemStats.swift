import Darwin
import Foundation
import IOKit

/// Overall load of the Mac: CPU (all cores), memory, GPU. Cheap enough for every tick.
struct SystemStats {
    private var lastTicks: (busy: UInt64, total: UInt64)?

    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    let cpuCores = ProcessInfo.processInfo.activeProcessorCount
    let gpuCores = GPU.coreCount()

    /// Share 0…1 since the last call (first call: since boot).
    mutating func cpuLoad() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total, busy >= last.busy else {
            return total > 0 ? Double(busy) / Double(total) : 0
        }
        return min(1, Double(busy - last.busy) / Double(total - last.total))
    }

    /// Used memory in bytes – same calculation as common monitors, so familiar values stay:
    /// active + inactive + speculative + wired + compressed − purgeable − file cache.
    func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let used = Int64(stats.active_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)
            + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
            - Int64(stats.purgeable_count) - Int64(stats.external_page_count)
        return min(memoryTotal, UInt64(max(0, used)) * page)
    }
}

/// GPU via IOKit (Apple Silicon, no special privileges).
enum GPU {
    /// Utilization 0…1 according to the driver ("Device Utilization %"), nil if unreadable.
    static func load() -> Double? {
        var best: Double?
        forEachAccelerator { entry in
            guard let stats = property(entry, "PerformanceStatistics") as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            best = max(best ?? 0, value / 100)
        }
        return best.map { min(1, max(0, $0)) }
    }

    static func coreCount() -> Int? {
        var cores: Int?
        forEachAccelerator { entry in
            if let n = (property(entry, "gpu-core-count") as? NSNumber)?.intValue { cores = n }
        }
        return cores
    }

    /// Accumulated GPU time per process in nanoseconds. Source: the processes' connections to the graphics driver
    /// (`IOUserClientCreator` = "pid 123, name", `AppUsage[].accumulatedGPUTime`).
    static func timeByPID() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        forEachAccelerator { accelerator in
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard let creator = property(child, "IOUserClientCreator") as? String,
                      let pid = pid(fromCreator: creator),
                      let usage = property(child, "AppUsage") as? [[String: Any]] else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                result[pid, default: 0] += time
            }
        }
        return result
    }

    static func pid(fromCreator text: String) -> pid_t? {
        guard text.hasPrefix("pid ") else { return nil }
        let digits = text.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    private static func forEachAccelerator(_ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
