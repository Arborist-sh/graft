import Foundation

/// One entry from `tart list --format json`. Tart capitalizes its keys.
public struct TartVM: Sendable, Codable, Equatable {
    public let name: String
    public let state: String
    public let source: String?
    public let size: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case state = "State"
        case source = "Source"
        case size = "Size"
    }

    public var isRunning: Bool { state.lowercased() == "running" }
}

/// Thin async wrappers over the `tart` CLI. No policy here — just one function per
/// `tart` subcommand, plus the IP-polling loop that everything else needs. Policy
/// (capacity tiers, naming, teardown ordering) lives in `LocalTartProvider`.
public enum Tart {
    static let executable = "tart"

    public static func clone(image: String, to name: String) async throws {
        try await Shell.runChecked(executable, ["clone", image, name])
    }

    /// Boot a VM detached so it outlives this process. Returns immediately —
    /// the VM is up but won't have an IP yet; call `waitForIP`. `mounts` become
    /// `--dir` directory shares (single-quoted so paths with spaces are safe).
    public static func run(name: String, mounts: [Mount] = [], network: VMNetwork = .nat) throws {
        var command = "\(executable) run \(name) --no-graphics"
        for flag in network.tartFlags {
            command += " \(flag)"
        }
        for mount in mounts {
            command += " --dir='\(mount.tartDirArg)'"
        }
        // Capture the detached boot's output to a per-VM log so a fast failure (bad image,
        // entitlement/session error, etc.) isn't swallowed — `acquire` reads it back if the
        // VM never gets an IP.
        try Shell.launchDetached(command, logURL: BootLog.url(for: name))
    }

    public static func stop(name: String) async throws {
        // `tart stop` self-limits to ~30s (graceful then force); bound the wrapper a
        // little beyond that so a wedged invocation can't hang teardown.
        try await Shell.runChecked(executable, ["stop", name], timeout: .seconds(45))
    }

    public static func delete(name: String) async throws {
        try await Shell.runChecked(executable, ["delete", name], timeout: .seconds(30))
    }

    /// Apply VM-shape settings to a (stopped) VM/image via `tart set`. Only the provided
    /// fields are changed. Disk can only grow.
    public static func set(
        name: String, cpu: Int? = nil, memory: Int? = nil, diskSize: Int? = nil, display: String? = nil
    ) async throws {
        var args = ["set", name]
        if let cpu { args += ["--cpu", String(cpu)] }
        if let memory { args += ["--memory", String(memory)] }
        if let diskSize { args += ["--disk-size", String(diskSize)] }
        if let display { args += ["--display", display] }
        guard args.count > 2 else { return }
        try await Shell.runChecked(executable, args, timeout: .seconds(60))
    }

    /// Push a local image to an OCI registry ref. No timeout — uploads can take minutes.
    public static func push(name: String, to ref: String) async throws {
        try await Shell.runChecked(executable, ["push", name, ref])
    }

    /// Pull an image from a registry into the local cache, streaming tart's progress to
    /// this process's terminal. No timeout — large pull.
    public static func pull(ref: String) async throws {
        let code = try await Shell.runStreaming(executable, ["pull", ref])
        guard code == 0 else { throw GraftError("`tart pull \(ref)` failed (exit \(code))") }
    }

    /// Whether `ref` is already in the local store (a local VM or a pulled OCI image).
    public static func isCached(_ ref: String) async throws -> Bool {
        try await list().contains { $0.name == ref }
    }

    /// Make `ref` available locally so a later `clone` is instant: if it's a registry
    /// ref (`registry/path:tag`) that isn't cached, pull it with progress. Bare local
    /// names that don't exist are left for `clone` to error on. Returns false if it
    /// couldn't be ensured (not cached and not a registry ref).
    @discardableResult
    public static func ensureAvailable(_ ref: String) async throws -> Bool {
        if try await isCached(ref) { return true }
        guard ref.contains("/") else { return false }   // local names have no "/"
        Log.info("pulling \(ref) (not cached locally)…")
        try await pull(ref: ref)
        return true
    }

    /// Run a command in the guest with the host terminal inherited, returning its exit
    /// code. `interactive` adds `tart exec -i` to forward stdin — needed for a shell,
    /// but it blocks on a non-TTY stdin, so omit it for one-shot commands.
    public static func execInteractive(name: String, command: [String], interactive: Bool = true) throws -> Int32 {
        // Interactive needs BOTH `-i` (attach stdin) and `-t` (allocate a guest PTY) — with
        // `-i` alone the guest shell has no controlling terminal and exits immediately.
        let base = interactive ? ["exec", "-i", "-t", name] : ["exec", name]
        return try Shell.runInteractive(executable, base + command)
    }

    /// Current IP, or nil if the VM has no lease yet (DHCP can take 10–60s). Bounded —
    /// a hung `tart ip` would otherwise wedge the acquire loop forever.
    public static func ip(name: String) async throws -> String? {
        let result = try await Shell.run(executable, ["ip", name], timeout: .seconds(15))
        guard result.succeeded else { return nil }
        let ip = result.stdoutTrimmed
        return ip.isEmpty ? nil : ip
    }

    public static func list() async throws -> [TartVM] {
        let json = try await Shell.runChecked(executable, ["list", "--format", "json"], timeout: .seconds(20))
        guard let data = json.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([TartVM].self, from: data)
    }

    public static func exists(name: String) async throws -> Bool {
        try await list().contains { $0.name == name }
    }

    /// Poll `tart ip` until the VM gets a DHCP lease or we time out. Intentionally
    /// a retry loop, not a fixed sleep — lease timing is unpredictable.
    public static func waitForIP(
        name: String,
        timeout: Duration = .seconds(90),
        pollInterval: Duration = .seconds(2)
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let ip = try await ip(name: name) {
                return ip
            }
            try await Task.sleep(for: pollInterval)
        }
        throw GraftError("timed out after \(timeout) waiting for \(name) to get an IP")
    }
}
