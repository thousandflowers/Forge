import Darwin
import Foundation

/// Whether some other process is still writing a file.
///
/// A file that has stopped growing is not necessarily finished: a copy from a
/// network share or a slow download stalls for seconds at a time. What does
/// tell is whether the writer still holds it open for writing, which is what
/// `lsof` answers, asked here through the same kernel calls.
///
/// Only writing counts. The Finder's preview keeps a picture it shows mapped,
/// through QuickLookUIService, for as long as it is selected, and a file just
/// renamed in the Finder is selected: counted as a writer, it was waited for
/// for five minutes.
enum FileActivity {
  /// `FWRITE` in `<sys/fcntl.h>`, which Swift does not see.
  private static let openedForWriting: UInt32 = 0x0002
  /// The count can grow between two calls; leave room for a few more.
  private static let slack = 16

  static func isOpenElsewhere(_ url: URL) -> Bool {
    var target = stat()
    guard stat(url.path, &target) == 0 else { return false }
    let me = getpid()
    return processes(using: url.path).contains { $0 != me && writes(target, in: $0) }
  }

  /// Every process that has it at all: open, mapped, or as its directory.
  private static func processes(using path: String) -> [pid_t] {
    let flags = UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
    let needed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, flags, nil, 0)
    guard needed > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + slack)
    let written = proc_listpidspath(
      UInt32(PROC_ALL_PIDS), 0, path, flags, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
    )
    guard written > 0 else { return [] }
    return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 != 0 }
  }

  /// Whether this process has the file open with a descriptor it can write.
  private static func writes(_ target: stat, in pid: pid_t) -> Bool {
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    // Another user's process (a copy run as root) cannot be looked into: it
    // is still taken for a writer, as before, rather than risk a half file.
    guard needed > 0 else { return errno == EPERM }
    let stride = MemoryLayout<proc_fdinfo>.stride
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + slack)
    let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
    guard written > 0 else { return false }

    return descriptors.prefix(Int(written) / stride).contains { descriptor in
      guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return false }
      var info = vnode_fdinfowithpath()
      let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
      guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return false }
      let seen = info.pvip.vip_vi.vi_stat
      return seen.vst_dev == UInt32(bitPattern: target.st_dev) && seen.vst_ino == target.st_ino
        && info.pfi.fi_openflags & openedForWriting != 0
    }
  }
}
