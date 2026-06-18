import ArgumentParser
import Dispatch
import Foundation

/// Run `operation` so that Ctrl-C (SIGINT) cancels it — which, for anything shelling out
/// via `Shell`, terminates the child subprocess (its cancellation handler calls
/// `terminate()`). Without this, Ctrl-C during e.g. a `tart pull` kills graft but leaves
/// the download running as an orphan.
///
/// Only **SIGINT** is trapped here, and only for the duration of `operation`. We set
/// `SIG_IGN` so graft isn't killed before the handler runs — but deliberately leave SIGTERM
/// alone, so any subprocess spawned inside `operation` still execs with a *default* SIGTERM
/// disposition and our `terminate()` (SIGTERM) actually stops it. (Trapping SIGTERM too
/// would be inherited as `SIG_IGN` across exec and the child would ignore terminate() — see
/// `SignalTrap`.) On interrupt, prints a note and exits 130.
@discardableResult
func withInterruptHandling<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let interrupted = AtomicFlag()
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    defer { source.cancel(); signal(SIGINT, SIG_DFL) }

    let task = Task { try await operation() }
    source.setEventHandler { interrupted.set(); task.cancel() }
    source.resume()

    do {
        return try await task.value
    } catch {
        if interrupted.isSet {
            FileHandle.standardError.write(Data("\n⎋ cancelled — stopped the download\n".utf8))
            throw ExitCode(130)   // 128 + SIGINT, the conventional Ctrl-C status
        }
        throw error
    }
}

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
