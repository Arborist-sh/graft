import Foundation

/// A decoded keypress from a raw-mode terminal. The byte→key decoding and the
/// selection-list math live here (pure, testable); the raw-mode I/O and ANSI
/// rendering live in the `graft` executable's TUI layer.
public enum Key: Equatable, Sendable {
    case up, down, enter, escape, ctrlC, backspace
    case char(Character)
    case other
}

/// Decode a small byte run from stdin into a `Key`. Terminals send arrow keys as a
/// 3-byte CSI escape (`ESC [ A`…) in a single read, normal keys as one byte, and a
/// lone `ESC` as a single `0x1B`.
public func decodeKey(_ bytes: [UInt8]) -> Key {
    switch bytes {
    case [0x1B, 0x5B, 0x41]: return .up        // ESC [ A
    case [0x1B, 0x5B, 0x42]: return .down       // ESC [ B
    case [0x1B, 0x5B, 0x43]: return .other      // right — ignored
    case [0x1B, 0x5B, 0x44]: return .other      // left — ignored
    case [0x0D], [0x0A]: return .enter          // CR / LF
    case [0x03]: return .ctrlC                  // ETX
    case [0x1B]: return .escape
    case [0x7F], [0x08]: return .backspace      // DEL / BS
    default:
        if bytes.count == 1, let b = bytes.first, (0x20..<0x7F).contains(b) {
            return .char(Character(UnicodeScalar(b)))
        }
        return .other
    }
}

/// The state of an interactive single-select list: the options, the live filter
/// query, the surviving (filtered) indices, and the cursor. All navigation/filter
/// transitions are pure so the fiddly off-by-ones (cursor clamping, the scroll
/// window) can be unit-tested without a terminal.
public struct SelectState: Equatable, Sendable {
    public let options: [String]
    public let maxVisible: Int
    public private(set) var query = ""
    public private(set) var cursor = 0          // index into `filtered`
    public private(set) var filtered: [Int]     // indices into `options`

    public init(options: [String], maxVisible: Int = 10) {
        self.options = options
        self.maxVisible = max(1, maxVisible)
        self.filtered = Array(options.indices)
    }

    /// The `options` index currently under the cursor, or nil when nothing matches.
    public var selectedOptionIndex: Int? {
        filtered.indices.contains(cursor) ? filtered[cursor] : nil
    }

    public mutating func up() { if cursor > 0 { cursor -= 1 } }
    public mutating func down() { if cursor < filtered.count - 1 { cursor += 1 } }

    public mutating func appendToQuery(_ c: Character) { query.append(c); reFilter() }
    public mutating func backspaceQuery() { if !query.isEmpty { query.removeLast(); reFilter() } }

    /// Case-insensitive substring filter. Keeps the cursor in range.
    private mutating func reFilter() {
        let q = query.lowercased()
        filtered = options.indices.filter { q.isEmpty || options[$0].lowercased().contains(q) }
        if cursor >= filtered.count { cursor = max(0, filtered.count - 1) }
    }

    /// The visible slice of `filtered` (a half-open range), scrolled to keep the
    /// cursor in view when the list is longer than `maxVisible`.
    public var window: Range<Int> {
        guard filtered.count > maxVisible else { return 0..<filtered.count }
        var start = cursor - maxVisible / 2
        start = max(0, min(start, filtered.count - maxVisible))
        return start..<(start + maxVisible)
    }
}
