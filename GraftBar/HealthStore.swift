import Combine
import Foundation
import GraftCore

/// Reads the health monitor's on-disk output and republishes it for the Sapflow section:
///
/// * `~/.graft/state/health.json`  — the live snapshot of *active* problems (warn/critical,
///   upserted as they appear, cleared on recovery). The "what's wrong right now" board.
/// * `~/.graft/logs/health.jsonl`  — the append-only event timeline (everything, including
///   recoveries + heartbeats). The "what just happened" feed.
///
/// Reads the files directly — no CLI shell — so it works regardless of which `graft` binary
/// is installed (sidesteps the stale-brew landmine the other sections hit). Cross-host
/// aggregation is a future epic; this is the local view.
@MainActor
final class HealthStore: ObservableObject {
    /// Active warn/critical problems, critical-first then by stable key.
    @Published var problems: [HealthEvent] = []
    /// Recent events, newest-first (capped at `feedLimit`).
    @Published var feed: [HealthEvent] = []
    /// Newest timestamp seen across snapshot + feed — the "as of" time shown in the header.
    @Published var lastEventAt: Date?

    private var timer: Timer?
    private let feedLimit = 200
    /// Only ever read the tail of the (append-only, unbounded) log — keeps the 3s poll cheap
    /// no matter how large health.jsonl grows.
    private let tailBytes = 256 * 1024

    static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".graft/state/health.json")
    }
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".graft/logs/health.jsonl")
    }

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit { timer?.invalidate() }

    func reload() {
        loadSnapshot()
        loadFeed()
    }

    // MARK: Snapshot (active problems)

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snap = try? HealthEvent.decoder.decode(SnapshotSink.Snapshot.self, from: data)
        else {
            problems = []
            return
        }
        problems = snap.problems.sorted {
            $0.severity.rank != $1.severity.rank
                ? $0.severity.rank > $1.severity.rank   // critical before warn
                : $0.key < $1.key
        }
        bump(snap.updatedAt)
    }

    // MARK: Feed (event timeline)

    private func loadFeed() {
        guard let text = Self.tail(of: Self.logURL, maxBytes: tailBytes) else {
            feed = []
            return
        }
        let lines = text.split(separator: "\n").suffix(feedLimit)
        var events: [HealthEvent] = []
        events.reserveCapacity(lines.count)
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let event = try? HealthEvent.decoder.decode(HealthEvent.self, from: data)
            else { continue }   // a partial last line mid-write decodes to nil; skip it
            events.append(event)
        }
        if let newest = events.last?.timestamp { bump(newest) }
        feed = events.reversed()   // newest first
    }

    private func bump(_ date: Date) {
        lastEventAt = lastEventAt.map { max($0, date) } ?? date
    }

    /// Read at most the last `maxBytes` of a file, dropping a leading partial line so every
    /// returned line is whole. Returns nil if the file can't be opened.
    private static func tail(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var str = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = str.firstIndex(of: "\n") {
            str = String(str[str.index(after: nl)...])
        }
        return str
    }
}
