import Foundation

/// Resolution-based trial gates only. Not approved physical tolerances or B2 policy.
nonisolated enum AnatomicalCandidatePolicyV1 {
  static let version = "AnatomicalCandidatePolicyV1-EXPERIMENTAL"
  static let confidence = 0.5
  static let headRaySpreadPixels = 2
  static let minimumAnkleSeparationPixels = 4
  static let standingSpreadPixels = 3.0
}
nonisolated enum AnatomicalCandidateStatus: String, Sendable {
  case experimental, missingLandmarks, lowConfidence, ambiguous, truncated, incompatibleSource
}
nonisolated struct AnatomicalCandidateScalar: Equatable, Sendable {
  let imageY: Double?
  let status: AnatomicalCandidateStatus
  static func refused(_ status: AnatomicalCandidateStatus) -> Self { .init(imageY: nil, status: status) }
}
nonisolated struct AnatomicalPlayerCandidate: Equatable, Sendable {
  let source: CameraFrameMetadata
  let controlRevision: UInt64
  let candidateID: UInt64
  let crown, leftSole, rightSole: AnatomicalCandidateScalar
  var experimentalReferences: StandingAnatomicalReferences? {
    guard crown.status == .experimental, leftSole.status == .experimental,
      rightSole.status == .experimental, let c = crown.imageY, let l = leftSole.imageY,
      let r = rightSole.imageY,
      [c, l, r].allSatisfy({ $0.isFinite && (0...1).contains($0) }), c > max(l, r) else { return nil }
    return .init(crownY: c, leftSoleY: l, rightSoleY: r, quality: .experimental)
  }
}

/// No image ownership or history. Accessor is synchronous and scoped to the existing locked mask.
/// All positives remain experimental: these 2D tests cannot certify a real head/foot or ground contact.
nonisolated enum AnatomicalCandidateExtractor {
  static func extract(source: CameraFrameMetadata, controlRevision: UInt64,
    candidate: PoseCandidate, region: PersonMaskRegion, width: Int, height: Int,
    labelAt: (Int, Int) -> UInt8) -> AnatomicalPlayerCandidate {
    func result(_ crown: AnatomicalCandidateScalar, _ l: AnatomicalCandidateScalar,
      _ r: AnatomicalCandidateScalar) -> AnatomicalPlayerCandidate {
      .init(source: source, controlRevision: controlRevision, candidateID: candidate.candidateID,
        crown: crown, leftSole: l, rightSole: r)
    }
    guard width > 2, height > 2, width <= source.descriptor.width,
      height <= source.descriptor.height, !source.mirrored,
      source.rotationAngle == 0 || source.rotationAngle == 180,
      candidate.candidateID == region.candidateID, region.label != 0 else {
      return result(.refused(.incompatibleSource), .refused(.incompatibleSource), .refused(.incompatibleSource))
    }
    func point(_ name: BodyJoint) -> (Int, Int)? {
      guard let p = candidate.joints[name], (try? p.validate()) != nil,
        p.confidence >= AnatomicalCandidatePolicyV1.confidence,
        p.x > 0, p.x < 1, p.y > 0, p.y < 1 else { return nil }
      return (Int(p.x * Double(width)), Int((1 - p.y) * Double(height)))
    }
    func failure(_ names: [BodyJoint]) -> AnatomicalCandidateScalar {
      .refused(names.contains(where: { candidate.joints[$0] == nil }) ? .missingLandmarks : .lowConfidence)
    }
    let head: [BodyJoint] = [.nose, .leftEye, .rightEye, .leftEar, .rightEar]
    var crown = failure(head)
    if head.allSatisfy({ point($0) != nil }) {
      let face = head.map { point($0)! }
      let xs = [face[1].0, face[0].0, face[2].0]
      let low = face.map(\.1).max()!, high = face.map(\.1).min()!
      let earMin = min(face[3].0, face[4].0), earMax = max(face[3].0, face[4].0)
      crown = .refused(.ambiguous)
      if Set(xs).count == 3, earMin < xs.min()!, earMax > xs.max()!,
        let neck = point(.neck), neck.1 > low,
        (low...neck.1).allSatisfy({ labelAt(face[0].0, $0) == region.label }),
        face.allSatisfy({ labelAt($0.0, $0.1) == region.label }) {
        var tops: [Int] = []
        for x in xs {
          guard labelAt(x, low) == region.label else { continue }
          var row = low
          while row > 0 && labelAt(x, row - 1) == region.label { row -= 1 }
          tops.append(row)
        }
        if tops.contains(0) { crown = .refused(.truncated) }
        else if tops.count == 3, let top = tops.min(), let bottom = tops.max(),
          bottom < high, bottom - top <= AnatomicalCandidatePolicyV1.headRaySpreadPixels {
          // Reject a silhouette that continues out of the head corridor above the observed face.
          var confined = true
          if top <= high {
            for y in top...high {
              if labelAt(earMin, y) != 0 || labelAt(earMax, y) != 0 { confined = false }
            }
          }
          if confined { crown = .init(imageY: 1 - Double(top) / Double(height), status: .experimental) }
        }
      }
    }
    let feet: [BodyJoint] = [.leftAnkle, .rightAnkle, .leftHip, .rightHip]
    var left = failure(feet), right = failure(feet)
    if let la = point(.leftAnkle), let ra = point(.rightAnkle),
      let lh = point(.leftHip), let rh = point(.rightHip) {
      left = .refused(.ambiguous); right = left
      let dx = la.0 - ra.0, hipDX = lh.0 - rh.0
      if abs(dx) >= AnatomicalCandidatePolicyV1.minimumAnkleSeparationPixels,
        (dx > 0) == (hipDX > 0), hipDX != 0,
        la.1 > lh.1, ra.1 > rh.1,
        labelAt(la.0, la.1) == region.label, labelAt(ra.0, ra.1) == region.label {
        let middle = (la.0 + ra.0) / 2
        func foot(_ ankle: (Int, Int)) -> AnatomicalCandidateScalar {
          var bottom = ankle.1
          while bottom + 1 < height && labelAt(ankle.0, bottom + 1) == region.label { bottom += 1 }
          guard bottom < height - 1 else { return .refused(.truncated) }
          guard bottom > ankle.1 else { return .refused(.ambiguous) }
          // Every below-ankle row must have a background separator between the two feet.
          for y in min(la.1, ra.1)...bottom {
            if labelAt(middle, y) != 0 { return .refused(.ambiguous) }
          }
          let radius = max(1, abs(dx) / 2)
          let start = max(0, ankle.0 - radius), end = min(width - 1, ankle.0 + radius)
          for y in ankle.1...bottom {
            if (start == 0 && labelAt(0, y) == region.label)
              || (end == width - 1 && labelAt(width - 1, y) == region.label) { return .refused(.truncated) }
          }
          for x in start...end where labelAt(x, bottom) == region.label {
            if x == 0 || x == width - 1 { return .refused(.truncated) }
            if (x < middle) != (ankle.0 < middle) { return .refused(.ambiguous) }
          }
          return .init(imageY: 1 - Double(bottom + 1) / Double(height), status: .experimental)
        }
        left = foot(la); right = foot(ra)
        if left.status == .ambiguous || right.status == .ambiguous { left = .refused(.ambiguous); right = left }
      }
    }
    return result(crown, left, right)
  }
}
