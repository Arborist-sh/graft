import Foundation
import Testing
@testable import GraftCore

@Suite("Pool state persistence")
struct StateTests {
    @Test("round-trips slot status")
    func roundTripsSlots() throws {
        let state = PoolState(
            runners: [],
            slots: [SlotStatus(tag: "mac#0", pool: "mac", vmName: "graft-abc", ip: "10.0.0.2",
                               phaseLabel: "running job: build", phaseKind: "busy", since: Date())]
        )
        let data = try StateManager.encoder.encode(state)
        let decoded = try StateManager.decoder.decode(PoolState.self, from: data)
        #expect(decoded.slots.count == 1)
        #expect(decoded.slots.first?.tag == "mac#0")
        #expect(decoded.slots.first?.phaseKind == "busy")
        #expect(decoded.slots.first?.phaseLabel == "running job: build")
    }

    @Test("decodes an older state file with no slots key")
    func backwardCompatible() throws {
        // A pre-slots state file: runners + updatedAt, no `slots`.
        let json = #"{"runners":[],"updatedAt":"2026-06-11T00:00:00Z"}"#
        let decoded = try StateManager.decoder.decode(PoolState.self, from: Data(json.utf8))
        #expect(decoded.slots.isEmpty)   // defaulted, not a decode failure
        #expect(decoded.runners.isEmpty)
    }
}
