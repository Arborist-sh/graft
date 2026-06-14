import Dispatch
import Foundation

/// Trap SIGINT/SIGTERM and run `handler` instead of the default (which would kill graft
/// instantly, orphaning any child process it was supervising — see GFT-21). Returns the
/// dispatch sources; keep them alive for as long as the trap should be active and
/// `cancel()` them when done.
///
/// Note on ordering: this sets the signals to `SIG_IGN` so the dispatch sources can
/// observe them. `SIG_IGN` is **inherited across exec**, so any child spawned *after* this
/// is installed would also ignore SIGINT/SIGTERM (and then couldn't be stopped with a
/// terminate()). Install the trap only *after* the child you mean to manage has launched,
/// so it execs with the default dispositions.
enum SignalTrap {
    static func install(_ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}

/// A tiny thread-safe boolean — set from a signal handler, read from the awaiting task —
/// so we can tell a user-initiated stop (don't report an error) from a real crash.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
