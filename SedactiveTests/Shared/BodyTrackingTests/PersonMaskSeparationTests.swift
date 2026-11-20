import Foundation
import Testing
@testable import Sedactive

/// `PersonSegmenter.associate` with other people in view (pre-merge audit, 20 November 2026). Staging
/// refused every frame with more people than linked players; this branch allows bystanders, so a
/// player's instance must be shown to be theirs alone. A 20 × 20 mask labelled by column; P2's torso
/// is in columns 4–6, P1's in 14–16 (`LiveVisionFixtures.standingPair`).
nonisolated struct PersonMaskSeparationTests {
    typealias F = TrackingFixtures

    static func associate(_ candidates: [PoseCandidate], count: Int? = nil, labels: [UInt8],
                          bounds: [[Int]], label: @escaping (Int) -> UInt8) throws -> [PlayerID: PersonMaskRegion] {
        let f = try TrackingIntegrationFixture()
        let pose = try f.result(3, 0.25, candidates, count: count)
        let association = LiveVisionFixtures.association(pose, revision: 2)
        return PersonSegmenter.associate(pose: pose, association: association, labels: labels, bounds: bounds,
                                         width: 20, height: 20) { x, _ in label(x) }
    }

    /// Two players, each on their own instance: both regions, with their own bounds.
    static let pairMask: (labels: [UInt8], bounds: [[Int]], label: (Int) -> UInt8) =
        ([1, 2], [[0, 9, 0, 19], [10, 19, 0, 19]], { $0 < 10 ? 1 : 2 })

    /// A person with only weak joints (all below the 0.5 confidence the players need), e.g. half out
    /// of frame at the edge: their torso is not confident, but Vision still placed them.
    static func weak(_ id: UInt64, x: Double) -> PoseCandidate {
        F.candidate(id, x: x, confidence: 0.3)
    }

    @Test func onePlayerInSoloIsFound() throws {
        let f = try TrackingIntegrationFixture()
        let pose = try f.result(3, 0.25, [LiveVisionFixtures.standingPair[0]])
        let both = LiveVisionFixtures.association(pose, revision: 2)
        let solo = PlayerTrackingSnapshot(source: both.source, evaluatedAt: both.evaluatedAt, controlRevision: both.controlRevision,
            player1: both.player1, player2: .init(state: .unbound, reason: .acquiring, candidateID: nil, cost: nil,
                                                  requiresRebind: false, lastConfirmedAt: nil),
            assignmentCount: 1, confirmedDescriptorCount: 2, provisionalDescriptorCount: 0)
        let regions = PersonSegmenter.associate(pose: pose, association: solo, labels: [1], bounds: [[10, 19, 0, 19]],
                                                width: 20, height: 20) { x, _ in x >= 10 ? 1 : 0 }
        #expect(regions[.player1]?.label == 1 && regions[.player2] == nil)
    }

    @Test func twoValidPlayersAreBothFound() throws {
        let m = Self.pairMask
        let regions = try Self.associate(LiveVisionFixtures.standingPair, labels: m.labels, bounds: m.bounds, label: m.label)
        #expect(regions[.player1]?.label == 2 && regions[.player2]?.label == 1)
    }

    /// A bystander on their own instance never affects either player.
    @Test func aSeparateBystanderIsIgnored() throws {
        for bystander in [F.candidate(30, x: 0.95), Self.weak(30, x: 0.95)] {
            let regions = try Self.associate(LiveVisionFixtures.standingPair + [bystander], labels: [1, 2, 3],
                bounds: [[0, 7, 0, 19], [8, 16, 0, 19], [17, 19, 0, 19]]) { $0 < 8 ? 1 : $0 <= 16 ? 2 : 3 }
            #expect(regions[.player1]?.label == 2 && regions[.player2]?.label == 1)
            #expect(regions[.player1]?.maxX == 17.0 / 20, "P1's bounds stop at P1's own instance")
        }
    }

    /// THE AUDIT'S CASE: Vision merged a bystander with only weak joints into P1's instance. The
    /// previous check located other people by their confident torso only, so P1 was admitted with
    /// bounds that include the bystander. Now P1 is refused (not separated); P2 is unaffected.
    @Test func aWeakBystanderMergedIntoAPlayerIsRefused() throws {
        let m = Self.pairMask
        let regions = try Self.associate(LiveVisionFixtures.standingPair + [Self.weak(30, x: 0.9)],
                                         labels: m.labels, bounds: m.bounds, label: m.label)
        #expect(regions[.player1] == nil, "P1's instance may include the bystander")
        #expect(regions[.player2]?.label == 1)
    }

    /// Only a bystander's arm (a wrist) lands on P2's instance: P2 is not shown to be alone, so refused.
    @Test func aBystandersLimbOnAPlayersInstanceRefusesThatPlayer() throws {
        var joints = Self.weak(30, x: 0.5).joints
        joints = joints.mapValues { _ in PoseJoint(x: 0.5, y: 0.5, confidence: 0.2) }
        joints[.rightWrist] = .init(x: 0.3, y: 0.5, confidence: 0.6) // column 6: P2's instance
        let reaching = PoseCandidate(candidateID: 30, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
            leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        let regions = try Self.associate(LiveVisionFixtures.standingPair + [reaching], labels: [1, 2, 3],
            bounds: [[0, 9, 0, 19], [12, 19, 0, 19], [10, 11, 0, 19]]) { $0 < 10 ? 1 : $0 < 12 ? 3 : 2 }
        #expect(regions[.player2] == nil && regions[.player1]?.label == 2)
    }

    /// More people than pose candidates (the candidate cap dropped someone): nobody in view is
    /// unchecked, so nothing is admitted.
    @Test func anUncheckedPersonInViewRefusesEveryone() throws {
        let m = Self.pairMask
        let regions = try Self.associate(LiveVisionFixtures.standingPair, count: 3, labels: m.labels, bounds: m.bounds, label: m.label)
        #expect(regions.isEmpty)
    }

    /// Another person with no joint inside the image cannot be located: nothing is admitted.
    @Test func anUnlocatablePersonRefusesEveryone() throws {
        let ghost = PoseCandidate(candidateID: 30, joints: [.leftShoulder: .init(x: 0, y: 0.5, confidence: 0.4)],
            maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil, rightFootBottomImageY: nil,
            maskAssociation: .unavailable)
        let m = Self.pairMask
        #expect(try Self.associate(LiveVisionFixtures.standingPair + [ghost], labels: m.labels, bounds: m.bounds, label: m.label).isEmpty)
    }

    /// Missing or ambiguous segmentation keeps its existing refusals: a torso on the background, a
    /// torso across two instances, and both players on one instance.
    @Test func missingOrAmbiguousSegmentationIsRefused() throws {
        let pair = LiveVisionFixtures.standingPair
        #expect(try Self.associate(pair, labels: [1], bounds: [[0, 9, 0, 19]]) { $0 < 10 ? 1 : 0 }.isEmpty, "P1 on the background")
        #expect(try Self.associate(pair, labels: [1, 2], bounds: [[0, 9, 0, 19], [10, 14, 0, 19]]) { $0 < 10 || $0 > 14 ? 1 : 2 }.isEmpty,
                "P1's torso across two instances")
        #expect(try Self.associate(pair, labels: [1], bounds: [[0, 19, 0, 19]]) { _ in 1 }.isEmpty, "one instance for both")
    }
}
