import ArgumentParser
import Foundation
import GraftCore

/// `graft tree …` — inspect the tree: the **trunk** (controller) plus its **branches**
/// (worker Macs) that your **leaves** (runner VMs) grow on. Backend-agnostic — the
/// orchestrator vendor's name lives only in `provider: "orchard"` config, never here.
///
/// Setup happens in `graft init` (pick the Orchard backend); these commands operate the
/// tree it points at. (`plant`/`branch`/`prune` for trunk+worker lifecycle land next.)
struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Inspect the tree — trunk, branches, and leaves.",
        subcommands: [Status.self, Branches.self, Leaves.self]
    )
}

// MARK: - Shared

extension Tree {
    /// Default trunk data dir + where we stash the one-time bootstrap-admin token the
    /// controller prints on first run, so `branch`/`prune` can authenticate later.
    static var dataDir: String { (NSHomeDirectory() as NSString).appendingPathComponent(".orchard/controller") }
    static var adminTokenFile: String { (NSHomeDirectory() as NSString).appendingPathComponent(".orchard/admin-token.txt") }
    static let workerAccount = "graft-workers"

    /// Fail early with an install hint if the `orchard` CLI isn't on PATH.
    static func requireOrchard() async throws {
        guard let r = try? await Shell.run("orchard", ["--version"]), r.succeeded else {
            throw GraftError("`orchard` not found on PATH — install it with `brew install cirruslabs/cli/orchard`")
        }
    }

    /// Strip ANSI escape codes from a line (the controller colorizes its startup banner).
    static func stripANSI(_ s: String) -> String {
        var out = "", inEscape = false
        for ch in s {
            if inEscape {
                if ch.isLetter { inEscape = false }   // CSI sequence ends at a letter
            } else if ch == "\u{1B}" {
                inEscape = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Admin auth env for a trunk, from the stored bootstrap-admin token. Throws with a
    /// clear hint when it's missing (you planted elsewhere, or need admin yourself).
    static func adminEnv(url: String) throws -> [String: String] {
        guard let token = try? String(contentsOfFile: adminTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw GraftError("no admin token at \(adminTokenFile) — plant the trunk here first (`graft tree plant`), or pass a bootstrap token explicitly")
        }
        var env = ProcessInfo.processInfo.environment
        env[OrchardEnv.url] = url
        env[OrchardEnv.accountName] = "bootstrap-admin"
        env[OrchardEnv.accountToken] = token
        return env
    }

    /// Build an `OrchardProvider` from a profile's orchard block, resolving the token
    /// from the Keychain when it isn't inline (same order as `graft run`).
    static func provider(profile: String?) throws -> OrchardProvider {
        let name = try resolveProfileName(profile)
        let cfg = try Profiles.load(name)
        guard var orchard = cfg.orchard else {
            throw GraftError("profile '\(name)' has no tree configured — run `graft init` and choose the Orchard backend")
        }
        if (orchard.token ?? "").isEmpty {
            let scope = KeychainScope(rawValue: cfg.secrets?.scope ?? "login") ?? .login
            orchard.token = KeychainSecretStore(scope: scope).orchardToken(account: orchard.serviceAccount)
        }
        return OrchardProvider(config: orchard)
    }

    /// Start a detection-only host-vitals monitor alongside a long-running tree process (a
    /// branch worker or the trunk controller). Sink/webhook config comes from the active
    /// profile when there is one, else defaults. Returns the task so the caller cancels it
    /// when the orchard process exits.
    static func startHostMonitor(_ detectors: [any HealthDetector], profile: String? = nil) -> Task<Void, Never> {
        let mon = ((try? resolveProfileName(profile)).flatMap { try? Profiles.load($0) })?.monitor ?? MonitorConfig()
        let reporter = HealthReporter(sinks: HealthMonitorFactory.sinks(monitor: mon))
        let heartbeat = mon.heartbeatSeconds
        let monitor = HealthMonitor(
            detectors: detectors, reporter: reporter,
            interval: .seconds(mon.intervalSeconds),
            heartbeatSeconds: heartbeat > 0 ? TimeInterval(heartbeat) : nil)
        printErr(ANSI.dim("    tending: \(detectors.count) host detectors, \(mon.webhooks.count) webhook(s) — detection-only"))
        return Task { await monitor.run() }
    }
}

// MARK: - graft tree status / branches / leaves

extension Tree {
    /// One-glance tree health: trunk, branch count, free capacity, graft's leaves.
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "canopy", abstract: "Canopy — at-a-glance tree overview (trunk, branches, free capacity).")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        func run() async throws {
            let report = try await Tree.provider(profile: profile).report()
            let paused = report.workers.filter(\.paused).count
            let stale = report.workers.filter(\.isStale).count
            let live = report.workers.count - stale
            var notes: [String] = []
            if stale > 0 { notes.append("\(stale) stale") }
            if paused > 0 { notes.append("\(paused) paused") }
            let branchNotes = notes.isEmpty ? "" : "  (" + notes.joined(separator: ", ") + ")"
            print("trunk:     \(report.controllerURL)")
            print("branches:  \(live)\(stale > 0 ? " live" : "")\(branchNotes)")
            print("capacity:  \(report.totalSlots) slots · \(report.usedVMs) used · \(report.freeSlots) free")
            print("leaves:    \(report.graftVMNames.count)")
        }
    }

    /// Per-branch view with advertised slots, plus the tree's free-slot total.
    struct Branches: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the branches (workers) and their leaf capacity.")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        func run() async throws {
            let report = try await Tree.provider(profile: profile).report()
            guard !report.workers.isEmpty else {
                printErr("no branches yet — graft one on with `graft tree branch <trunk-url>`")
                return
            }
            let width = report.workers.map { $0.name.count }.max() ?? 8
            print("\(pad("BRANCH", width))  PAUSED  LEAVES")
            for w in report.workers {
                let stale = w.isStale ? ANSI.yellow("  ⚠ stale (no heartbeat)") : ""
                print("\(pad(w.name, width))  \(pad(w.paused ? "yes" : "no", 6))  \(w.slots)\(stale)")
            }
            printErr(ANSI.dim("— tree: \(report.freeSlots) free / \(report.totalSlots) slots (\(report.usedVMs) used)"))
        }

