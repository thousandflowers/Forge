import Darwin
import Foundation

/// Whether some other process is still using a file.
///
/// A file that has stopped growing is not necessarily finished: a copy from a
/// network share or a slow download stalls for seconds at a time. What does
/// tell is whether the writer still holds it open, which is what `lsof`
/// answers, asked here through the same kernel call.
enum FileActivity {
  static func isOpenElsewhere(_ url: URL) -> Bool {
    let path = url.path
    let flags = UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
    let needed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, flags, nil, 0)
    guard needed > 0 else { return false }

    // The count can grow between the two calls; leave room for a few more.
    let slack = 16
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + slack)
    let written = proc_listpidspath(
      UInt32(PROC_ALL_PIDS), 0, path, flags, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
    )
    guard written > 0 else { return false }

    let me = getpid()
    return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).contains { $0 != 0 && $0 != me }
  }
}
