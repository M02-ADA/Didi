import Foundation
import Testing
@testable import Sedactive

@MainActor
struct ReplayBodyInputTests {
    @Test func bundledVersionedFixturesDecodeAndRoundTrip() throws {
        for name in ["cooperative-v2", "two-player-recovery-v2"] {
            let fixture = try LH00TestData.load(name)
            let encoded = try JSONEncoder().encode(fixture)
            #expect(try ReplayFixture.decode(encoded) == fixture)
            #expect(fixture.schemaVersion == 2)
            #expect(fixture.records.count == (name == "cooperative-v2" ? 14 : 17))
        }
    }

    @Test func missingWristAndSoleStayIndependentWithoutVerdictLogic() throws {
        let fixture = try LH00TestData.load()
        let firstID = PlayerID.player1
        let secondID = PlayerID.player2
        let clearInput = try #require(fixture.records[1].snapshot?.players[firstID])
        #expect(clearInput.geometry.crownY.validity == .valid)
        #expect(clearInput.geometry.leftWristY.value == 0.82)
        #expect(clearInput.geometry.rightWristY.value == 0.86)
        let raised = try #require(fixture.records[2].snapshot?.players[firstID])
        #expect(raised.geometry.rightWristY.value == 1.12)
        #expect(raised.geometry.crownY == clearInput.geometry.crownY)
        let wristMissing = try #require(fixture.records[3].snapshot?.players[firstID])
        #expect(wristMissing.geometry.leftWristY.value == nil)
        #expect(wristMissing.geometry.leftWristY.validity == .missingLandmarks)
        #expect(wristMissing.geometry.leftSoleY.validity == .valid)
        let jump = try #require(fixture.records[4].snapshot?.players[secondID])
        #expect(jump.geometry.leftSoleY.value == 0.22)
        #expect(jump.geometry.rightSoleY.value == 0.24)
        #expect(jump.jumpState == JumpState(phase: .airborne, validity: .valid))
        #expect(fixture.records[5].snapshot?.players[secondID]?.geometry.rightSoleY.value == 0.17)
        let soleMissing = try #require(fixture.records[6].snapshot?.players[secondID])
        #expect(soleMissing.geometry.rightSoleY.validity == .missingLandmarks)
        #expect(soleMissing.geometry.crownY.validity == .valid)
        #expect(soleMissing.geometry.leftWristY.validity == .valid)
        #expect(fixture.records[7].snapshot?.players[secondID]?.trackingStatus == .uncertain)
        #expect(fixture.records[8].snapshot?.players[secondID]?.trackingStatus == .lost)
        #expect(fixture.records[9].snapshot?.players[secondID]?.geometry.crownY.validity == .stale)
    }

    @Test(arguments: ["cooperative-v2", "two-player-recovery-v2"])
    func repeatedReplayHasIdenticalPacketsCacheCountersAndStatuses(_ name: String) async throws {
        let fixture = try LH00TestData.load(name)
        let first = try await run(fixture)
        let second = try await run(fixture)
        #expect(first.packets == second.packets)
        #expect(first.latest == second.latest)
        #expect(first.diagnostics == second.diagnostics)
        #expect(first.events == second.events)
        #expect(first.packets.map(\.frameID) == fixture.records.compactMap { $0.snapshot?.frameID })
        #expect(first.latest?.frameID == (name == "cooperative-v2" ? 13 : 14))
    }

    private func run(_ fixture: ReplayFixture) async throws -> (
        packets: [BodySnapshot], latest: BodySnapshot?, diagnostics: BodyInputDiagnostics, events: [BodyInputStatusEvent]
    ) {
        let provider = try ReplayBodyInput(fixture: fixture)
        var events: [BodyInputStatusEvent] = []
        let observer = try provider.statusUpdates { events.append($0) }
        try await provider.start(configuration: fixture.configuration)
        var iterator = try provider.snapshotStream(generation: fixture.configuration.sessionGeneration).makeAsyncIterator()
        var packets: [BodySnapshot] = []
        for record in fixture.records {
            try provider.advance(to: record.deliveredAt)
            if let snapshot = record.snapshot {
                let packet = try #require(await iterator.next())
                #expect(packet == snapshot)
                packets.append(packet)
            }
        }
        let latest = provider.latestSnapshot
        try provider.releaseSnapshotSubscription(generation: fixture.configuration.sessionGeneration)
        await provider.stop()
        try provider.removeStatusObserver(observer)
        return (packets, latest, provider.diagnostics, events)
    }

