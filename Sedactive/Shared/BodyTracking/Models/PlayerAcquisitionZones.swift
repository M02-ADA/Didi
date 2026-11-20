import CoreGraphics
import Foundation

/// Where a player may be linked: the calibration stage's standing boxes, in the camera image's
/// own normalized X (the unmirrored source; the preview is mirrored for display, so P1's box on
/// the left of the screen is the right side of the image).
///
/// - The anchor is a body's torso centre (the mean of its visible shoulders and hips), so an arm
///   reaching past the edge, or a bystander's partly visible limbs, never decides anything.
/// - Each zone is derived from the drawn boxes through the stage's own display transform
///   (`CalibrationStageLayout`: aspect fill when it keeps both boxes on the image, otherwise the
///   whole frame), for the delivered frame's width ÷ height. The built-in camera (1280 × 720) and
///   external cameras (staging, 20 November 2026: e.g. 960 × 720) therefore get the boxes the
///   players actually see. The tracker does not know the screen, so a zone is the union of the
///   box's X range on every supported landscape iPad (`screens`), widened by `margin`, so a player
///   standing at the edge of their box still counts. `CalibrationZoneGeometryTests` checks this.
/// - Zones decide LINKING only (who becomes P1/P2, and a Solo re-link). After linking, identity is
///   the tracker's: a linked player may lean or step outside their box mid-round.
/// - Height is not used: the boxes span the image's standing height, and a bystander at the edge
///   is excluded by X alone.
nonisolated enum PlayerAcquisitionZones {
    /// Hysteresis around the drawn boxes (about 15 % of a box's width).
    static let margin = 0.04
    /// The built-in camera's delivered frame (1280 × 720).
    static let builtInImageAspect = 16.0 / 9.0
    /// The supported landscape iPad screens (points): 11-inch (the Sketch artboard), 13-inch,
    /// 10.9-inch and the earlier 11-inch.
    static let screens = [CGSize(width: 1210, height: 834), CGSize(width: 1366, height: 1024),
                          CGSize(width: 1180, height: 820), CGSize(width: 1194, height: 834)]

    /// The union of a drawn box's X range in the unmirrored source on the supported screens, for a
    /// frame of `imageAspect` (width ÷ height; a non-positive or non-finite value means the
    /// built-in camera's).
    static func box(_ player: PlayerID, solo: Bool, imageAspect: Double = builtInImageAspect) -> ClosedRange<Double> {
        let aspect = CGFloat(imageAspect.isFinite && imageAspect > 0 ? imageAspect : builtInImageAspect)
        var lower = Double.infinity, upper = -Double.infinity
        for screen in screens {
            let fill = CalibrationStageLayout.canFill(in: screen, aspect: aspect)
            let drawn = CalibrationStageLayout.boxRect(solo ? .player1 : player, solo: solo, in: screen)
            let source = CalibrationStageLayout.sourceRect(for: drawn, in: screen, aspect: aspect, fill: fill)
            lower = min(lower, Double(source.minX))
            upper = max(upper, Double(source.maxX))
        }
        return lower...upper
    }

    static func zone(_ player: PlayerID, solo: Bool, imageAspect: Double = builtInImageAspect) -> ClosedRange<Double> {
        let box = box(player, solo: solo, imageAspect: imageAspect)
        return (box.lowerBound - margin)...(box.upperBound + margin)
    }

    /// The zone (player) a torso centre at normalized `x` belongs to, or nil (outside every box).
    static func player(atX x: Double, solo: Bool, imageAspect: Double = builtInImageAspect) -> PlayerID? {
        if solo { return zone(.player1, solo: true, imageAspect: imageAspect).contains(x) ? .player1 : nil }
        return PlayerID.allCases.first {
            zone($0, solo: false, imageAspect: imageAspect).contains(x) && (($0 == .player1) == (x > 0.5))
        }
    }

    /// The torso centre's normalized X from a pose candidate's confident core joints, if any.
    static func torsoCenterX(_ candidate: PoseCandidate, minimumConfidence: Double = 0.5) -> Double? {
        let xs = [BodyJoint.leftShoulder, .rightShoulder, .leftHip, .rightHip].compactMap { joint -> Double? in
            guard let p = candidate.joints[joint], p.confidence >= minimumConfidence else { return nil }
            return p.x
        }
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }
}
