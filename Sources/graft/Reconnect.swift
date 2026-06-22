import ArgumentParser
import Darwin
import Dispatch
import Foundation
import GraftCore

/// Self-contained reconnect for `graft arborist tend` (GFT-33).
///
/// The supervisor externalizes its per-slot phase to `~/.graft/state/pool.json` and its
/// liveness to the pidfile, so a *second* graft invocation can both detect a running
/// supervisor and render a faithful, read-only view of it — no IPC, no launchd. This file
/// holds the three pieces that build on that: the collision prompt, the poll-driven
/// viewer, and the detached-engine spawn that lets `tend` background itself.

// MARK: - Collision resolution

/// What to do when `graft arborist tend` finds a supervisor already running.
enum TendCollision {
    case reconnect   // attach a live read-only view
    case killAndStart // stop the running one, then start fresh
    case cancel      // do nothing
}

enum Reconnect {
    /// Prompt the user about an already-running supervisor. Non-interactive callers
    /// (`--daemon`, piped stdin) can't answer a prompt, so they get a clear error instead
    /// of silently double-supervising (which would corrupt the shared `pool.json`).
    static func resolveCollision(pid: Int32, interactive: Bool) throws -> TendCollision {
        let summary = runningSummary(pid: pid)
        guard interactive else {
            throw GraftError("""
                graft is already tending (\(summary)).
                  • reconnect a live view:  graft arborist attach
                  • stop it:                graft stop
                """)
        }
        printErr("graft is already tending (\(summary)).")
        printErr("  [r] reconnect — attach a live, read-only view")
        printErr("  [k] kill      — stop it, then start fresh")
        printErr("  [c] cancel    — leave it running (default)")
        while true {
            FileHandle.standardError.write(Data("choose [r/k/c]: ".utf8))
            guard let line = readLine() else { return .cancel }
            switch line.trimmingCharacters(in: .whitespaces).lowercased() {
            case "r", "reconnect":   return .reconnect
            case "k", "kill":        return .killAndStart
            case "c", "cancel", "":  return .cancel
            default:                 printErr("  not a choice — r, k, or c")
            }
        }
    }

    /// SIGTERM the running supervisor and wait (up to ~10s) for it to clear its pidfile,
    /// so a follow-on start doesn't collide with the one shutting down.
    static func killAndWait(pid: Int32) async throws {
        guard kill(pid, SIGTERM) == 0 else { throw GraftError("failed to signal pid \(pid)") }
        printErr("sent SIGTERM to graft (pid \(pid)) — waiting for shutdown…")
        for _ in 0..<100 {
            if Daemon.runningPID() == nil { printErr("stopped."); return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw GraftError("supervisor (pid \(pid)) didn't exit in time — check `graft status` and retry")
    }

    private static func runningSummary(pid: Int32) -> String {
        let runners = StateManager().load()?.runners ?? []
        return runners.isEmpty ? "pid \(pid)" : "pid \(pid), \(runners.count) runner(s)"
    }

    // MARK: - Read-only viewer

    /// Attach a live, read-only dashboard to the running supervisor by polling `pool.json`.
    /// Renders identically to the live tend dashboard (at poll latency). Ctrl-C detaches
    /// the *viewer* only — the supervisor keeps running. Returns when the user detaches or
    /// the supervisor exits.
    static func runViewer(specs: [LiveDashboard.PoolSpec], pollInterval: Duration = .seconds(1)) async {
        let dashboard = LiveDashboard()
        dashboard.configure(pools: specs)
        dashboard.start()
        defer { dashboard.stop() }

        // Trap Ctrl-C just for the viewer: SIG_IGN so the dispatch source sees it, restored
        // on the way out. We never touch the supervisor — detaching is purely local.
        let detached = AtomicFlag()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { detached.set() }
        source.resume()
        defer { source.cancel(); signal(SIGINT, SIG_DFL) }

        let state = StateManager()
        var supervisorGone = false
        while !detached.isSet {
            if let snapshot = state.load() { dashboard.apply(slots: snapshot.slots) }
            if Daemon.runningPID() == nil { supervisorGone = true; break }
            // Sleep in small slices so Ctrl-C feels responsive.
            let slices = max(1, Int(pollInterval.components.seconds * 10))
            for _ in 0..<slices {
                if detached.isSet { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        dashboard.stop()
        if supervisorGone {
            printErr("supervisor exited — nothing left to tend.")
        } else {
            printErr("detached — supervisor still tending (stop it with `graft stop`).")
        }
    }

    /// Pool specs (name + desired count) from a config/profile, best-effort. The viewer
    /// also infers pools from the snapshot itself, so an empty result still renders.
    static func specs(config: String?, profile: String?) -> [LiveDashboard.PoolSpec] {
        guard
            let cfg = try? GraftConfig.load(from: GraftConfig.resolvePath(explicit: config, profile: profile))
        else { return [] }
        return cfg.pools.map { .init(name: $0.name, desired: $0.count) }
    }

    // MARK: - Detached engine spawn (Stage 2)

    /// Spawn `graft arborist tend --daemon …` as a detached background process — its own
    /// session (so closing the launching terminal doesn't SIGHUP it), stdio redirected to
    /// `~/.graft/logs/supervisor.log`. Returns once the engine has written its pidfile (so
    /// the caller can attach), or throws if it dies first / never comes up.
    static func startDetachedEngine(passthrough: [String]) async throws -> Int32 {
        let logURL = BootLog.directory.appendingPathComponent("supervisor.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let child = try DetachedSpawn.spawn(
            arguments: ["arborist", "tend", "--daemon"] + passthrough,
            logURL: logURL)

        // Wait for the engine to come up: it writes the pidfile once it starts supervising.
        // Catch an early death (bad config, auth failure) fast via waitpid.
        for _ in 0..<150 {   // up to ~15s (image pre-pull can be slow on a cold cache)
            var status: Int32 = 0
            if waitpid(child, &status, WNOHANG) == child {
                throw GraftError("supervisor exited on startup — see \(logURL.path)")
            }
            if let pid = Daemon.runningPID() { return pid }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw GraftError("supervisor didn't come up in time — see \(logURL.path)")
    }
}

/// Spawn a detached child process via `posix_spawn` with its own session and redirected
/// stdio. Kept separate from `Reconnect` so the C-interop noise is contained.
enum DetachedSpawn {
    static func spawn(arguments: [String], logURL: URL) throws -> pid_t {
        let exe = executablePath()

        let logFd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard logFd >= 0 else { throw GraftError("cannot open log \(logURL.path)") }
        defer { close(logFd) }
        let nullFd = open("/dev/null", O_RDONLY)
        defer { if nullFd >= 0 { close(nullFd) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if nullFd >= 0 { posix_spawn_file_actions_adddup2(&actions, nullFd, 0) }
        posix_spawn_file_actions_adddup2(&actions, logFd, 1)
        posix_spawn_file_actions_adddup2(&actions, logFd, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session: detaches from the controlling terminal so a closing shell's SIGHUP
        // (sent to the foreground process group) never reaches the engine.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let argv = [exe] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        defer { for arg in cArgs where arg != nil { free(arg) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, cArgs, environ)
        guard rc == 0 else { throw GraftError("posix_spawn failed (\(rc): \(String(cString: strerror(rc))))") }
        return pid
    }

    /// Absolute path to the running `graft` binary, to re-spawn ourselves.
    private static func executablePath() -> String {
        if let path = Bundle.main.executablePath { return path }
        return CommandLine.arguments.first ?? "graft"
    }
}
