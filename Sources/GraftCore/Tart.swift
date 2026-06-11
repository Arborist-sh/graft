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
    /// the VM is up but won't have an IP yet; call `waitForIP`.
    public static func run(name: String) throws {
        try Shell.launchDetached("\(executable) run \(name) --no-graphics")
    }

    public static func stop(name: String) async throws {
        // `tart stop` self-limits to ~30s (graceful then force); bound the wrapper a
        // little beyond that so a wedged invocation can't hang teardown.
        try await Shell.runChecked(executable, ["stop", name], timeout: .seconds(45))
    }

    public static func delete(name: String) async throws {
        try await Shell.runChecked(executable, ["delete", name], timeout: .seconds(30))
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
