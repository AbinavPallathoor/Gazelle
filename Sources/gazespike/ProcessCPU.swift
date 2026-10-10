import Darwin
import Foundation

/// Measures CPU used by this process plus the WebKit helper processes it spawned
/// (WKWebView runs WASM in separate WebContent/GPU processes, which `getrusage` would miss).
/// Helpers are matched by name, by sharing our "responsible" process (the terminal, for a CLI)
/// and by starting after us.
final class ProcessCPU {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()
    private let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
    private var last: (wall: Double, cpu: Double)?

    /// Returns CPU percent (100 = one full core) since the previous call, or nil on the first call.
    func sample() -> Double? {
        let wall = Double(DispatchTime.now().uptimeNanoseconds)
        let cpu = totalCPUNanos()
        defer { last = (wall, cpu) }
        guard let last, wall > last.wall else { return nil }
        return 100 * (cpu - last.cpu) / (wall - last.wall)
    }

    /// Names of the helper processes currently counted, for logging.
    func helperNames() -> [String] { helperPIDs().map(name) }

    private func totalCPUNanos() -> Double {
        ([getpid()] + helperPIDs()).reduce(0) { $0 + cpuNanos($1) }
    }

    private func helperPIDs() -> [pid_t] {
        guard let responsible else { return [] }
        let me = getpid()
        let owner = responsible(me)
        let myStart = startTime(me)
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, n)).filter {
            $0 > 0 && $0 != me && responsible($0) == owner
                && name($0).hasPrefix("com.apple.WebKit") && startTime($0) >= myStart
        }
    }

    private func startTime(_ pid: pid_t) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return info.pbi_start_tvsec
    }

    private func cpuNanos(_ pid: pid_t) -> Double {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard ok == 0 else { return 0 }
        return Double(info.ri_user_time + info.ri_system_time) * timebase
    }

    private func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return String(cString: buf)
    }
}
