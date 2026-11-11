import Foundation
import Testing
@testable import Sedactive

/// Safe accessors expose invalid reads without dereferencing native memory.
nonisolated struct AnatomicalSamplingSafetyTests {
  @Test(arguments: [Double.leastNonzeroMagnitude, Double.leastNormalMagnitude, 1e-20])
  func roundedTorsoCoordinateCannotReadPastMask(_ imageY: Double) throws {
    let fixture = try TrackingIntegrationFixture()
    var candidates = LiveVisionFixtures.standingPair
    let original = candidates[0]
    var joints = original.joints
    joints[.leftShoulder] = .init(x: 0.75, y: imageY, confidence: 0.9)
    candidates[0] = .init(candidateID: original.candidateID, joints: joints,
      maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
      rightFootBottomImageY: nil, maskAssociation: .unavailable)
    let pose = try fixture.result(3, 0.25, candidates)
    var invalidReads = 0
    let regions = PersonSegmenter.associate(pose: pose,
      association: LiveVisionFixtures.association(pose, revision: 2), labels: [1, 2],
      bounds: [[0, 49, 0, 99], [50, 99, 0, 99]], width: 100, height: 100) { x, y in
        guard (0..<100).contains(x), (0..<100).contains(y) else {
          invalidReads += 1; return 0
        }
        return x < 50 ? 1 : 2
      }
    #expect(regions.isEmpty)
    #expect(invalidReads == 0)
  }

  @Test(arguments: [BodyJoint.leftAnkle, .rightAnkle],
    [Double.leastNonzeroMagnitude, Double.leastNormalMagnitude, 1e-20])
  func roundedAnkleCoordinateCannotReadPastMask(_ joint: BodyJoint, _ imageY: Double) throws {
    let fixture = try TrackingIntegrationFixture()
    let pose = try fixture.result(3, 0.25, LiveVisionFixtures.standingPair)
    let original = pose.frame.candidates[0]
    var joints = original.joints
    joints[joint] = .init(x: joint == .leftAnkle ? 0.71 : 0.79,
      y: imageY, confidence: 0.9)
    let candidate = PoseCandidate(candidateID: original.candidateID, joints: joints,
      maskTopImageY: nil, maskBottomImageY: nil, leftFootBottomImageY: nil,
      rightFootBottomImageY: nil, maskAssociation: .unavailable)
    let region = PersonMaskRegion(candidateID: candidate.candidateID, label: 1,
      minX: 0.5, maxX: 1, minY: 0, maxY: 1)
    var invalidReads = 0
    let anatomy = BodyMeasurementExtractor.experimentalAnatomy(source: pose.source,
      controlRevision: 2, candidate: candidate, region: region, width: 100, height: 100) { x, y in
        guard (0..<100).contains(x), (0..<100).contains(y) else {
          invalidReads += 1; return 0
        }
        return 1
      }
    #expect(anatomy.leftSole.imageY == nil && anatomy.rightSole.imageY == nil)
    #expect(invalidReads == 0)
  }
}
