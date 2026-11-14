import Foundation

/// Resolution-based trial gates only. Not approved physical tolerances or B2 policy.
nonisolated enum AnatomicalCandidatePolicyV1 {
  static let version = "AnatomicalCandidatePolicyV1-EXPERIMENTAL"
  static let confidence = 0.5
  static let headRaySpreadPixels = 2
  static let minimumAnkleSeparationPixels = 4
  static let standingSpreadPixels = 3.0
  /// Head-top rays may differ by this share of the half ear span (scale-invariant): a round
  /// crown is ~0.1 of its radius lower at the eyes' columns than at the nose's, at any distance.
  static let headRaySpreadShare = 0.15
  /// The columns checked for something rising beside the head (raised hands, another person)
  /// lie this share of the ear span OUTSIDE the ears. Measured on the iPad (11 November 2026,
  /// facing the camera, hands down): head and hair reach 0.22–0.42 of the ear span beyond the
  /// ears, so the earlier 0.25 refused a normal head as "hands up". 0.6 = largest seen + ~40 %.
  /// Hands held above the head are still refused by `maximumCrownAboveEyesShare` (measured 0.84–0.92).
  static let headCorridorMarginShare = 0.6
  /// A head top no more than this many ear spans above the eyes (a head is ~0.7). Anything
  /// higher is a raised hand or object on the head, not the crown.
  static let maximumCrownAboveEyesShare = 1.2
  /// Policy V2 anatomical bands (shares of head-top-to-ankle span); see the extractor.
  static let minimumCrownAboveNoseShare = 0.06
  static let maximumCrownAboveNoseShare = 0.24
  static let maximumFootHeightShare = 0.15
}

