import ArgumentParser
import Dispatch
import Foundation
import GraftCore

/// `graft run` — start the pool supervisor and keep pools filled until stopped.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start the pool supervisor (runs until stopped)."
    )

    @Option(name: .shortAndLong, help: "Config path (default: $GRAFT_CONFIG or ~/.graft/config.json).")
    var config: String?

    @Flag(help: "Daemon mode for launchd. launchd does the supervising — this just notes intent.")
    var daemon = false

    @Option(name: .long, help: "Use an Orchard controller instead of local Tart (not yet implemented).")
    var orchardURL: String?

    func run() async throws {
        let path = GraftConfig.resolvePath(explicit: config)
        let cfg = try GraftConfig.load(from: path)

        let problems = cfg.validate()
        guard problems.isEmpty else {
            for problem in problems { printErr("  • \(problem)") }
            throw GraftError("config has \(problems.count) problem(s) — run `graft config validate`")
        }
        guard orchardURL == nil, cfg.provider == "tart" else {
            throw GraftError("only the local Tart provider is implemented; Orchard is planned")
        }

        let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
        let supervisor = PoolSupervisor(
            config: cfg,
            provider: LocalTartProvider(),
            secrets: KeychainSecretStore(scope: scope)
        )

        try writePidfile()
        defer { removePidfile() }

        Log.info("graft starting — \(cfg.pools.count) pool(s), \(scope.rawValue) keychain\(daemon ? ", daemon" : "")")
        let task = Task { await supervisor.run() }
        let sources = installSignalHandlers {
            Log.info("signal received — shutting down gracefully")
            task.cancel()
        }
        defer { sources.forEach { $0.cancel() } }
        await task.value
    }
}

/// `graft status` — daemon liveness + the current runner snapshot.
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show supervisor and runner state."
    )

    func run() throws {
        if let pid = readPid(), isAlive(pid) {
            print("daemon:  running (pid \(pid))")
        } else {
            print("daemon:  not running")
        }

        let runners = StateManager().load()?.runners ?? []
        guard !runners.isEmpty else {
            print("runners: none")
            return
        }
        print("runners: \(runners.count)")
        for record in runners.sorted(by: { $0.pool < $1.pool }) {
            print("  \(record.pool)\t\(record.vm.name)\t\(record.vm.ip)\t\(record.vm.os.rawValue)\tup \(age(record.startedAt))")
        }
    }
}

/// `graft stop` — signal a running supervisor to shut down gracefully.
struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Gracefully stop a running supervisor."
    )

    func run() throws {
        guard let pid = readPid(), isAlive(pid) else {
            printErr("graft is not running")
            return
        }
        guard kill(pid, SIGTERM) == 0 else {
            throw GraftError("failed to signal pid \(pid)")
        }
        printErr("sent SIGTERM to graft (pid \(pid))")
    }
}

// MARK: - Runtime helpers

private func pidfileURL() -> URL {
    StateManager.defaultDirectory.appendingPathComponent("graft.pid")
}

private func writePidfile() throws {
    try FileManager.default.createDirectory(
        at: StateManager.defaultDirectory,
        withIntermediateDirectories: true
    )
    try String(getpid()).write(to: pidfileURL(), atomically: true, encoding: .utf8)
}

private func removePidfile() {
    try? FileManager.default.removeItem(at: pidfileURL())
}

private func readPid() -> Int32? {
    guard let contents = try? String(contentsOf: pidfileURL(), encoding: .utf8) else { return nil }
    return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

private func age(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
}

/// Trap SIGINT/SIGTERM and invoke `handler`. Returns the sources to keep alive.
private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}