        private func pad(_ s: String, _ width: Int) -> String {
            s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
        }
    }

    /// Leaves (VMs) on the tree — graft's by default, the whole cluster with `--all`.
    struct Leaves: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the leaves (VMs) on the tree (graft's by default).")

        @Option(name: .long, help: "Profile to read (default: active profile).")
        var profile: String?

        @Flag(help: "Show every leaf on the cluster, not just graft's.")
        var all = false

        func run() async throws {
            let listing = try await Tree.provider(profile: profile).rawList("vms")
            let lines = listing.split(whereSeparator: \.isNewline).map(String.init)
            guard let header = lines.first else { printErr("no leaves"); return }
            let rows = all
                ? Array(lines.dropFirst())
                : lines.dropFirst().filter { $0.hasPrefix("graft-") }
            guard !rows.isEmpty else {
                printErr(all ? "no leaves" : "no graft leaves (try --all)")
                return
            }
            print(header)
            rows.forEach { print($0) }
        }
    }
}

// MARK: - graft tree plant / branch / prune  (trunk + branch lifecycle)

extension Tree {
    /// PID of an `orchard controller` already running on `dataDir`, if any — an orphan from
    /// a prior `plant`/`bonsai` whose Ctrl-C didn't reach it (GFT-21). Lets us refuse with a
    /// clear message instead of the cryptic Badger "cannot acquire directory lock" error.
    static func runningControllerPID(dataDir: String) async -> Int32? {
        guard let r = try? await Shell.run("pgrep", ["-f", "orchard controller.*--data-dir \(dataDir)"]),
              r.succeeded else { return nil }
        return r.stdoutTrimmed.split(whereSeparator: \.isNewline).first.flatMap { Int32($0) }
    }