/// Why one head-top or sole reading was refused, precisely enough to tell the players.
nonisolated enum AnatomicalRefusalDetail: String, Sendable, CaseIterable {
  case incompatibleSource
  case headLandmarksMissing, headLowConfidence, headTurned, headOffMask, headTopUneven, headCorridorBlocked, headCutOff
  case anklesMissing, anklesLowConfidence, feetTooClose, legsCrossed, ankleOffMask, soleNotBelowAnkle, feetJoined, feetCutOff
  // Policy V2.
  case headTopUnclear, headTopTooHigh, headTopTooLow, soleImplausible
}
nonisolated enum AnatomicalCandidateStatus: String, Sendable {
  case experimental, missingLandmarks, lowConfidence, ambiguous, truncated, incompatibleSource
}
nonisolated struct AnatomicalCandidateScalar: Equatable, Sendable {
  let imageY: Double?
  let status: AnatomicalCandidateStatus
  var detail: AnatomicalRefusalDetail? = nil
  static func refused(_ status: AnatomicalCandidateStatus, _ detail: AnatomicalRefusalDetail? = nil) -> Self {
    .init(imageY: nil, status: status, detail: detail)
  }
}
nonisolated struct AnatomicalPlayerCandidate: Equatable, Sendable {
  let source: CameraFrameMetadata
  let controlRevision: UInt64
  let candidateID: UInt64
  let crown, leftSole, rightSole: AnatomicalCandidateScalar
  /// Measurements behind the head/foot checks, for device diagnostics (never evidence):
  /// outline width beyond the ears above the eyes and head-top height above the eyes, both as
  /// shares of the ear span; the share of rows between the feet (ankle to sole) that are filled.
  var headBeyondEarsShare: Double? = nil
  var crownAboveEyesShare: Double? = nil
  var feetGapFilledShare: Double? = nil
  /// Head-top-to-nose and ankle-to-sole as shares of the head-top-to-ankle span (policy V2 checks).
  var crownAboveNoseShare: Double? = nil
  var footHeightShare: Double? = nil
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
    var beyondEars: Double?, aboveEyes: Double?, gapFilled: Double?, crownAboveNose: Double?, footHeight: Double?
    func result(_ crown: AnatomicalCandidateScalar, _ l: AnatomicalCandidateScalar,
      _ r: AnatomicalCandidateScalar) -> AnatomicalPlayerCandidate {
      .init(source: source, controlRevision: controlRevision, candidateID: candidate.candidateID,
        crown: crown, leftSole: l, rightSole: r, headBeyondEarsShare: beyondEars,
        crownAboveEyesShare: aboveEyes, feetGapFilledShare: gapFilled,
        crownAboveNoseShare: crownAboveNose, footHeightShare: footHeight)
    }
    guard width > 2, height > 2, width <= source.descriptor.width,
      height <= source.descriptor.height, !source.mirrored,
      source.rotationAngle == 0 || source.rotationAngle == 180,
      candidate.candidateID == region.candidateID, region.label != 0 else {
      let refused = AnatomicalCandidateScalar.refused(.incompatibleSource, .incompatibleSource)
      return result(refused, refused, refused)
    }
    func point(_ name: BodyJoint) -> (Int, Int)? {
      guard let p = candidate.joints[name], (try? p.validate()) != nil,
        p.confidence >= AnatomicalCandidatePolicyV1.confidence,
        p.x > 0, p.x < 1, p.y > 0, p.y < 1 else { return nil }
      let x = Int(p.x * Double(width)), y = Int((1 - p.y) * Double(height))
      // Strictly interior normalized values can still round to a mask boundary.
      guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
      return (x, y)
    }
    func failure(_ names: [BodyJoint], missing: AnatomicalRefusalDetail,
      low: AnatomicalRefusalDetail) -> AnatomicalCandidateScalar {
      names.contains(where: { candidate.joints[$0] == nil }) ? .refused(.missingLandmarks, missing)
        : .refused(.lowConfidence, low)
    }
    // HEAD-TOP (policy V2, 11 November 2026). Evidence gates only, then ONE scale-free anatomical
    // check against the same frame's ankles. The earlier silhouette-shape rules (side columns
    // beyond the ears, three-ray evenness, ear-scaled height) kept refusing normal hair and
    // depended on ear landmark placement; they are replaced, not re-tuned.
    let head: [BodyJoint] = [.nose, .leftEye, .rightEye]
    var crown = failure(head, missing: .headLandmarksMissing, low: .headLowConfidence)
    var crownRow: Int?, noseRow: Int?
    if let nose = point(.nose), let eyeA = point(.leftEye), let eyeB = point(.rightEye) {
      let face = [nose, eyeA, eyeB]
      let low = face.map(\.1).max()!, high = face.map(\.1).min()!
      if !(min(eyeA.0, eyeB.0) < nose.0 && nose.0 < max(eyeA.0, eyeB.0)) {
        crown = .refused(.ambiguous, .headTurned) // not facing the camera: nose not between the eyes
      } else if !(point(.neck).map { neck in neck.1 > low && (low...neck.1).allSatisfy({ labelAt(nose.0, $0) == region.label }) } ?? false)
        || !face.allSatisfy({ labelAt($0.0, $0.1) == region.label }) {
        crown = .refused(.ambiguous, .headOffMask) // face/neck landmarks not on this player's mask
      } else {
        var tops: [Int] = []
        for x in [eyeA.0, nose.0, eyeB.0] {
          guard labelAt(x, low) == region.label else { continue }
          var row = low
          while row > 0 && labelAt(x, row - 1) == region.label { row -= 1 }
          tops.append(row)
        }
        if tops.contains(0) { crown = .refused(.truncated, .headCutOff) }
        else if tops.count == 3, let top = tops.min(), tops.max()! < high {
          // The highest point of the head outline above the face (hair included, as a head is).
          crown = .init(imageY: 1 - Double(top) / Double(height), status: .experimental)
          crownRow = top; noseRow = nose.1
          if let earL = point(.leftEar), let earR = point(.rightEar), earL.0 != earR.0 {
            aboveEyes = Double(high - top) / Double(abs(earR.0 - earL.0))
          }
        } else {
          crown = .refused(.ambiguous, .headTopUnclear) // the outline does not rise above the eyes
        }
      }
    }
    let feet: [BodyJoint] = [.leftAnkle, .rightAnkle, .leftHip, .rightHip]
    var left = failure(feet, missing: .anklesMissing, low: .anklesLowConfidence), right = left
    if let la = point(.leftAnkle), let ra = point(.rightAnkle),
      let lh = point(.leftHip), let rh = point(.rightHip) {
      let dx = la.0 - ra.0, hipDX = lh.0 - rh.0
      var refusal: AnatomicalRefusalDetail?
      if abs(dx) < AnatomicalCandidatePolicyV1.minimumAnkleSeparationPixels { refusal = .feetTooClose }
      else if (dx > 0) != (hipDX > 0) || hipDX == 0 || la.1 <= lh.1 || ra.1 <= rh.1 { refusal = .legsCrossed }
      else if labelAt(la.0, la.1) != region.label || labelAt(ra.0, ra.1) != region.label { refusal = .ankleOffMask }
      left = .refused(.ambiguous, refusal); right = left
      if refusal == nil {
        let middle = (la.0 + ra.0) / 2
        do { // Diagnostic: how much of the column between the feet is filled, ankle row to soles.
          var bottom = max(la.1, ra.1)
          for ankle in [la, ra] {
            var b = ankle.1
            while b + 1 < height && labelAt(ankle.0, b + 1) == region.label { b += 1 }
            bottom = max(bottom, b)
          }
          let rows = min(la.1, ra.1)...bottom
          gapFilled = Double(rows.filter { labelAt(middle, $0) != 0 }.count) / Double(rows.count)
        }
        func foot(_ ankle: (Int, Int)) -> AnatomicalCandidateScalar {
          var bottom = ankle.1
          while bottom + 1 < height && labelAt(ankle.0, bottom + 1) == region.label { bottom += 1 }
          guard bottom < height - 1 else { return .refused(.truncated, .feetCutOff) }
          guard bottom > ankle.1 else { return .refused(.ambiguous, .soleNotBelowAnkle) }
          // Each sole is read straight down from its OWN ankle (independent left/right soles).
          // No background gap between the feet is required: on the iPad (11 November 2026) the
          // instance mask filled 100 % of the column between apart feet in every sample with
          // both ankles found, so that rule could never be met. Distinct, uncrossed ankles
          // (checked above) keep the two columns apart.
          let radius = max(1, abs(dx) / 2)
          let start = max(0, ankle.0 - radius), end = min(width - 1, ankle.0 + radius)
          for y in ankle.1...bottom {
            if (start == 0 && labelAt(0, y) == region.label)
              || (end == width - 1 && labelAt(width - 1, y) == region.label) { return .refused(.truncated, .feetCutOff) }
          }
          for x in start...end where labelAt(x, bottom) == region.label {
            if x == 0 || x == width - 1 { return .refused(.truncated, .feetCutOff) }
          }
          return .init(imageY: 1 - Double(bottom + 1) / Double(height), status: .experimental)
        }
        left = foot(la); right = foot(ra)
        if left.status == .ambiguous || right.status == .ambiguous {
          let detail = left.status == .ambiguous ? left.detail : right.detail
          left = .refused(.ambiguous, detail); right = left
        }
      }
    }
    // Anatomical plausibility, scale-free (works for adults and children, near or far): the
    // head-top above the nose, and each foot below its ankle, as shares of the same frame's
    // head-top-to-ankle span. Anthropometry: head-top to nose ~0.12 of stature (adults) to
    // ~0.17 (young children); ankle (malleolus) ~0.04 of stature, shoes included ~0.06.
    if let crownRow, let noseRow, let la = point(.leftAnkle), let ra = point(.rightAnkle) {
      let span = Double(max(la.1, ra.1) - crownRow)
      if span > 0 {
        let share = Double(noseRow - crownRow) / span
        crownAboveNose = share
        if share > AnatomicalCandidatePolicyV1.maximumCrownAboveNoseShare {
          crown = .refused(.ambiguous, .headTopTooHigh) // hands or an object above the head
        } else if share < AnatomicalCandidatePolicyV1.minimumCrownAboveNoseShare {
          crown = .refused(.ambiguous, .headTopTooLow) // outline cut at the head (lighting, background)
        }
        var feet: [Double] = []
        for (side, ankle) in [(left, la), (right, ra)] {
          if let y = side.imageY { feet.append(Double(Int(((1 - y) * Double(height)).rounded())) - Double(ankle.1)) }
        }
        if !feet.isEmpty {
          let foot = feet.max()! / span
          // Diagnostic only. A ≤ 0.15 limit refused 58/62 real samples on the iPad (measured
          // 0.125–0.22, median 0.164: Vision's ankle sits above the malleolus, shoes are in the mask).
          footHeight = foot
        }
      }
    }
    return result(crown, left, right)
  }
}
