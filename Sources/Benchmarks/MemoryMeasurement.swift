import Foundation
@preconcurrency import Darwin

/// Returns the current resident memory size in bytes using mach_task_basic_info.
func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let selfPort = mach_task_self_
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
            task_info(selfPort, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return info.resident_size
}

/// Formats bytes as a human-readable string (e.g., "14.2 MB").
func formatBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    return String(format: "%.1f MB", mb)
}
