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

/// A snapshot of what the supervisor believes is running. Persisted so a restart
/// (or crash) can reconcile against reality instead of leaking VMs.
public struct PoolState: Codable, Sendable {
    public var runners: [RunnerRecord]
    public var updatedAt: Date

    public init(runners: [RunnerRecord] = [], updatedAt: Date = Date()) {
        self.runners = runners
        self.updatedAt = updatedAt
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
