import Foundation
import Testing
@testable import GraftCore

/// Thread-safe sink for the `@Sendable` onLine handler (called off a background queue).
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite("Shell streaming")
struct ShellTests {
    @Test("captures output lines, feeds stdin, returns the exit code")
    func capturesLinesAndStdin() async throws {
        let collected = LineCollector()
        // Echo a line, echo stdin back through `cat`, echo another, then exit 0.
        let code = try await Shell.runStreaming(
            "bash", ["-c", "echo first; cat; echo third"],
            stdin: "second\n",
            onLine: { collected.add($0) }
        )
        #expect(code == 0)

        // The background reader may flush the last line just after exit.
        for _ in 0..<50 where collected.all().count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        let lines = collected.all()
        #expect(lines.contains("first"))
        #expect(lines.contains("second"))   // proves stdin was delivered
        #expect(lines.contains("third"))
    }

    @Test("run() returns a fast child's real exit code promptly (no waitUntilExit hang)")
    func runReturnsFastExitCode() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let ok = try await Shell.run("true")
        let bad = try await Shell.run("sh", ["-c", "exit 7"])
        #expect(ok.exitCode == 0)
        #expect(bad.exitCode == 7)               // real status, read without waitUntilExit
        #expect(start.duration(to: clock.now) < .seconds(5))   // never hangs on a fast child
    }

    @Test("run() gives the child /dev/null stdin so a stdin-reading command can't hang on an inherited TTY")
    func runStdinIsNullDevice() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        // `cat` with no args reads stdin to EOF. If it inherited a controlling terminal
        // it would block forever (the bug that hung `orchard ssh` under interactive
        // `graft run`); with /dev/null stdin it sees immediate EOF and exits empty.
        let result = try await Shell.run("cat")
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(start.duration(to: clock.now) < .seconds(5))   // returned promptly, didn't hang on stdin
    }

    @Test("times out and terminates a hung subprocess instead of blocking forever")
    func timesOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await Shell.run("sleep", ["30"], timeout: .seconds(1))
        let elapsed = start.duration(to: clock.now)
        #expect(!result.succeeded)              // terminated → non-zero exit
        #expect(elapsed < .seconds(5))          // returned promptly, not after 30s
    }

    @Test("strips trailing carriage returns and propagates non-zero exit")
    func stripsCRAndExitCode() async throws {
        let collected = LineCollector()
        let code = try await Shell.runStreaming(
            "bash", ["-c", "printf 'has-cr\\r\\n'; exit 7"],
            onLine: { collected.add($0) }
        )
        #expect(code == 7)
        for _ in 0..<50 where collected.all().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(collected.all().contains("has-cr"))   // \r stripped, not "has-cr\r"
    }
}
