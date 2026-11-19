import CoreGraphics
import Foundation
import Testing
@testable import Sedactive

/// People outside the calibration boxes (19 November 2026, iPad: a bystander at the far edge of the
/// camera while P1 stood in the left box). Linking counts only people whose torso centre is in a
/// box (`PlayerAcquisitionZones`); after linking, identity is the tracker's; the mask associates
/// each player by their own torso and refuses an instance shared with someone else.
nonisolated struct BystanderZoneTests {
    typealias F = TrackingFixtures

    static func solo() throws -> PlayerTracker {
        var tracker = try PlayerTracker(policy: F.policy())
        try tracker.reset(context: F.context(), controlRevision: 1)
        try tracker.armBinding(controlRevision: 1, solo: true)
        return tracker
    }

    /// Feeds `people` for `frames` frames 0.125 s apart (more than the acquisition dwell).
    @discardableResult
    static func feed(_ tracker: inout PlayerTracker, _ people: [PoseCandidate], frames: Int = 3,
                     from start: Int = 1) throws -> PlayerTrackingSnapshot {
        var r = tracker.snapshot
        for i in 0..<frames { r = try tracker.process(F.input(UInt64(start + i), Double(start + i) * 0.125, people)) }
        return r
    }

    /// Half out of frame at the image edge: one hip lost, still enough torso to be a body.
    static func partial(_ id: UInt64, x: Double) -> PoseCandidate {
        F.candidate(id, x: x, missing: [.leftHip])
    }

    // MARK: Solo

    @Test func soloP1AloneInTheBoxLinks() throws {
        var t = try Self.solo()
        let r = try Self.feed(&t, [F.candidate(10, x: 0.5)])
        #expect(r.player1.state == .tracking && r.player1.candidateID == 10 && r.player2.state == .unbound)
    }

    @Test(arguments: [0.92, 0.94, 0.08, 0.2, 0.75])
    func soloP1LinksWhileSomeoneStandsOutsideTheBox(bystanderX: Double) throws {
        for bystander in [F.candidate(30, x: bystanderX), Self.partial(30, x: bystanderX)] {
            var t = try Self.solo()
            let r = try Self.feed(&t, [F.candidate(10, x: 0.5), bystander])
            #expect(r.player1.state == .tracking && r.player1.candidateID == 10, "bystander at \(bystanderX) ignored")
        }
    }

    /// Just outside the zone is ignored; inside it (even within the hysteresis margin) a second
    /// person in the box refuses, never guessing who P1 is.
    @Test func soloBoundaryIsExactAndASecondPersonInTheBoxRefuses() throws {
        let zone = PlayerAcquisitionZones.zone(.player1, solo: true)
        var outside = try Self.solo()
        #expect(try Self.feed(&outside, [F.candidate(10, x: 0.5), F.candidate(30, x: zone.lowerBound - 0.01)])
            .player1.candidateID == 10)
        var inside = try Self.solo()
        #expect(try Self.feed(&inside, [F.candidate(10, x: 0.5), F.candidate(30, x: zone.lowerBound + 0.01)])
            .player1.state == .unbound)
    }

    // MARK: Co-op

    /// The reported scene: P1 in the left box (camera right), a bystander at the camera's far
    /// edge, P2's box empty. Nobody is linked (co-op needs both), the bystander is never a player,
    /// and once P2 steps in the pair links as P1 and P2.
    @Test func coopNeverMakesAnOutsidePersonAPlayer() throws {
        var t = try F.tracker()
        for (start, bystander) in [(1, F.candidate(30, x: 0.92)), (10, Self.partial(30, x: 0.94))] {
            let r = try Self.feed(&t, [F.candidate(10, x: 0.65), bystander], frames: 5, from: start)
            #expect(r.player1.state == .unbound && r.player2.state == .unbound, "co-op waits for P2")
            #expect(r.player1.candidateID != 30 && r.player2.candidateID != 30)
        }
        let r = try Self.feed(&t, [F.candidate(10, x: 0.65), F.candidate(30, x: 0.92), F.candidate(20, x: 0.3)], from: 20)
        #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20, "the outside person stays outside")
    }

    @Test(arguments: [0.92, 0.5, 0.08])
    func coopLinksBothPlayersWhileSomeoneStandsOutsideTheBoxes(bystanderX: Double) throws {
        var t = try F.tracker()
        let r = try Self.feed(&t, F.pair + [F.candidate(30, x: bystanderX)])
        #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20, "bystander at \(bystanderX) ignored")
    }

    /// Someone who really steps into the empty P2 box is reassessed by the existing rules: they
    /// are the person in P2's box, so they link as P2.
    @Test func aPersonEnteringTheEmptyP2BoxIsReassessed() throws {
        var t = try F.tracker()
        try Self.feed(&t, [F.candidate(10, x: 0.65), F.candidate(30, x: 0.92)])
        let r = try Self.feed(&t, [F.candidate(10, x: 0.65), F.candidate(30, x: 0.3)], from: 10)
        #expect(r.player1.candidateID == 10 && r.player2.candidateID == 30)
    }

    @Test func twoPeopleInOneBoxRefuse() throws {
        var t = try F.tracker()
        let r = try Self.feed(&t, F.pair + [F.candidate(30, x: 0.62)])
        #expect(r.player1.state == .unbound && r.player2.state == .unbound)
    }

    /// The torso centre decides: an arm reaching past the box edge does not.
    @Test func anArmReachingOutsideTheBoxStillLinks() throws {
        var t = try F.tracker()
        var reaching = F.candidate(10, x: 0.75)
        var joints = reaching.joints
        joints[.leftWrist] = .init(x: 0.97, y: 0.5, confidence: 0.9)
        reaching = .init(candidateID: 10, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                         leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        let r = try Self.feed(&t, [reaching, F.candidate(20, x: 0.25)])
        #expect(r.player1.candidateID == 10 && r.player2.candidateID == 20)
    }

    // MARK: After linking

    /// A bystander appearing, flickering at the edge and leaving never changes who is who, and a
    /// linked player leaning out of their box keeps their identity (boxes decide linking only).
    @Test func identityIsStableWhileSomeoneComesAndGoesAtTheEdge() throws {
        var t = try F.bound()
        for i in 0..<12 {
            let people = i % 3 == 0 ? F.pair : F.pair + [i % 2 == 0 ? F.candidate(30, x: 0.95) : Self.partial(30, x: 0.94)]
            let r = try t.process(F.input(UInt64(10 + i), 0.25 + Double(i) * 0.125, people))
            #expect(r.player1.state == .tracking && r.player1.candidateID == 10 && !r.player1.requiresRebind)
            #expect(r.player2.state == .tracking && r.player2.candidateID == 20 && !r.player2.requiresRebind)
        }
        // P1 leans toward the edge (out of the drawn box) in small steps: still P1.
        var x = 0.75
        for i in 0..<6 {
            x += 0.02
            let r = try t.process(F.input(UInt64(40 + i), 2 + Double(i) * 0.125, [F.candidate(10, x: x), F.candidate(20, x: 0.25)]))
            #expect(r.player1.candidateID == 10 && r.player1.state == .tracking)
        }
        #expect(x > PlayerAcquisitionZones.zone(.player1, solo: false).upperBound - 0.01)
    }

    // MARK: The mask

    static func pose(_ candidates: [PoseCandidate]) throws -> (CameraPoseResult, PlayerTrackingSnapshot) {
        let f = try TrackingIntegrationFixture()
        let pose = try f.result(3, 0.25, candidates)
        return (pose, LiveVisionFixtures.association(pose, revision: 2))
    }

    /// Three instances (P1, P2, a bystander at the edge): each player gets their own instance and
    /// bounds; the bystander's instance is never anyone's region.
    @Test func eachPlayerGetsOnlyTheirOwnInstanceWithSomeoneElseInView() throws {
        let bystander = F.candidate(30, x: 0.95)
        let (pose, association) = try Self.pose(LiveVisionFixtures.standingPair + [bystander])
        // 20 columns: P2 0–7 (label 1), P1 8–16 (label 2), bystander 18–19 (label 3).
        let regions = PersonSegmenter.associate(pose: pose, association: association, labels: [1, 2, 3],
            bounds: [[0, 7, 0, 19], [8, 16, 0, 19], [18, 19, 0, 19]], width: 20, height: 20) { x, _ in
                x < 8 ? 1 : x <= 16 ? 2 : x >= 18 ? 3 : 0
            }
        #expect(regions[.player1]?.label == 2 && regions[.player2]?.label == 1)
        #expect(regions[.player1]?.maxX == 17.0 / 20, "P1's bounds stop at P1's own instance")
    }

    /// Vision merged a bystander into P1's instance (their torso lies on P1's label): P1 gets no
    /// region this frame (not separated), never a measurement that may include someone else.
    @Test func anInstanceSharedWithSomeoneElseIsRefused() throws {
        let overlapping = F.candidate(30, x: 0.7)
        let (pose, association) = try Self.pose(LiveVisionFixtures.standingPair + [overlapping])
        let regions = PersonSegmenter.associate(pose: pose, association: association, labels: [1, 2],
            bounds: [[0, 9, 0, 19], [10, 19, 0, 19]], width: 20, height: 20) { x, _ in x < 10 ? 1 : 2 }
        #expect(regions[.player1] == nil, "merged with the bystander")
        #expect(regions[.player2]?.label == 1, "P2's own instance is unaffected")
    }

    // MARK: The drawn boxes

    /// The zones contain each drawn box's X range on every supported landscape iPad screen, and
    /// extend at most `margin` beyond the union of those boxes.
    @Test(arguments: [CGSize(width: 1210, height: 834), CGSize(width: 1366, height: 1024),
                      CGSize(width: 1180, height: 820), CGSize(width: 1194, height: 834)])
    func theZonesMatchTheDrawnBoxes(screen: CGSize) {
        let aspect: CGFloat = 16 / 9
        let fill = CalibrationStageLayout.canFill(in: screen, aspect: aspect)
        for (player, solo) in [(PlayerID.player1, false), (.player2, false), (.player1, true)] {
            let box = CalibrationStageLayout.boxRect(player, solo: solo, in: screen)
            let source = CalibrationStageLayout.sourceRect(for: box, in: screen, aspect: aspect, fill: fill)
            let zone = PlayerAcquisitionZones.zone(player, solo: solo)
            #expect(zone.contains(Double(source.minX)) && zone.contains(Double(source.maxX)),
                    "\(screen) \(player) solo \(solo): box \(source.minX)…\(source.maxX) in \(zone)")
            #expect(Double(source.minX) - zone.lowerBound <= PlayerAcquisitionZones.margin + 0.03
                    && zone.upperBound - Double(source.maxX) <= PlayerAcquisitionZones.margin + 0.03)
        }
    }
}