    /// Stop a local orchard worker by its `--name`. The bonsai branch worker is spawned
    /// after the signal trap is installed, so it inherits our `SIG_IGN` and can ignore a
    /// polite SIGTERM — escalate to SIGKILL so the bonsai always tears down cleanly.
    static func killWorker(name: String) async {
        _ = try? await Shell.run("pkill", ["-TERM", "-f", "orchard worker run.*--name \(name)"])
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? await Shell.run("pkill", ["-KILL", "-f", "orchard worker run.*--name \(name)"])
    }

    /// On branch shutdown, sweep the leaves this worker booted. Orchard does **not** reap its
    /// tart VMs when the worker exits — it leaves them **running** and stranded on the host
    /// (design §3), which is why a bare Ctrl-C leaks VMs. These are `orchard-graft-*` tart VMs.
    /// Stopping a running leaf aborts whatever job it's mid-flight on — the accepted
    /// worker-bounce behavior (§0.7); a `--drain` that waits for jobs to finish is future work.
    static func sweepBranchLeaves() async {
        guard let vms = try? await Tart.list() else { return }
        let leaves = vms.filter { $0.name.hasPrefix("orchard-graft-") }
        guard !leaves.isEmpty else { return }
        printErr(ANSI.dim("    sweeping \(leaves.count) leaf VM(s) the branch booted…"))
        for vm in leaves {
            try? await Tart.stop(name: vm.name)
            try? await Tart.delete(name: vm.name)
        }
        printErr(ANSI.green("    leaves swept."))
    }

    /// On a *deliberate* branch drop (Ctrl-C), proactively deregister the worker from the
    /// trunk so the tree reflects the loss **immediately** — instead of the controller waiting
    /// out the ~120–180s heartbeat-stale window before it stops counting the dead branch's
    /// slots (we know this isn't a blip). Best-effort: needs the admin token (present when this
    /// host can authenticate as admin, e.g. the trunk host); otherwise we fall back to the
    /// stale window. Stop the worker process *before* calling this so it can't re-register.
    static func deregisterBranch(name: String, url: String) async {
        guard let env = try? adminEnv(url: url) else {
            printErr(ANSI.dim("    (no admin token here — the trunk will drop this branch after the stale window)"))
            return
        }
        if (try? await Shell.run("orchard", ["delete", "worker", name], environment: env, timeout: .seconds(15)))?.succeeded == true {
            printErr(ANSI.dim("    deregistered branch '\(name)' from the trunk — capacity freed now."))
        }
    }

    /// Error for "a trunk is already running here" — names the PID and how to clear it.
    static func trunkAlreadyRunning(pid: Int32) -> GraftError {
        GraftError("a trunk is already running here (pid \(pid)) — it holds the controller's database lock.\n" +
            "    Reuse it, or stop it first:  kill \(pid)   (or: pkill -f 'orchard controller')")
    }

