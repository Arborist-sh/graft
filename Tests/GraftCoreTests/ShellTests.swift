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
