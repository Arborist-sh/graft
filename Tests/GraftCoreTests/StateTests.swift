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

    @Test("ownedVMNames unions tracked runners with in-flight slot leaves (GFT-20)")
    func ownedUnionsInFlight() {
        let tracked = RunningVM(name: "graft-tracked", ip: "10.0.0.2", os: .macOS)
        let state = PoolState(
            runners: [RunnerRecord(vm: tracked, pool: "mac", startedAt: Date())],
            slots: [
                // Same leaf, now reporting a phase — must dedupe, not double-count.
                SlotStatus(tag: "mac#0", pool: "mac", vmName: "graft-tracked",
                           phaseLabel: "ready", phaseKind: "ready", since: Date()),
                // A leaf mid-acquire: it has a slot phase + name but no runner record yet.
                // Keying off `runners` alone would false-flag it as deadwood (GFT-20).
                SlotStatus(tag: "mac#1", pool: "mac", vmName: "graft-inflight",
                           phaseLabel: "acquiring leaf", phaseKind: "acquiring", since: Date()),
                // A parked slot with no leaf contributes nothing.
                SlotStatus(tag: "mac#2", pool: "mac", vmName: nil,
                           phaseLabel: "waiting for capacity", phaseKind: "waiting", since: Date()),
            ]
        )
        #expect(state.ownedVMNames == ["graft-tracked", "graft-inflight"])
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