    @Test func overflowReplayAndResetAreRepeatable() async throws {
        let fixture = try LH00TestData.load()
        var results: [[UInt64]] = []
        for _ in 0..<2 {
            let provider = try ReplayBodyInput(fixture: fixture)
            try await provider.start(configuration: fixture.configuration)
            var iterator = try provider.snapshotStream(generation: fixture.configuration.sessionGeneration).makeAsyncIterator()
            try provider.advance(to: 14)
            #expect(provider.diagnostics.droppedSnapshotCount == 6)
            var frames: [UInt64] = []
            for _ in 0..<8 { frames.append(try #require(await iterator.next()).frameID) }
            results.append(frames)
            try provider.advance(to: 100) // EOF does not fabricate stopped or clear latest evidence.
            #expect(provider.status == .running)
            #expect(provider.latestSnapshot?.frameID == 13)
            #expect(throws: BodyInputContractError.self) { try provider.advance(to: 99) }
            await provider.stop()
            #expect(provider.latestSnapshot == nil)
        }
        #expect(results[0] == results[1])
    }

    @Test func malformedVersionAndConflictingDuplicateAreRejected() throws {
        let base = try LH00TestData.load()
        let badVersion = ReplayFixture(schemaVersion: 99,
                                       configuration: base.configuration, cameraGeometryRevision: 1, records: [])
        #expect(throws: BodyInputContractError.self) { try ReplayBodyInput(fixture: badVersion) }
        let first = try LH00TestData.snapshot(1, capturedAt: 1)
        let conflict = try LH00TestData.snapshot(1, capturedAt: 1.5)
        let fixture = try LH00TestData.fixture([ReplayRecord(deliveredAt: 2, snapshot: first),
                                              ReplayRecord(deliveredAt: 3, snapshot: conflict)])
        #expect(throws: BodyInputContractError.conflictingObservation) { try ReplayBodyInput(fixture: fixture) }
        let invalidTime = try LH00TestData.fixture([ReplayRecord(deliveredAt: 0, snapshot: first)])
        #expect(throws: BodyInputContractError.self) { try ReplayBodyInput(fixture: invalidTime) }
        let staleGeometry = try LH00TestData.fixture([ReplayRecord(deliveredAt: 1, cameraGeometryRevision: 2),
                                                    ReplayRecord(deliveredAt: 2, cameraGeometryRevision: 1)])
        #expect(throws: BodyInputContractError.self) { try ReplayBodyInput(fixture: staleGeometry) }
    }

    @Test func framePayloadContainsNoProfilesOrDeliveryTime() throws {
        let snapshot = try LH00TestData.snapshot(1)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(Set(object.keys) == ["sessionGeneration", "frameID", "capturedAt", "cameraGeometryRevision", "players"])
        let players = try #require(object["players"] as? [String: Any])
        for value in players.values {
            let sample = try #require(value as? [String: Any])
            #expect(sample["name"] == nil)
            #expect(sample["weightKg"] == nil)
            #expect(sample["zone"] == nil)
        }
    }

    @Test func schemaTwoRejectsLegacyResourcesAndUnknownSlotKeysExplicitly() throws {
        for name in ["cooperative-v1", "reversed-selection-v1"] {
            #expect(throws: BodyInputContractError.invalidValue("unsupported replay schema version: 1")) {
                try LH00TestData.load(name)
            }
        }
        let fixture = try LH00TestData.load()
        let data = try JSONEncoder().encode(fixture)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "configuration", "cameraGeometryRevision", "records"])
        var configuration = try #require(object["configuration"] as? [String: Any])
        var baselines = try #require(configuration["calibrations"] as? [String: Any])
        baselines["00000000-0000-4000-8000-000000000001"] = baselines.removeValue(forKey: "player1")
        configuration["calibrations"] = baselines
        object["configuration"] = configuration
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try ReplayFixture.decode(malformed) }
    }

    @Test func anonymousRecoveryFixtureKeepsSlotsWhileStatusAndTrackingRecover() async throws {
        let fixture = try LH00TestData.load("two-player-recovery-v2")
        let provider = try ReplayBodyInput(fixture: fixture)
        var events: [BodyInputStatusEvent] = []
        let observer = try provider.statusUpdates { events.append($0) }
        try await provider.start(configuration: fixture.configuration)
        try provider.advance(to: 8)
        #expect(provider.latestSnapshot?.players[.player2]?.trackingStatus == .uncertain)
        try provider.advance(to: 9)
        #expect(provider.latestSnapshot?.players[.player2]?.trackingStatus == .lost)
        try provider.advance(to: 14)
        #expect(provider.status == .interrupted(.system))
        #expect(provider.latestSnapshot == nil)
        try provider.advance(to: 16.2)
        let recovered = try #require(provider.latestSnapshot)
        #expect(provider.status == .running)
        #expect(recovered.frameID == 14)
        #expect(Set(recovered.players.keys) == Set(PlayerID.allCases))
        #expect(recovered.players[.player2]?.trackingStatus == .reliable)
        #expect(events.map(\.status).contains(.interrupted(.system)))
        #expect(provider.currentContext?.accepts(recovered) == true)
        try provider.removeStatusObserver(observer)
        // Scripted evidence verifies transport/identity metadata, not real tracker reacquisition.
    }

}
