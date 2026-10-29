import Darwin
import Foundation

/// Signals a process together with its child processes.
///
/// The pipeline runs as `taskpolicy -b uv run … meeting-pipeline`: `taskpolicy` turns into `uv`
/// (exec, same PID) and `uv` starts Python as a child process. A signal sent to `uv` alone is not
/// guaranteed to reach Python (`uv` may just exit and leave Python running), so the children get
/// the signal too, before the parent. Children are listed with `proc_listchildpids` from libproc:
/// the same information as `pgrep -P <pid>`, without starting another process. One level is
/// enough for uv → python; Python's own helpers (claude, afconvert) end when their pipes close.
nonisolated enum ProcessTree {
    /// How long SIGTERM gets before SIGKILL.
    static let killAfterSeconds: TimeInterval = 5

    /// SIGTERM to the children and the process now; SIGKILL after `killAfter` seconds to those
    /// still alive (Python ignoring the signal, `uv` waiting for it). The pipeline is idempotent,
    /// so a killed run simply continues on the next launch.
    ///
    /// Works with PIDs only, so the delayed check can run on any thread without touching the
    /// `Process` object: a process that has exited (and was reaped by `Process`) no longer answers
    /// `kill(pid, 0)`. PID reuse within seconds does not happen on macOS (PIDs are handed out in
    /// sequence). When the app itself quits before the delay is over, the check never runs; the
    /// next launch resumes the recording anyway.
    static func terminate(pid: pid_t, killAfter: TimeInterval = ProcessTree.killAfterSeconds) {
        guard pid > 0 else { return }  // kill(0, …) and kill(-1, …) would signal whole process groups
        let family = children(of: pid) + [pid]
        signal(SIGTERM, to: family)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killAfter) {
            let survivors = family.filter(isAlive)
            guard !survivors.isEmpty else { return }
            Log.pipeline.error("\(survivors.count) pipeline process(es) ignored SIGTERM, sending SIGKILL")
            signal(SIGKILL, to: survivors)
        }
    }

    /// Direct children of a process (empty for a process that is gone).
    static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        // Returns how many PIDs it wrote (verified against `pgrep -P`), not a byte count.
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// `kill` with signal 0 sends nothing and only reports whether the process exists.
    /// EPERM = it exists but belongs to someone else.
    static func isAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    /// Children first, so the parent cannot start another one in between.
    private static func signal(_ sig: Int32, to pids: [pid_t]) {
        for pid in pids where pid > 0 {
            Darwin.kill(pid, sig)
        }
    }
}
