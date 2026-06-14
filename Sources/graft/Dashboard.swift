import Foundation
import GraftCore

/// A live, in-place terminal dashboard for interactive `graft arborist tend`: the pools
/// of the tree, each with a fixed row per desired runner slot showing what that leaf is
/// doing (booting → ready → running a job → stopping). `Log` lines scroll above the live
/// region.
///
/// The block is *seeded* from config (`configure(pools:)`) so it renders the full
/// expected shape immediately — every pool, every desired slot — even before a single
/// leaf reports in, and even when the fleet has no capacity (Orchard with no branches).
/// A slot with no live leaf shows a dim placeholder rather than vanishing, so the screen
/// always reflects what the tree is *supposed* to be, not just what happens to be up.
///
/// Rendering is a single bottom-anchored block redrawn on a timer. Each redraw moves the
/// cursor to the top of the block and clears to end of screen (`ESC[<n>F` + `ESC[0J`),
/// prints any pending log lines (which become permanent scrollback), then redraws the
/// block below — so it always sits at the bottom and shrinks/grows cleanly. TTY-only;
/// the caller skips this entirely for daemon/piped output.
final class LiveDashboard: @unchecked Sendable {
    /// One configured pool and how many runners it wants — the fixed shape we always draw.
    struct PoolSpec { let name: String; let desired: Int }

    private struct Row { var vm: String?; var phase: RunnerPhase; var kind: String; var since: Date }

    private let lock = NSLock()
    private var specs: [PoolSpec] = []               // configured pools, in config order
    private var specIndex: [String: Int] = [:]       // pool name → position in `specs`
    private var rows: [String: Row] = [:]            // slot tag ("pool#i") → live row
    private var pendingLogs: [String] = []
    private var prevLineCount = 0
    private var tick = 0
    private var running = false
    private var loop: Task<Void, Never>?

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let out = FileHandle.standardOutput

    // MARK: Lifecycle

    /// Seed the fixed shape: the pools and their desired runner counts. Call before
    /// `start()` (or any time) so the block draws every expected slot from the first
    /// frame — including pools that have no leaf up yet.
    func configure(pools: [PoolSpec]) {
        lock.lock(); defer { lock.unlock() }
        specs = pools
        specIndex = Dictionary(uniqueKeysWithValues: pools.enumerated().map { ($0.element.name, $0.offset) })
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        Self.out.write(Data("\u{1B}[?25l".utf8))    // hide cursor
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.render()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    func stop() {
        loop?.cancel()
        lock.lock()
        running = false
        var output = moveToBlockStart()
        output += "\u{1B}[0J"                        // clear the live block
        output += flushPendingLogs()                 // emit any trailing logs
        rows.removeAll(); prevLineCount = 0
        output += "\u{1B}[?25h"                      // show cursor
        if !output.hasSuffix("\n") { output += "\n" } // leave the prompt on a clean line
        Self.out.write(Data(output.utf8))
        lock.unlock()
    }

    // MARK: Feeds (called from supervisor tasks + the Log sink — all thread-safe)

    func update(slot: String, vm: String?, phase: RunnerPhase) {
        lock.lock(); defer { lock.unlock() }
        // Register the pool if we weren't pre-seeded, so an un-configured caller still
        // groups correctly (desired count is then inferred from the slot indices seen).
        registerPoolIfNeeded(for: slot)
        if case .done = phase {
            // The slot's task exited (shutdown). Drop the live row back to a placeholder —
            // the pool still *desires* this slot, so the row stays visible, just dim.
            rows[slot] = nil
        } else {
            let kind = phase.kind
            let priorSince = (rows[slot]?.kind == kind) ? rows[slot]?.since : nil
            rows[slot] = Row(vm: vm ?? rows[slot]?.vm, phase: phase, kind: kind, since: priorSince ?? Date())
        }
    }

    func log(_ line: String, isWarn: Bool) {
        lock.lock(); defer { lock.unlock() }
        pendingLogs.append(line)
    }

    // MARK: Rendering

    private func render() {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }

        // 1. Go to the top of the current live block and wipe it (+ anything below).
        var output = moveToBlockStart()
        if prevLineCount > 0 { output += "\u{1B}[0J" }
        // 2. Flush log lines — they end in \n, so they scroll into permanent history.
        output += flushPendingLogs()
        // 3. Redraw the block with NO trailing newline, so the cursor rests on the last
        //    row and the terminal never scrolls (which corrupts the in-place redraw).
        let frame = Self.frames[tick % Self.frames.count]
        let lines = renderLines(frame: frame)
        prevLineCount = lines.count
        output += lines.joined(separator: "\n")
        tick += 1
        Self.out.write(Data(output.utf8))
    }