    /// Run the controller in the foreground, echoing its logs (optionally prefixed) and
    /// capturing the one-time bootstrap-admin token so `branch`/`prune` can authenticate.
    /// Shared by `plant` and `bonsai`.
    static func runController(dataDir: String, prefix: String = "") async throws -> Int32 {
        let tokenFile = adminTokenFile
        return try await Shell.runStreaming(
            "orchard",
            ["controller", "run", "--insecure-no-tls", "--insecure-ssh-no-client-auth", "--data-dir", dataDir],
            onLine: { line in
                FileHandle.standardError.write(Data((prefix + line + "\n").utf8))
                let clean = stripANSI(line)
                if let r = clean.range(of: "Service account token:") {
                    let tok = clean[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !tok.isEmpty { try? tok.write(toFile: tokenFile, atomically: true, encoding: .utf8) }
                }
            }
        )
    }

    /// Plant the trunk: run the controller in the foreground. On first run the controller
    /// prints a one-time `bootstrap-admin` token — we capture it so `branch`/`prune` can
    /// authenticate. (HTTP-only for now; TLS is a future option.)
    struct Plant: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Plant the trunk — run the controller (foreground).")

        @Option(name: .long, help: "Controller data directory (state + accounts persist here).")
        var dataDir: String = Tree.dataDir

        @Flag(name: .long, help: "Also report this trunk's host vitals + controller-responding health to the webhook/logs.")
        var monitor = false

        func run() async throws {
            try await Tree.requireOrchard()
            // Refuse cleanly if a trunk is already running here (GFT-21) — otherwise the
            // controller collides on the Badger DB lock with an inscrutable error.
            if let pid = await Tree.runningControllerPID(dataDir: dataDir) {
                throw Tree.trunkAlreadyRunning(pid: pid)
            }
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

            // Optional controller-host monitor: disk/memory + is the controller answering?
            let monitorTask: Task<Void, Never>? = monitor ? Tree.startHostMonitor(
                HealthMonitorFactory.controllerDetectors(name: ProcessInfo.processInfo.hostName, responding: {
                    // Token is captured a beat after the controller starts — treat "not yet" as healthy.
                    guard let env = try? Tree.adminEnv(url: "http://127.0.0.1:6120") else { return true }
                    return ((try? await Shell.run("orchard", ["list", "workers"], environment: env, timeout: .seconds(10)))?.succeeded) ?? false
                })) : nil
            defer { monitorTask?.cancel() }

            printErr(ANSI.green("🕳  digging a hole…"))
            printErr(ANSI.green("🌱  planting the trunk…") + ANSI.dim("   (Ctrl-C to stop)"))
            printErr(ANSI.dim("    data: \(dataDir)\n"))

            // Run the controller in its own task; trap Ctrl-C to tear it down so it can't be
            // orphaned (GFT-21). Install the trap *after* the controller has exec'd, so it
            // inherits the default SIGTERM disposition (not our SIG_IGN) and stops cleanly.
            let controller = Task { try await Tree.runController(dataDir: dataDir) }
            try? await Task.sleep(for: .milliseconds(250))
            let stopped = AtomicFlag()
            let sources = SignalTrap.install {
                printErr("\n" + ANSI.green("🪓  uprooting the trunk…"))
                stopped.set()
                controller.cancel()
            }
            defer { sources.forEach { $0.cancel() } }

            let code = try await controller.value
            if code != 0 && !stopped.isSet { throw ExitCode(code) }
        }
    }

    /// Grow a bonsai — a complete tiny tree (trunk + one branch) on THIS machine, for local
    /// testing. Separate orchard processes (not the wedge-prone fused `orchard dev`): the
    /// trunk foreground, a branch grafted on in the background once the trunk is up. Ctrl-C
    /// stops both. A bonsai is a quick sandbox, not a role — so it isn't tended; to monitor a
    /// local setup, run `graft tree plant --tend` and `graft tree branch --tend` separately.
    struct Bonsai: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Grow a bonsai — a whole tiny tree (trunk + branch) on this machine, for local testing.")

        @Option(name: .long, help: "Controller data directory (state + accounts persist here).")
        var dataDir: String = Tree.dataDir

