import Foundation

/// Provisioning status for a nest (dev box), written by `graft nest` as it works and read
/// by the GUI. Tart's own state only says running/stopped — it flips to "running" the moment
/// the VM boots, long before the repo is cloned and the box is actually usable. This fills
/// that gap: the GUI can show "cloning…" vs. "ready" instead of a misleading instant
/// "running". Stored as one small JSON file per box under `~/.graft/nests/`.
public struct NestStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case creating      // cloning the base image
        case booting       // VM starting / waiting for the guest
        case provisioning  // SSH setup + cloning the repo
        case ready         // usable
        case failed        // setup errored
    }

    public var phase: Phase
    public var detail: String
    public var updatedAt: Date

    public init(phase: Phase, detail: String, updatedAt: Date = Date()) {
        self.phase = phase
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

/// Where nest status files live, and the read/write/clear around them. Best-effort: a failed
/// write never breaks the nest flow, and a missing/unreadable file just means "no status yet"
/// (the GUI falls back to Tart's state).
public enum NestStatusStore {
    public static var directory: URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".graft/nests"))
    }

    private static func file(_ vmName: String) -> URL {
        directory.appendingPathComponent("\(vmName).json")
    }

    public static func write(_ status: NestStatus, for vmName: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: file(vmName))
    }

    public static func read(_ vmName: String) -> NestStatus? {
        guard let data = try? Data(contentsOf: file(vmName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NestStatus.self, from: data)
    }

    public static func clear(_ vmName: String) {
        try? FileManager.default.removeItem(at: file(vmName))
    }
}
