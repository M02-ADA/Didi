import Foundation
import Testing
@testable import Sedactive

/// EVIDENCE (13 November 2026, co-op calibration with a parent and a much shorter child): the
/// REAL `CalibrationSession` with SYNTHETIC pose, mask and anatomy fixtures. P1 is the existing
/// adult fixture; P2 is the same body scaled to `share` of its height about the floor (sole 0.1),
/// as a shorter person at the same distance appears. Heights are test scenarios, not product
/// values. Nothing here says how Vision's confidence behaves for a small person on the iPad.
nonisolated struct ParentChildCalibrationEvidenceTests {
    static let floorY = 0.1

    /// The standing pair with P2's joints scaled toward the floor.
    static func pair(childShare share: Double) -> [PoseCandidate] {
        LiveVisionFixtures.standingPair.map { c in
            guard c.candidateID == 20 else { return c }
            var joints = c.joints
            for (joint, point) in joints {
                joints[joint] = .init(x: point.x, y: floorY + (point.y - floorY) * share, confidence: point.confidence)
            }
            return .init(candidateID: c.candidateID, joints: joints, maskTopImageY: nil, maskBottomImageY: nil,
                         leftFootBottomImageY: nil, rightFootBottomImageY: nil, maskAssociation: .unavailable)
        }
    }

    /// Ten paired samples; P2's mask and head-top follow its own (scaled) body.
    static func collect(childShare share: Double, weakChildFrameAt weak: Int? = nil) throws -> CalibrationSession {
        let (f, initial, stamp) = try LiveVisionFixtures.sessionFixture(); var session = initial
        for i in 0..<10 {
            let pose = try f.result(UInt64(i + 3), Double(i) * 0.25 + 0.25, pair(childShare: share))
            let started = session.beginSample(stamp, source: pose.source, at: pose.source.capturedAt); try #require(started)
            var mask = LiveVisionFixtures.withAnatomy(LiveVisionFixtures.mask(pose), pose: pose, revision: stamp.bindingRevision)
            let top = floorY + (0.9 - floorY) * share
            if let region = mask.regions[.player2] {
                var regions = mask.regions
                regions[.player2] = .init(candidateID: region.candidateID, label: region.label, minX: region.minX,
                                          maxX: region.maxX, minY: region.minY, maxY: top)
                let anatomy = mask.anatomy, rows = mask.maskHeight
                mask = PersonMaskObservation(source: mask.source, quality: mask.quality, regions: regions,
                                             outputBytes: mask.outputBytes, serviceSeconds: mask.serviceSeconds)
                mask.anatomy = anatomy; mask.maskHeight = rows
            }
            if let a = mask.anatomy[.player2] {
                mask.anatomy[.player2] = .init(source: a.source, controlRevision: a.controlRevision, candidateID: a.candidateID,
                                               crown: .init(imageY: top, status: .experimental), leftSole: a.leftSole, rightSole: a.rightSole)
            }
            if i == weak {
                // One frame in which the child's tracking is uncertain (the tracker's pair-level rule).
                session.uncertain()
                continue
            }
            session.observe(mask, pose: pose, association: LiveVisionFixtures.association(pose, revision: stamp.bindingRevision),
                            stamp: stamp, at: pose.source.capturedAt + 0.01)
        }
        return session
    }

    @Test(arguments: [1.0, 0.75, 0.6]) func eachPlayerIsMeasuredFromTheirOwnBody(childShare share: Double) throws {
        let session = try Self.collect(childShare: share)
        let candidate = try #require(session.candidate, "child at \(share) of the adult's height: a candidate after 10 samples")
        #expect(candidate.acceptance == .stableEstimate, "accepted for both, each by their own proportions (\(candidate.acceptance))")
        let adult = try #require(candidate.players[.player1]?.anatomy), child = try #require(candidate.players[.player2]?.anatomy)
        let adultHeight = adult.crownY - adult.leftSoleY, childHeight = child.crownY - child.leftSoleY
        print(String(format: "[ParentChildEvidence] share %.2f · adult head-top→sole %.3f · child %.3f image heights", share, adultHeight, childHeight))
        #expect(abs(childHeight / adultHeight - share) < 0.01, "the child's reference is their own, not the adult's")
    }

    /// A single uncertain frame (either player) restarts BOTH windows today (Edo's pair rule):
    /// the adult's nine stable samples are lost with the child's.
    @Test func oneUncertainFrameRestartsBothPlayersWindows() throws {
        let session = try Self.collect(childShare: 0.6, weakChildFrameAt: 8)
        #expect(session.candidate == nil)
        #expect(session.players[.player1]?.samples ?? 0 <= 1 && session.players[.player2]?.samples ?? 0 <= 1,
                "both restarted (P1 \(session.players[.player1]?.samples ?? -1), P2 \(session.players[.player2]?.samples ?? -1))")
    }
}
