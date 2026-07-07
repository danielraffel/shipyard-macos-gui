import Foundation
import Darwin

/// Coarse macOS memory-pressure level, mirroring the kernel's
/// `kern.memorystatus_vm_pressure_level` sysctl (1 = normal, 2 = warning,
/// 4 = critical). This is the same signal `memory_pressure(1)` surfaces and the
/// one a lease governor would consult before granting a native-build lease.
enum MemoryPressure: Equatable {
    case normal, warning, critical, unknown

    /// Kernel `kern.memorystatus_vm_pressure_level` values → cases. Anything the
    /// kernel doesn't report as one of the three known levels is `.unknown`
    /// (so the UI shows a neutral state rather than fabricating "normal").
    static func classify(level: Int32?) -> MemoryPressure {
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    var label: String {
        switch self {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        case .unknown:  return "Unknown"
        }
    }
}

/// A raw sample of the VM page counters + page size + total physical RAM. Split
/// out from the interpretation so the free-memory math is a pure, testable
/// function that never has to touch `host_statistics64`.
struct VMSample: Equatable {
    let freePages: UInt64
    let inactivePages: UInt64
    let pageSize: UInt64
    let totalBytes: UInt64
}

/// A point-in-time snapshot of THIS Mac's vitals — the "see what the governor
/// sees" panel. 1-minute load average, memory-pressure level, and free RAM,
/// read in-process via `getloadavg`/`sysctl`/`host_statistics64` (no subprocess).
struct HostHealth: Equatable {
    /// 1-minute load average (BSD `getloadavg`).
    var loadAverage1m: Double
    var pressure: MemoryPressure
    /// "Available" RAM = free + inactive pages, matching Activity Monitor's
    /// notion of memory the system can hand out without paging.
    var freeBytes: UInt64
    var totalBytes: UInt64

    /// Available-memory fraction (0...1). 0 when total is unknown (avoids NaN).
    var freeFraction: Double {
        totalBytes == 0 ? 0 : min(1, Double(freeBytes) / Double(totalBytes))
    }

    /// Two-decimal load, so a change from 1.2 → 1.25 is visible.
    var loadSummary: String { String(format: "%.2f", loadAverage1m) }

    var freeSummary: String { HostHealth.formatBytes(freeBytes) }

    /// Available = free + inactive. Pure — the caller supplies the sample so
    /// tests can assert the arithmetic without a live kernel.
    static func availableBytes(_ s: VMSample) -> UInt64 {
        (s.freePages &+ s.inactivePages) &* s.pageSize
    }

    /// Deterministic byte formatter (GB with one decimal ≥ 1 GB, else whole MB).
    /// Hand-rolled rather than `ByteCountFormatter` so tests are exact and the
    /// binary/decimal unit choice is fixed.
    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

/// Reads live host vitals. The three raw providers are injectable so tests drive
/// fixed samples and never read (let alone mutate) the real host.
enum HostHealthProbe {
    typealias LoadProvider = () -> Double?
    typealias PressureProvider = () -> Int32?
    typealias MemoryProvider = () -> VMSample?

    /// Compose a `HostHealth` from the (injectable) raw providers. Any provider
    /// returning nil degrades that field gracefully — load falls to 0,
    /// pressure to `.unknown`, memory to zeroes — rather than failing the whole
    /// read, so a partial kernel hiccup still paints a usable panel.
    static func read(
        load: LoadProvider = liveLoadAverage,
        pressure: PressureProvider = livePressureLevel,
        memory: MemoryProvider = liveMemory
    ) -> HostHealth {
        let sample = memory()
        return HostHealth(
            loadAverage1m: load() ?? 0,
            pressure: MemoryPressure.classify(level: pressure()),
            freeBytes: sample.map(HostHealth.availableBytes) ?? 0,
            totalBytes: sample?.totalBytes ?? 0
        )
    }

    // MARK: - Live providers (in-process, no subprocess)

    /// 1-minute load average via BSD `getloadavg`. nil if the call fails.
    static func liveLoadAverage() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        // Returns the number of samples retrieved, or -1 on error.
        guard getloadavg(&loads, 3) >= 1 else { return nil }
        return loads[0]
    }

    /// `kern.memorystatus_vm_pressure_level` (1 normal / 2 warning / 4 critical).
    /// nil if the sysctl is unavailable.
    static func livePressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return nil }
        return level
    }

    /// Page counters + page size (`host_statistics64` / `host_page_size`) and
    /// total physical RAM (`ProcessInfo.physicalMemory`). nil if the VM query
    /// fails, so the caller can degrade rather than report bogus zeroes as real.
    static func liveMemory() -> VMSample? {
        // mach_host_self() hands back a send right whose user-ref count bumps on
        // every call, so release it before returning (this runs on a 5s poll for
        // the whole app lifetime — leaked port refs would accumulate otherwise).
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        return VMSample(
            freePages: UInt64(stats.free_count),
            inactivePages: UInt64(stats.inactive_count),
            pageSize: UInt64(pageSize),
            totalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }
}