    /// Build the block: a header + one row per desired slot, grouped by pool.
    private func renderLines(frame: String) -> [String] {
        guard !specs.isEmpty else { return [] }
        var lines: [String] = []
        for (i, spec) in specs.enumerated() {
            if i > 0 { lines.append("") }            // blank line between pools
            lines.append(header(for: spec))
            let desired = max(spec.desired, highestIndex(in: spec.name) + 1)
            for idx in 0..<desired {
                lines.append(slotLine(pool: spec.name, index: idx, frame: frame))
            }
        }
        return lines
    }

    /// `  mac  ·  1/2 up · 1 busy` — pool name, live count vs desired, and a tally of
    /// what the live leaves are doing.
    private func header(for spec: PoolSpec) -> String {
        let desired = max(spec.desired, highestIndex(in: spec.name) + 1)
        var tally: [String: Int] = [:]
        var up = 0
        for idx in 0..<desired {
            guard let row = rows["\(spec.name)#\(idx)"] else { continue }
            up += 1
            tally[row.phase.kind, default: 0] += 1
        }
        var parts = [ANSI.bold(spec.name), ANSI.dim("·"), "\(up)/\(desired) up"]
        if !tally.isEmpty {
            let summary = tally.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            parts.append(ANSI.dim("· \(summary)"))
        }
        return "  " + parts.joined(separator: " ")
    }

    /// One slot row: a live leaf with its phase, or a dim placeholder when nothing's up.
    private func slotLine(pool: String, index: Int, frame: String) -> String {
        let label = "#\(index)".padding(toLength: 3, withPad: " ", startingAt: 0)
        guard let row = rows["\(pool)#\(index)"] else {
            // No leaf for this desired slot (capacity-clamped, or not started yet).
            let vm = "—".padding(toLength: 8, withPad: " ", startingAt: 0)
            return "    " + ANSI.dim("· \(label)  \(vm)  waiting…")
        }
        let vm = Self.shortVM(row.vm).padding(toLength: 8, withPad: " ", startingAt: 0)
        let glyph = Self.glyph(kind: row.kind, frame: frame)
        let age = ANSI.dim(Self.age(since: row.since))
        return "    \(glyph) \(label)  \(vm)  \(row.phase.label)  \(age)"
    }

    /// Glyph + colour per phase: steady green dot when ready/parked, a spinner while it's
    /// actively working, yellow while retrying, dim while tearing down.
    private static func glyph(kind: String, frame: String) -> String {
        switch kind {
        case "ready":                       return ANSI.green("●")
        case "busy":                        return ANSI.green(frame)
        case "waiting":                     return ANSI.dim("·")
        case "retrying":                    return ANSI.yellow(frame)
        case "stopping", "deregistering":   return ANSI.dim(frame)
        default:                            return frame    // acquiring/booting/provisioning/…
        }
    }

    // MARK: Helpers

    /// Highest slot index reported live for a pool (so an un-seeded or over-spawned pool
    /// still shows every row it actually has).
    private func highestIndex(in pool: String) -> Int {
        var max = -1
        let prefix = "\(pool)#"
        for tag in rows.keys where tag.hasPrefix(prefix) {
            if let idx = Int(tag.dropFirst(prefix.count)), idx > max { max = idx }
        }
        return max
    }

    /// If a slot reports for a pool we weren't told about, append it so it still renders.
    private func registerPoolIfNeeded(for tag: String) {
        guard let hash = tag.lastIndex(of: "#") else { return }
        let pool = String(tag[..<hash])
        guard specIndex[pool] == nil else { return }
        specIndex[pool] = specs.count
        specs.append(PoolSpec(name: pool, desired: 1))
    }

    /// Cursor to column 0 of the first live row (we never leave a trailing newline, so the
    /// cursor sits at the end of the last row between renders).
    private func moveToBlockStart() -> String {
        guard prevLineCount > 0 else { return "" }
        var s = "\r"
        if prevLineCount > 1 { s += "\u{1B}[\(prevLineCount - 1)A" }
        return s
    }

    private func flushPendingLogs() -> String {
        guard !pendingLogs.isEmpty else { return "" }
        let text = pendingLogs.map { $0 + "\n" }.joined()
        pendingLogs.removeAll()
        return text
    }

    /// `graft-d62da19a-…` → `d62da19a` (the bit that distinguishes leaves at a glance).
    private static func shortVM(_ vm: String?) -> String {
        guard let vm else { return "—" }
        let stripped = vm.hasPrefix(LocalTartProvider.namePrefix) ? String(vm.dropFirst(LocalTartProvider.namePrefix.count)) : vm
        return String(stripped.prefix(8))
    }

    /// Compact "time in this phase": `5s` / `3m` / `1h02m`.
    private static func age(since: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(since))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
    }
}
