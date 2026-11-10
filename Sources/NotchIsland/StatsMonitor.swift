import Darwin
import Foundation
import IOKit

struct SystemStats: Equatable {
    var cpu: Double            // 0...1
    var gpu: Double?           // 0...1
    var memoryUsed: UInt64     // bytes
    var memoryTotal: UInt64
    var diskFree: Int64?       // bytes
    var diskTotal: Int64?
    var temperature: Double?   // °C, hottest processor sensor
    var down: Double           // bytes per second
    var up: Double
}

/// Samples CPU, GPU, memory, disk and network every two seconds for the
/// figures in the expanded panel. All from public system counters.
final class StatsMonitor {
    private static let key = "showStats"
    private let model: IslandModel
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastBytes: [String: (received: UInt32, sent: UInt32)] = [:]
    private var lastSample = Date()
    private var disk: (free: Int64, total: Int64)?
    private var diskChecked = Date.distantPast
    private let thermometer = TemperatureSensor()
    private var temperature: Double?

    /// On unless the user turned it off.
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        sample()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        if !on { model.stats = nil }
    }

    /// Takes a fresh reading now, for when the panel opens.
    func refresh() { sample() }

    private func sample() {
        guard enabled else { return }
        let now = Date()
        let interval = max(now.timeIntervalSince(lastSample), 0.1)
        lastSample = now

        let cpu = cpuLoad()
        let network = networkRates(over: interval)
        if now.timeIntervalSince(diskChecked) > 30 {
            diskChecked = now
            let values = try? URL(fileURLWithPath: "/").resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage, let total = values?.volumeTotalCapacity {
                disk = (free, Int64(total))
            }
        }
        let memory = memoryUsed()
        // The sensors are only read while someone is looking.
        if model.expanded || temperature == nil { temperature = thermometer.read() }
        let stats = SystemStats(cpu: cpu, gpu: gpuLoad(), memoryUsed: memory, memoryTotal: ProcessInfo.processInfo.physicalMemory,
                                diskFree: disk?.free, diskTotal: disk?.total, temperature: temperature,
                                down: network.down, up: network.up)
        // Keep counting in the background, but only redraw while the panel is open.
        if model.expanded || model.stats == nil { model.stats = stats }
    }

    private func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let last = lastTicks, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    /// App memory plus wired and compressed, the figure Activity Monitor calls "Memory Used".
    private func memoryUsed() -> UInt64 {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pages = UInt64(info.internal_page_count) - min(UInt64(info.purgeable_count), UInt64(info.internal_page_count))
            + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private func gpuLoad() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let percent = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(percent) / 100)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }

    /// Traffic on the wired and Wi-Fi interfaces (en0, en1, ...).
    private func networkRates(over interval: TimeInterval) -> (down: Double, up: Double) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return (0, 0) }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var seen: [String: (received: UInt32, sent: UInt32)] = [:]
        var cursor = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = item.pointee.ifa_data else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            seen[name] = (counters.ifi_ibytes, counters.ifi_obytes)
            if let last = lastBytes[name] {
                // The counters are 32-bit and wrap; wrapping subtraction keeps the difference right.
                received += UInt64(counters.ifi_ibytes &- last.received)
                sent += UInt64(counters.ifi_obytes &- last.sent)
            }
        }
        lastBytes = seen
        return (Double(received) / interval, Double(sent) / interval)
    }
}
