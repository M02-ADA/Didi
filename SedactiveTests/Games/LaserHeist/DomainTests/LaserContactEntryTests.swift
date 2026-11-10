import Foundation
import Testing
@testable import Sedactive

nonisolated struct LaserContactEntryTests {
    static let lifetime = UUID(uuidString: "D0900000-0000-4000-8000-000000000001")!
    static let targetID = UUID(uuidString: "D0900000-0000-4000-8000-000000000002")!
    static let left = LaserContactHand(playerID: .player1, wrist: .left)
    static let right = LaserContactHand(playerID: .player1, wrist: .right)

    private func target(_ id: UUID = targetID, players: Set<PlayerID> = Set(PlayerID.allCases),
                        activation: Double = 1, deadline: Double = 5) throws -> LaserContactTarget {
        try LaserContactTarget(id: id, eligiblePlayers: players, activation: activation, deadline: deadline)
    }

    private func tracker(_ targets: [LaserContactTarget]? = nil) throws -> LaserContactEntryTracker {
        var tracker = try LaserContactEntryTracker(lifetime: Self.lifetime, maximumContactAge: 0.5)
        try tracker.replaceTargets(targets ?? [target()])
        return tracker
    }

    private func evaluate(_ tracker: inout LaserContactEntryTracker, frame: UInt64, capture: Double,
                          arrival: Double? = nil, hands: [LaserContactHand: LaserContactLocation],
                          targetID: UUID = targetID, lifetime: UUID = lifetime) throws -> [LaserContactActivation] {
        try tracker.evaluate(lifetime: lifetime, frameID: frame, capturedAt: capture,
            arrivedAt: arrival ?? capture, locations: [targetID: hands])
    }

    @Test func firstInsideAndHeldPoseNeedANewOutsideBaseline() throws {
        var tracker = try tracker()
        for (frame, time) in [(UInt64(1), 1.0), (2, 1.1)] {
            #expect(try evaluate(&tracker, frame: frame, capture: time, hands: [Self.left: .inside]).isEmpty)
        }
        #expect(try evaluate(&tracker, frame: 3, capture: 1.2, hands: [Self.left: .outside]).isEmpty)
        #expect(try evaluate(&tracker, frame: 4, capture: 1.3, hands: [Self.left: .inside]) ==
                [LaserContactActivation(targetID: Self.targetID, hand: Self.left)])
        #expect(try evaluate(&tracker, frame: 5, capture: 1.4, hands: [Self.left: .outside]).isEmpty)
        #expect(try evaluate(&tracker, frame: 6, capture: 1.5, hands: [Self.left: .inside]).isEmpty)
    }

    @Test(arguments: LaserContactHand.ordered)
    func eachWristWorksIndependentlyWhenAllOtherWristsAreUnavailable(_ hand: LaserContactHand) throws {
        var tracker = try tracker()
        #expect(try evaluate(&tracker, frame: 1, capture: 1, hands: [hand: .outside]).isEmpty)
        #expect(try evaluate(&tracker, frame: 2, capture: 1.1, hands: [hand: .inside]) ==
                [LaserContactActivation(targetID: Self.targetID, hand: hand)])
    }

    @Test func unavailableObservationBreaksPendingEntry() throws {
        var tracker = try tracker()
        _ = try evaluate(&tracker, frame: 1, capture: 1, hands: [Self.left: .outside])
        _ = try evaluate(&tracker, frame: 2, capture: 1.1, hands: [:])
        #expect(try evaluate(&tracker, frame: 3, capture: 1.2, hands: [Self.left: .inside]).isEmpty)
        _ = try evaluate(&tracker, frame: 4, capture: 1.3, hands: [Self.left: .outside])
        #expect(try evaluate(&tracker, frame: 5, capture: 1.4, hands: [Self.left: .inside]).count == 1)
    }

    @Test(arguments: [true, false])
    func staleArrivalOrCaptureGapRequiresAnotherOutside(_ staleArrival: Bool) throws {
        var tracker = try tracker()
        _ = try evaluate(&tracker, frame: 1, capture: 1, hands: [Self.left: .outside])
        #expect(try evaluate(&tracker, frame: 2, capture: staleArrival ? 1.1 : 1.6,
            arrival: 1.7, hands: [Self.left: .inside]).isEmpty)
        _ = try evaluate(&tracker, frame: 3, capture: 1.8, hands: [Self.left: .outside])
        #expect(try evaluate(&tracker, frame: 4, capture: 1.9, hands: [Self.left: .inside]).count == 1)
    }

    @Test func preActivationAndIneligiblePlayerCannotArm() throws {
        var tracker = try tracker([target(players: [.player2])])
        let other = LaserContactHand(playerID: .player2, wrist: .left)
        _ = try evaluate(&tracker, frame: 1, capture: 0.9, hands: [other: .outside])
        #expect(try evaluate(&tracker, frame: 2, capture: 1, hands: [other: .inside]).isEmpty)
        _ = try evaluate(&tracker, frame: 3, capture: 1.1, hands: [Self.left: .outside])
        #expect(try evaluate(&tracker, frame: 4, capture: 1.2, hands: [Self.left: .inside]).isEmpty)
    }

    @Test(arguments: [4.999, 5.0, 5.001], [true, false])
    func captureAndArrivalMustBothPrecedeDeadline(_ boundary: Double, _ captureAtBoundary: Bool) throws {
        var tracker = try tracker()
        _ = try evaluate(&tracker, frame: 1, capture: 4.8, hands: [Self.left: .outside])
        let result = try evaluate(&tracker, frame: 2, capture: captureAtBoundary ? boundary : 4.9,
                                  arrival: boundary, hands: [Self.left: .inside])
        #expect(result.count == (boundary < 5 ? 1 : 0))
    }

    @Test func duplicatesAndOutOfOrderFramesCannotRewindOrCreateEntry() throws {
        var tracker = try tracker()
        _ = try evaluate(&tracker, frame: 2, capture: 1.1, hands: [Self.left: .outside])
        #expect(try evaluate(&tracker, frame: 2, capture: 1.1, arrival: 1.2,
                             hands: [Self.left: .outside]).isEmpty)
        #expect(throws: LaserDataError.self) {
            try evaluate(&tracker, frame: 2, capture: 1.1, arrival: 1.2, hands: [Self.left: .inside])
        }
        #expect(try evaluate(&tracker, frame: 1, capture: 1, arrival: 1.2, hands: [:]).isEmpty)
        #expect(try evaluate(&tracker, frame: 3, capture: 1.05, arrival: 1.3, hands: [:]).isEmpty)
        #expect(try evaluate(&tracker, frame: 4, capture: 1.1, arrival: 1.3,
                             hands: [Self.left: .inside]).isEmpty)
        #expect(try evaluate(&tracker, frame: 5, capture: 1.2, arrival: 1.4,
                             hands: [Self.left: .inside]).count == 1)
    }

    @Test func simultaneousPlayersAndHandsHaveStableTieAndTargetOrder() throws {
        let second = UUID(uuidString: "D0900000-0000-4000-8000-000000000003")!
        var tracker = try tracker([target(second), target()])
        let outside = Dictionary(uniqueKeysWithValues: LaserContactHand.ordered.reversed().map { ($0, LaserContactLocation.outside) })
        let inside = outside.mapValues { _ in LaserContactLocation.inside }
        _ = try tracker.evaluate(lifetime: Self.lifetime, frameID: 1, capturedAt: 1, arrivedAt: 1,
                                locations: [second: outside, Self.targetID: outside])
        let result = try tracker.evaluate(lifetime: Self.lifetime, frameID: 2, capturedAt: 1.1, arrivedAt: 1.1,
                                         locations: [second: inside, Self.targetID: inside])
        #expect(result.map(\.targetID) == [Self.targetID, second])
        #expect(result.allSatisfy { $0.hand == Self.left })
    }

    @Test func invalidationRevokesOldLifetimeAndHeldEvidence() throws {
        var tracker = try tracker()
        _ = try evaluate(&tracker, frame: 10, capture: 1, hands: [Self.left: .outside])
        let next = UUID()
        try tracker.invalidate(lifetime: next, capturedAfter: 1.1)
        #expect(try evaluate(&tracker, frame: 11, capture: 1.2, hands: [Self.left: .inside]).isEmpty)
        #expect(try evaluate(&tracker, frame: 1, capture: 1.1, arrival: 1.2,
                             hands: [Self.left: .outside], lifetime: next).isEmpty)
        #expect(try evaluate(&tracker, frame: 2, capture: 1.2,
                             hands: [Self.left: .inside], lifetime: next).isEmpty)
        _ = try evaluate(&tracker, frame: 3, capture: 1.3, hands: [Self.left: .outside], lifetime: next)
        #expect(try evaluate(&tracker, frame: 4, capture: 1.4,
                             hands: [Self.left: .inside], lifetime: next).count == 1)
    }

    @Test func newlySpawnedTargetCannotConsumeTriggeringFrameOrHeldWrist() throws {
        var tracker = try tracker()
        _ = try evaluate(&tracker, frame: 1, capture: 1, hands: [Self.left: .outside])
        _ = try evaluate(&tracker, frame: 2, capture: 1.1, hands: [Self.left: .inside])
        let next = UUID()
        try tracker.replaceTargets([target(next, activation: 1.1)])
        // The original frame cannot be repurposed with new target membership.
        #expect(throws: LaserDataError.self) {
            try evaluate(&tracker, frame: 2, capture: 1.1, hands: [Self.left: .inside], targetID: next)
        }
        #expect(try evaluate(&tracker, frame: 3, capture: 1.2,
                             hands: [Self.left: .inside], targetID: next).isEmpty)
        _ = try evaluate(&tracker, frame: 4, capture: 1.3, hands: [Self.left: .outside], targetID: next)
        #expect(try evaluate(&tracker, frame: 5, capture: 1.4,
                             hands: [Self.left: .inside], targetID: next).count == 1)
        #expect(throws: LaserDataError.self) { try tracker.replaceTargets([target()]) }
    }

    @Test func invalidConfigurationAndNonCausalInputAreRejected() throws {
        for age in [0, -1, Double.nan, Double.infinity] {
            #expect(throws: LaserDataError.self) {
                try LaserContactEntryTracker(lifetime: Self.lifetime, maximumContactAge: age)
            }
        }
        #expect(throws: LaserDataError.self) { try target(players: []) }
        #expect(throws: LaserDataError.self) { try target(activation: 1, deadline: 1) }
        var tracker = try tracker()
        #expect(throws: LaserDataError.self) {
            try evaluate(&tracker, frame: 1, capture: 2, arrival: 1, hands: [:])
        }
        #expect(throws: LaserDataError.self) { try tracker.replaceTargets([target(), target()]) }
    }
}
