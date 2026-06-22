import ArgumentParser
import Dispatch
import Foundation
import GraftCore

/// `graft run` — start the pool supervisor and keep pools filled until stopped.
struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tend",
        abstract: "Tend the pool — supervise runners until stopped (+ --monitor to report health)."
    )

    @Option(name: .shortAndLong, help: "Config path (overrides profile resolution).")
    var config: String?

    @Option(name: .long, help: "Profile to run (default: active profile).")
    var profile: String?

    @Flag(help: "Daemon mode for launchd. launchd does the supervising — this just notes intent.")
    var daemon = false

    @Flag(name: .long, help: "Supervise in this process (blocking, live dashboard) instead of backgrounding a detached engine.")
    var foreground = false

    @Flag(name: .shortAndLong, help: "Echo every step (runner output + events) above the live status, instead of just the spinner.")
    var verbose = false

    @Flag(help: "Also report health to the configured webhook + logs while tending (the health monitor).")
    var monitor = false

    func run() async throws {
        let interactiveStdin = isatty(STDIN_FILENO) != 0

        // A supervisor is already running: never silently start a second one (they'd fight
        // over the same pidfile + pool.json). Offer to reconnect, kill it, or cancel.
        if let pid = Daemon.runningPID() {
            switch try Reconnect.resolveCollision(pid: pid, interactive: interactiveStdin && !daemon) {
            case .reconnect:
                await Reconnect.runViewer(specs: Reconnect.specs(config: config, profile: profile))
                return
            case .cancel:
                return
            case .killAndStart:
                try await Reconnect.killAndWait(pid: pid)
            }
        }

        // Default (interactive): background a detached engine and attach a live viewer, so
        // the supervisor survives this terminal closing — self-contained, no launchd/nohup.
        // `--daemon` (launchd) and `--foreground` keep supervising in *this* process.
        if !daemon, !foreground, interactiveStdin, isatty(STDOUT_FILENO) != 0 {
            let pid = try await Reconnect.startDetachedEngine(passthrough: passthroughArgs())
            let log = BootLog.directory.appendingPathComponent("supervisor.log").path
            printErr("🌳 tending in the background (pid \(pid)) · logs: \(log)")
            printErr("   attach later: graft arborist attach   ·   stop: graft stop")
            printErr("   attaching now — Ctrl-C detaches the view (it keeps running)…")
            await Reconnect.runViewer(specs: Reconnect.specs(config: config, profile: profile))
            return
        }

        try await superviseInProcess()
    }

    /// Flags worth forwarding to the detached engine (it loads its own config + supervises).
    private func passthroughArgs() -> [String] {
        var args: [String] = []
        if let config { args += ["--config", config] }
        if let profile { args += ["--profile", profile] }
        if monitor { args.append("--monitor") }
        return args
    }

    /// Supervise the pool in *this* process — the live dashboard when interactive, the plain
    /// log stream under `--daemon`. Blocks until stopped. The default `run()` path backgrounds
    /// this via a detached `--daemon` engine; `--foreground` runs it here directly.
    private func superviseInProcess() async throws {
        let path = GraftConfig.resolvePath(explicit: config, profile: profile)
        let cfg = try GraftConfig.load(from: path)

        let problems = cfg.validate()
        guard problems.isEmpty else {
            for problem in problems { printErr("  • \(problem)") }
            throw GraftError("config has \(problems.count) problem(s) — run `graft config validate`")
        }

        // Claim liveness up front — before the (possibly slow) image pre-pull — so `graft
        // status`, `graft stop`, and an attaching viewer see the supervisor immediately.
        try Daemon.writePidfile()
        defer { Daemon.removePidfile() }

        let provider = try Self.makeProvider(cfg)
        // Each pool's App key may live in a different keychain (login vs system), so the
        // scope is resolved per App ID — not assumed to be one keychain for the whole run.
        let scopes = Set(cfg.distinctGitHubConfigs().map(\.scope.rawValue)).sorted().joined(separator: "+")
        // A representative store for the (detection-only) health monitor's GitHub clients.
        let monitorScope = cfg.github?.scope ?? cfg.pools.compactMap { $0.github?.scope }.first ?? .login

        // Local Tart: pull any pool images that aren't cached yet (with progress) before
        // the live UI starts, so the first runner doesn't silently hang on a big download.
        // Orchard workers pull images themselves (image-pull-policy), so skip it there.
        if case .tart = cfg.provider {
            // Ctrl-C during a pre-flight pull cancels it (and the tart child) instead of
            // orphaning the download — the supervisor installs its own trap further down.
            try await withInterruptHandling {
                for image in Set(cfg.pools.map(\.image)).sorted() {
                    try await Tart.ensureAvailable(image)
                }
            }
        }

        // Live spinner dashboard only when we own an interactive terminal; daemon /
        // piped output keeps the plain log stream.
        let dashboard = (!daemon && isatty(STDOUT_FILENO) != 0) ? LiveDashboard() : nil
        // Seed the live block with the tree's fixed shape — every pool, every desired
        // slot — so it renders the full canopy from the first frame, even before a leaf
        // is up (or when the fleet has no capacity at all).
        dashboard?.configure(pools: cfg.pools.map { .init(name: $0.name, desired: $0.count) })
        dashboard?.start()
        if let dashboard {
            // Quiet by default: only warnings/errors print above the spinner. With
            // --verbose, echo every event + runner-output line. Phase parsing runs
            // regardless, so the spinner is fully driven either way.
            let verbose = self.verbose
            Log.sink = { line, isWarn in
                if verbose || isWarn { dashboard.log(line, isWarn: isWarn) }
            }
        }
        defer { Log.sink = nil; dashboard?.stop() }

        let reporter: RunnerStatusReporter? = dashboard.map { (d: LiveDashboard) -> RunnerStatusReporter in
            { tag, vm, phase in d.update(slot: tag, vm: vm, phase: phase) }
        }
        let secrets = cfg.secretStore(scope: monitorScope)
        let supervisor = PoolSupervisor(
            config: cfg,
            provider: provider,
            github: { appID in
                GitHubAppClient(appID: appID, secrets: cfg.secretStore(scope: cfg.scope(forAppID: appID)))
            },
            status: reporter
        )

        // Optional in-process health monitor (detection-only). Co-located with the trunk
        // by construction, so it shares the supervisor's state file and is unambiguously
        // the trunk for the state-backed detectors (wedged-slot, deadwood).
        func startMonitorIfRequested() -> Task<Void, Never>? {
            guard monitor else { return nil }
            let detectors = HealthMonitorFactory.detectors(
                config: cfg, provider: provider, secrets: secrets, isTrunk: true)
            let reporter = HealthReporter(sinks: HealthMonitorFactory.sinks(monitor: cfg.monitor))
            let heartbeatSeconds = cfg.monitor?.heartbeatSeconds ?? 300
            let monitor = HealthMonitor(
                detectors: detectors, reporter: reporter,
                interval: .seconds(cfg.monitor?.intervalSeconds ?? 60),
                heartbeatSeconds: heartbeatSeconds > 0 ? TimeInterval(heartbeatSeconds) : nil)
            Log.info("tending in-process — \(detectors.count) detectors, \(cfg.monitor?.webhooks.count ?? 0) webhook(s)")
            return Task { await monitor.run() }
        }

        Log.info("graft starting — \(cfg.pools.count) pool(s), \(scopes.isEmpty ? "login" : scopes) keychain\(daemon ? ", daemon" : "")")
        let task = Task { await supervisor.run() }
        let monitorTask = startMonitorIfRequested()
        let sources = SignalTrap.install {
            Log.info("signal received — shutting down gracefully")
            task.cancel()
            monitorTask?.cancel()
        }
        defer { sources.forEach { $0.cancel() } }
        await task.value
        monitorTask?.cancel()
        _ = await monitorTask?.value
    }

    /// Pick the VM backend from config: local Tart (single host) or an Orchard
    /// controller (multi-host fleet). `validate()` has already checked that an
    /// `orchard` block is present when the provider is "orchard".
    static func makeProvider(_ cfg: GraftConfig) throws -> any VMProvider {
        switch cfg.provider {
        case .tart:
            return LocalTartProvider()
        case .orchard(var orchard):
            // Token resolution: explicit config value wins; otherwise pull it from the
            // Keychain (where `graft init` stashes it) so it's not in plaintext.
            // Left empty for an unsecured local trunk, which ignores auth.
            if (orchard.token ?? "").isEmpty {
                orchard.token = KeychainSecretStore(scope: orchard.scope).orchardToken(account: orchard.serviceAccount)
            }
            return OrchardProvider(config: orchard)
        }
    }
}

/// `graft status` — daemon liveness + the current runner snapshot.
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show supervisor and runner state."
    )

    func run() throws {
        if let pid = Daemon.runningPID() {
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
        guard let pid = Daemon.runningPID() else {
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

private func age(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
}

