import Darwin
import Foundation

/// Ends a process, on the user's explicit instruction and never otherwise.
///
/// Two steps, in the order a person would want them: ask politely, and only
/// force it if the polite request was ignored. `SIGTERM` lets an app save and
/// close; `SIGKILL` does not, and is offered separately rather than applied
/// automatically.
public enum ProcessTerminator {
    public enum Failure: Error, Sendable, Equatable {
        case refusedProtectedProcess
        case notPermitted
        case alreadyGone

        public var message: String {
            switch self {
            case .refusedProtectedProcess: "This process cannot be ended from here."
            case .notPermitted: "macOS did not permit ending this process. It belongs to another user or to the system."
            case .alreadyGone: "The process had already exited."
            }
        }
    }

    /// PIDs that must never be signalled: the init process, the kernel, and this
    /// app itself — quitting ourselves through the process list would look like
    /// a crash.
    static func isProtected(_ pid: pid_t) -> Bool {
        pid <= 1 || pid == getpid()
    }

    public static func terminate(pid: pid_t, force: Bool = false) throws {
        guard !isProtected(pid) else { throw Failure.refusedProtectedProcess }
        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
            switch errno {
            case EPERM: throw Failure.notPermitted
            case ESRCH: throw Failure.alreadyGone
            default: throw Failure.notPermitted
            }
        }
    }

    /// Whether the process is still around, so the interface can offer to force
    /// it only when asking nicely did not work.
    public static func isRunning(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 performs the permission checks without sending anything.
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
