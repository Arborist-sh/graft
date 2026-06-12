import Foundation
import GraftCore
#if canImport(Darwin)
import Darwin
#endif

/// graft's terminal styling. The accent is green — the sprout. Everything renders to
/// stderr so stdout stays clean for machine-readable output.
enum ANSI {
    static let csi = "\u{1B}["
    static let reset = "\(csi)0m"
    static let hideCursor = "\(csi)?25l"
    static let showCursor = "\(csi)?25h"
    static let clearToEnd = "\(csi)0J"

    static func wrap(_ s: String, _ code: String) -> String { "\(csi)\(code)m\(s)\(reset)" }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func greenBold(_ s: String) -> String { wrap(s, "1;32") }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func cursorUp(_ n: Int) -> String { n > 0 ? "\(csi)\(n)A" : "" }
}

/// Put the terminal into raw mode for the duration of an interactive prompt: no echo,
/// no line buffering, and signals disabled (so we read Ctrl-C as a byte and restore
/// the terminal before exiting). Returns nil when stdin isn't a TTY.
#if canImport(Darwin)
final class RawMode {
    private var original = termios()
    private let fd: Int32

    init?(fd: Int32 = STDIN_FILENO) {
        self.fd = fd
        guard isatty(fd) != 0, tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_cc.16 = 1    // VMIN  = 1: block until at least one byte
        raw.c_cc.17 = 0    // VTIME = 0: no inter-byte timer
        guard tcsetattr(fd, TCSAFLUSH, &raw) == 0 else { return nil }
    }

    /// Read one keypress. Arrow keys arrive as a 3-byte escape in a single read.
    func readKey() -> Key {
        var buf = [UInt8](repeating: 0, count: 3)
        let n = read(fd, &buf, 3)
        guard n > 0 else { return .other }
        return decodeKey(Array(buf.prefix(n)))
    }

    func restore() { tcsetattr(fd, TCSAFLUSH, &original) }
}
#endif

/// An arrow-key single-select list with type-to-filter. The brand-styled successor to
/// a numbered menu — and since `Prompt.choose` routes through it, every picker (image,
/// repo, dev box, App, target, wizard) gets it for free. Falls back to a numbered menu
/// when there's no TTY (pipes, CI), so non-interactive use still works.
enum Select {
    private static let err = FileHandle.standardError
    private static func emit(_ s: String) { err.write(Data(s.utf8)) }

    /// Returns the chosen index into `options`, or nil if cancelled (esc) when
    /// `cancellable`. Ctrl-C restores the terminal and exits (130), like any CLI.
    static func choose(
        _ title: String, _ options: [String], cancellable: Bool = true, filterable: Bool = true
    ) -> Int? {
        #if canImport(Darwin)
        // We draw to stderr and read keys from stdin (RawMode checks stdin); only show
        // the live picker when stderr is a terminal too. Otherwise fall back.
        guard isatty(STDERR_FILENO) != 0, let raw = RawMode() else {
            return numberedFallback(title, options)
        }
        var state = SelectState(options: options)
        var prevLines = 0
        // Auto-disable the filter UI for short lists — no point on 2–3 options.
        let filter = filterable && options.count > 6

        func paint(_ block: String, lineCount: Int) {
            var out = ""
            if prevLines > 0 { out += "\r" + ANSI.cursorUp(prevLines - 1) + ANSI.clearToEnd }
            out += block
            emit(out)
            prevLines = lineCount
        }

        emit(ANSI.hideCursor)
        let (body, n) = render(state, title: title, filter: filter, cancellable: cancellable)
        paint(body, lineCount: n)

        defer { emit(ANSI.showCursor); raw.restore() }
        while true {
            switch raw.readKey() {
            case .up: state.up()
            case .down: state.down()
            case .enter:
                if let idx = state.selectedOptionIndex {
                    finalize(title: title, chosen: options[idx], prevLines: &prevLines)
                    return idx
                }
            case .escape where cancellable:
                finalize(title: title, chosen: nil, prevLines: &prevLines)
                return nil
            case .ctrlC:
                emit(ANSI.showCursor); raw.restore()
                exit(130)
            case .backspace where filter: state.backspaceQuery()
            case .char(let c) where filter: state.appendToQuery(c)
            default: break
            }
            let (body, n) = render(state, title: title, filter: filter, cancellable: cancellable)
            paint(body, lineCount: n)
        }
        #else
        return numberedFallback(title, options)
        #endif
    }

    // MARK: Rendering (pure string-building over SelectState)

    private static func render(_ s: SelectState, title: String, filter: Bool, cancellable: Bool) -> (String, Int) {
        var lines: [String] = []
        let nav = filter ? "↑/↓ · type to filter · enter" : "↑/↓ · enter"
        let hint = cancellable ? "\(nav) · esc" : nav
        lines.append("\(ANSI.green("?")) \(ANSI.bold(title))  \(ANSI.dim(hint))")
        if filter && !s.query.isEmpty {
            lines.append("  \(ANSI.dim("filter:")) \(s.query)")
        }
        let win = s.window
        if win.lowerBound > 0 { lines.append("    \(ANSI.dim("⋮"))") }
        for i in win {
            let label = s.options[s.filtered[i]]
            lines.append(i == s.cursor ? "  \(ANSI.greenBold("❯ \(label)"))" : "    \(label)")
        }
        if win.upperBound < s.filtered.count { lines.append("    \(ANSI.dim("⋮"))") }
        if s.filtered.isEmpty { lines.append("    \(ANSI.dim("(no matches)"))") }
        return (lines.joined(separator: "\n"), lines.count)
    }

    private static func finalize(title: String, chosen: String?, prevLines: inout Int) {
        var out = ""
        if prevLines > 0 { out += "\r" + ANSI.cursorUp(prevLines - 1) + ANSI.clearToEnd }
        if let chosen {
            out += "\(ANSI.green("✓")) \(ANSI.bold(title)) \(ANSI.dim("·")) \(chosen)\n"
        } else {
            out += ANSI.dim("✗ \(title) · cancelled") + "\n"
        }
        emit(out)
        prevLines = 0
    }

    /// Numbered-menu fallback for non-TTY contexts (pipes, CI) — the pre-glow-up UX,
    /// preserved so scripted/piped callers keep working.
    static func numberedFallback(_ title: String, _ options: [String]) -> Int {
        FileHandle.standardError.write(Data((title + "\n").utf8))
        for (index, option) in options.enumerated() {
            FileHandle.standardError.write(Data("  [\(index + 1)] \(option)\n".utf8))
        }
        while true {
            FileHandle.standardError.write(Data("pick [1-\(options.count)]: ".utf8))
            let value = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if let number = Int(value), (1...options.count).contains(number) { return number - 1 }
            FileHandle.standardError.write(Data("  not a valid choice\n".utf8))
        }
    }
}