        func run() async throws {
            try await Tree.requireOrchard()
            // Refuse cleanly if a trunk is already running here (GFT-21).
            if let pid = await Tree.runningControllerPID(dataDir: dataDir) {
                throw Tree.trunkAlreadyRunning(pid: pid)
            }
            try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

            printErr(ANSI.green("🪴  potting a bonsai — a local trunk + branch…") + ANSI.dim("   (Ctrl-C to stop)\n"))
            let url = "http://127.0.0.1:6120"
            let tokenFile = Tree.adminTokenFile

            // Once the trunk is listening + the admin token is captured, graft a branch on.
            let branch = Task {
                for _ in 0..<90 where (try? String(contentsOfFile: tokenFile))?.isEmpty != false {
                    try? await Task.sleep(for: .seconds(1))
                }
                try? await Task.sleep(for: .seconds(1))
                do {
                    let boot = try await Tree.mintBootstrapToken(url: url)
                    printErr(ANSI.green("🌿  grafting a branch on…\n"))
                    _ = try await Shell.runStreaming(
                        "orchard", ["worker", "run", url, "--bootstrap-token", boot, "--name", "bonsai"],
                        onLine: { line in FileHandle.standardError.write(Data(("[branch] " + line + "\n").utf8)) }
                    )
                } catch is CancellationError {
                } catch {
                    printErr(ANSI.yellow("  branch failed: \(error)"))
                }
            }
            defer { branch.cancel() }

            printErr(ANSI.green("🕳  digging a hole… 🌱 planting the trunk…\n"))

            // Run the controller in its own task and trap Ctrl-C to tear the whole bonsai
            // down — neither the trunk nor the branch should be left orphaned (GFT-21).
            let controller = Task { try await Tree.runController(dataDir: dataDir, prefix: "[trunk] ") }
            try? await Task.sleep(for: .milliseconds(250))
            let stopped = AtomicFlag()
            let sources = SignalTrap.install {
                printErr("\n" + ANSI.green("🪓  uprooting the bonsai…"))
                stopped.set()
                controller.cancel()
                branch.cancel()
            }
            defer { sources.forEach { $0.cancel() } }

            let code = try await controller.value
            branch.cancel()
            // The branch worker spawned after the trap → may ignore SIGTERM; force it down,
            // then sweep the leaves it booted (Orchard leaves them running — design §3).
            await Tree.killWorker(name: "bonsai")
            await Tree.sweepBranchLeaves()
            if code != 0 && !stopped.isSet { throw ExitCode(code) }
        }
    }

    /// Graft a branch on: run a worker on THIS Mac that joins the tree. Mints a bootstrap
    /// token from the trunk (needs you to have planted it here) unless one is passed.
    struct Branch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Graft a branch on — run a worker that joins the tree.")

        @Argument(help: "Trunk (controller) URL to join, e.g. http://trunk.local:6120")
        var url: String

        @Option(name: .long, help: "Bootstrap token (default: mint one — needs the trunk planted here).")
        var token: String?

        @Option(name: .long, help: "Branch (worker) name (default: this host's name).")
        var name: String?

        @Option(name: .long, help: "Labels, comma-separated key=value (e.g. hardware=m4max).")
        var labels: String?

        @Option(name: .long, help: "Reserve N GB of host RAM: advertise (total − N) to the scheduler so leaves can't OOM the host.")
        var reserve: Int?

        @Option(name: .long, help: "How many leaves this branch can hold (org.cirruslabs.tart-vms). Default: the host's auto-detected ceiling (2 on macOS). Use --leaves 1 per branch if running two branches on one Mac.")
        var leaves: Int?

        @Flag(name: .long, help: "Also report this branch's host vitals (disk/memory/tart) to the webhook/logs.")
        var monitor = false

        func run() async throws {
            try await Tree.requireOrchard()
            printErr(ANSI.green("🌿  grafting a branch onto \(url)…"))
            let boot: String
            if let token { boot = token } else { boot = try await Tree.mintBootstrapToken(url: url) }
            // Resolve the worker name deterministically (defaults to the hostname) and always
            // pass it, so the name we monitor + deregister under matches what's registered.
            let workerName = name ?? ProcessInfo.processInfo.hostName
            var args = ["worker", "run", url, "--bootstrap-token", boot, "--name", workerName]
            if let labels {
                for kv in labels.split(separator: ",") { args += ["--labels", kv.trimmingCharacters(in: .whitespaces)] }
            }
            let resourceArgs = OrchardProvider.workerResourceArgs(
                leaves: leaves, reserve: reserve,
                totalMB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)),
                cores: ProcessInfo.processInfo.activeProcessorCount)
            args += resourceArgs
            if !resourceArgs.isEmpty {
                let reserveNote = reserve.map { " · reserving \($0) GB" } ?? ""
                printErr(ANSI.dim("    advertising \(leaves ?? 2) leaf slot(s)\(reserveNote)"))
            }
            let monitorTask: Task<Void, Never>? = monitor
                ? Tree.startHostMonitor(HealthMonitorFactory.branchDetectors(name: workerName))
                : nil
            defer { monitorTask?.cancel() }

            printErr(ANSI.dim("    branch live — Ctrl-C to drop it.\n"))

            // Run the worker in its own task and trap Ctrl-C so we SIGTERM it AND sweep the
            // leaves it booted — Orchard leaves its tart VMs running on worker exit, so without
            // this a Ctrl-C strands them on the host. Trap installed after the worker execs so
            // it keeps the default SIGTERM disposition (not graft's SIG_IGN) — see SignalTrap.
            let worker = Task {
                try await Shell.runStreaming("orchard", args, onLine: { line in
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                })
            }
            try? await Task.sleep(for: .milliseconds(250))
            let stopped = AtomicFlag()
            let sources = SignalTrap.install {
                printErr("\n" + ANSI.green("🪓  dropping the branch…"))
                stopped.set()
                worker.cancel()
            }
            defer { sources.forEach { $0.cancel() } }

            let code = try await worker.value
            // On a user-initiated drop: tell the trunk we're gone (immediate capacity drop, no
            // stale-window wait), then sweep the leaves the worker left stranded.
            if stopped.isSet {
                await Tree.deregisterBranch(name: workerName, url: url)
                await Tree.sweepBranchLeaves()
            }
            if code != 0 && !stopped.isSet { throw ExitCode(code) }
        }
    }

    /// Prune a branch: deregister a worker from the trunk. Needs admin (the stored
    /// bootstrap-admin token from a local `plant`).
    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Prune a branch — remove a worker from the tree.")

        @Argument(help: "Branch (worker) name to remove.")
        var name: String

        @Option(name: .long, help: "Trunk URL (default: the profile's controllerURL).")
        var url: String?

        @Option(name: .long, help: "Profile to read the trunk URL from (default: active).")
        var profile: String?

        func run() async throws {
            try await Tree.requireOrchard()
            let trunk: String
            if let url {
                trunk = url
            } else {
                let profileName = try resolveProfileName(profile)
                guard let u = (try Profiles.load(profileName)).orchard?.controllerURL.absoluteString else {
                    throw GraftError("profile '\(profileName)' has no trunk URL — pass --url")
                }
                trunk = u
            }
            let env = try Tree.adminEnv(url: trunk)
            let result = try await Shell.run("orchard", ["delete", "worker", name], environment: env, timeout: .seconds(20))
            guard result.succeeded else {
                throw GraftError("couldn't prune '\(name)': \(result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed)")
            }
            printErr(ANSI.green("✂️  pruned branch '\(name)'"))
        }
    }

    /// Mint a worker bootstrap token from the trunk (ensures the worker service account
    /// exists first). Uses the stored admin token, so the trunk must have been planted here.
    static func mintBootstrapToken(url: String) async throws -> String {
        let env = try adminEnv(url: url)
        _ = try? await Shell.run("orchard", [
            "create", "service-account", workerAccount,
            "--roles", "compute:read", "--roles", "compute:write", "--roles", "compute:connect",
        ], environment: env, timeout: .seconds(20))
        let result = try await Shell.run("orchard", ["get", "bootstrap-token", workerAccount], environment: env, timeout: .seconds(20))
        guard result.succeeded, !result.stdoutTrimmed.isEmpty else {
            throw GraftError("couldn't mint a bootstrap token: \(result.stderrTrimmed.isEmpty ? result.stdoutTrimmed : result.stderrTrimmed)")
        }
        return result.stdoutTrimmed
    }
}
