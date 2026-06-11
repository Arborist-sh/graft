import Foundation

/// A runner the supervisor currently has in flight.
public struct RunnerRecord: Codable, Sendable, Equatable {
    public let vm: RunningVM
    public let pool: String
    public let startedAt: Date

    public init(vm: RunningVM, pool: String, startedAt: Date) {
        self.vm = vm
        self.pool = pool
        self.startedAt = startedAt
    }
}

/// Live status of one runner slot, for out-of-process status UIs (the menu-bar app,
/// `graft status`). Persisted alongside `runners` so the daemon's per-slot phase is
/// visible even with no live dashboard. `phaseKind` is a stable key for icon/colour;
/// `phaseLabel` is the human string.
public struct SlotStatus: Codable, Sendable, Equatable, Identifiable {
    public let tag: String          // e.g. "mac#0"
    public let pool: String
    public var vmName: String?
    public var ip: String?
    public var phaseLabel: String   // "running job: build-and-test"
    public var phaseKind: String    // "busy"
    public var since: Date

    public var id: String { tag }

    public init(
        tag: String, pool: String, vmName: String? = nil, ip: String? = nil,
        phaseLabel: String, phaseKind: String, since: Date
    ) {
        self.tag = tag
        self.pool = pool
        self.vmName = vmName
        self.ip = ip
        self.phaseLabel = phaseLabel
        self.phaseKind = phaseKind
        self.since = since
    }
}

/// A snapshot of what the supervisor believes is running. Persisted so a restart
/// (or crash) can reconcile against reality instead of leaking VMs.
public struct PoolState: Codable, Sendable {
    public var runners: [RunnerRecord]
    public var slots: [SlotStatus]
    public var updatedAt: Date

    public init(runners: [RunnerRecord] = [], slots: [SlotStatus] = [], updatedAt: Date = Date()) {
        self.runners = runners
        self.slots = slots
        self.updatedAt = updatedAt
    }

    // Tolerate older state files (and forward-compat) by defaulting any missing key.
    enum CodingKeys: String, CodingKey { case runners, slots, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runners = try c.decodeIfPresent([RunnerRecord].self, forKey: .runners) ?? []
        slots = try c.decodeIfPresent([SlotStatus].self, forKey: .slots) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Crash-safe persistence of `PoolState` to `~/.graft/state/pool.json`. Writes are
/// atomic (temp + rename), so a `kill -9` mid-write can't corrupt the file.
public struct StateManager: Sendable {
    public let fileURL: URL

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".graft/state")
    }

    public init(directory: URL? = nil) {
        self.fileURL = (directory ?? Self.defaultDirectory).appendingPathComponent("pool.json")
    }

    /// Last persisted state, or nil if absent/unreadable (treated as empty).
    public func load() -> PoolState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(PoolState.self, from: data)
    }

    public func save(_ state: PoolState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
