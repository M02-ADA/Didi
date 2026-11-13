//
//  MascotPoseEnvelope.swift
//  Sedactive
//

import simd

/// Arm clearance for the mascot's oversized head, both colour variants (Codex's
/// `handoff/MascotPoseEnvelope.swift`, values unchanged). Its shoulders sit
/// under the cheeks, so an upper arm aimed straight up would pass through
/// the head. Rising arm directions are turned outward before the solver
/// aims the joints; downward ones are left alone, and the change eases in
/// over the first part of a raise, so arms never snap.
///
/// Presentation only: it reads and writes `RobotPoseTargets` (model space,
/// +Y up, +X = the avatar's anatomical right), never Vision joints, body
/// samples or anything the checker judges.
nonisolated enum MascotPoseEnvelope {
    static func apply(to targets: inout RobotPoseTargets) {
        for side in RobotPoseTargets.Side.allCases {
            let sign: Float = side == .right ? 1 : -1
            // More clearance when the trunk or head tilts toward the arm.
            let tilt = min(0.65, abs(targets.lean) + abs(targets.headRoll))
            if let upper = targets.upperArm[side] {
                targets.upperArm[side] = clearHead(upper, sideSign: sign, outwardPerRise: 6.4, tilt: tilt)
            }
            if let forearm = targets.forearm[side] {
                targets.forearm[side] = clearHead(forearm, sideSign: sign, outwardPerRise: 1.5, tilt: tilt)
            }
        }
    }

    private static func clearHead(_ vector: SIMD3<Float>, sideSign: Float,
                                  outwardPerRise: Float, tilt: Float) -> SIMD3<Float> {
        guard vector.y > 0 else { return vector }
        var adjusted = vector
        adjusted.x = sideSign * max(sideSign * vector.x, vector.y * outwardPerRise)
        let direction = simd_normalize(adjusted)
        // Fade the additional clearance in as the tracked limb rises.ooke
        let angle = tilt * min(1, max(0, vector.y * 3))
        let c = cos(angle), s = sin(angle) * sideSign
        let safe = SIMD3(c * direction.x + s * direction.y,
                         c * direction.y - s * direction.x, direction.z)
        // Ease in over the first part of a raise, including across-body gestures.
        // A forward arc keeps the blend defined for opposite horizontal headings.
        let raw = simd_normalize(vector)
        let ramp = min(1, raw.y / 0.30)
        let blend = ramp * ramp * (3 - 2 * ramp)
        var result = raw * (1 - blend) + safe * blend
        let opposition = max(0, -simd_dot(raw, safe))
        result.z -= 2 * blend * (1 - blend) * opposition
        return simd_normalize(result)
    }
}
