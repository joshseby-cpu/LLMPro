import Foundation
import Darwin
import SwiftUI

@MainActor
@Observable
final class SystemMetrics {
    static let shared = SystemMetrics()

    struct Snapshot: Equatable {
        var usedGB: Double
        var totalGB: Double
        var pressurePercent: Double
        var timestamp: Date
    }

    private(set) var current: Snapshot = .init(usedGB: 0, totalGB: 0, pressurePercent: 0, timestamp: Date())
    private(set) var history: [Snapshot] = []
    private var task: Task<Void, Never>?

    var totalMemoryBytes: UInt64 { Self.totalSystemMemory() }

    private init() {}

    func start() {
        // Idempotent: a single long-lived poller is shared across every tab.
        // Cancelling + restarting on each view's onAppear (while another view's
        // onDisappear calls stop()) created a race that left the poller dead and
        // the gauges reading 0. So once it's running, leave it running.
        guard task == nil else { return }
        let total = Double(totalMemoryBytes) / 1_073_741_824.0
        task = Task { [weak self] in
            while !Task.isCancelled {
                let used = Self.usedSystemMemoryGB()
                let snap = Snapshot(
                    usedGB: used,
                    totalGB: total,
                    pressurePercent: total > 0 ? (used / total) * 100 : 0,
                    timestamp: Date()
                )
                await MainActor.run {
                    self?.current = snap
                    self?.history.append(snap)
                    if let h = self?.history, h.count > 120 { self?.history.removeFirst(h.count - 120) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private static func totalSystemMemory() -> UInt64 {
        // ProcessInfo is the most reliable source and never returns 0; keep the
        // sysctl path as a fallback for parity with how "used" is sampled.
        let pi = ProcessInfo.processInfo.physicalMemory
        if pi > 0 { return pi }
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }

    private static func usedSystemMemoryGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let bytesPerPage = Double(pageSize)
        let usedBytes = Double(stats.active_count + stats.wire_count) * bytesPerPage
        return usedBytes / 1_073_741_824.0
    }
}
