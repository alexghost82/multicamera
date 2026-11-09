import Foundation
import Darwin

struct HostMemoryUsage: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var percentage: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(min(100, max(0, (Double(usedBytes) / Double(totalBytes) * 100).rounded())))
    }
}

enum HostTelemetry {
    static func readMemoryUsage() -> HostMemoryUsage? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_page_size)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard pageSize > 0, totalBytes > 0 else { return nil }
        let usedPages = UInt64(statistics.active_count)
            + UInt64(statistics.wire_count)
            + UInt64(statistics.compressor_page_count)
        return HostMemoryUsage(usedBytes: min(usedPages * pageSize, totalBytes), totalBytes: totalBytes)
    }
}