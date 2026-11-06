//
//  LiveSyntheticPlayer.swift
//  Sedactive
//

#if DEBUG
import Foundation

/// A SYNTHETIC person in Vision's convention (upright, unmirrored image,
/// normalized, origin bottom-left; the person's left is image-right), for
/// Simulator checks and tests of the live gameplay path. Never live data.
nonisolated struct LiveSyntheticBody: Equatable, Sendable {
    var cx = 0.5, floor = 0.08, h = 0.8
    /// Feet off the floor and crouch depth, in image heights.
    var lift = 0.0, crouch = 0.0

    func person(aspect: Double) -> LivePerson {
        let base = floor + lift, sx = h / aspect
        let upper = { (y: Double) in base + y * h - crouch * h }
        let shoulderY = upper(0.78), hipY = base + 0.5 * h - crouch * h * 0.6
        func p(_ x: Double, _ y: Double) -> LivePoint { LivePoint(x: x, y: y, confidence: 0.9) }
        return LivePerson(joints: [
            .nose: p(cx, upper(0.9)), .neck: p(cx, upper(0.8)),
            .leftEar: p(cx + 0.04 * sx, upper(0.89)), .rightEar: p(cx - 0.04 * sx, upper(0.89)),
            .leftShoulder: p(cx + 0.1 * sx, shoulderY), .rightShoulder: p(cx - 0.1 * sx, shoulderY),
            .leftElbow: p(cx + 0.11 * sx, shoulderY - 0.16 * h), .rightElbow: p(cx - 0.11 * sx, shoulderY - 0.16 * h),
            .leftWrist: p(cx + 0.12 * sx, shoulderY - 0.32 * h), .rightWrist: p(cx - 0.12 * sx, shoulderY - 0.32 * h),
            .root: p(cx, hipY), .leftHip: p(cx + 0.05 * sx, hipY), .rightHip: p(cx - 0.05 * sx, hipY),
            .leftKnee: p(cx + 0.05 * sx, base + 0.27 * h), .rightKnee: p(cx - 0.05 * sx, base + 0.27 * h),
            .leftAnkle: p(cx + 0.05 * sx, base + 0.04 * h), .rightAnkle: p(cx - 0.05 * sx, base + 0.04 * h),
        ])
    }
}

/// Scripted reactions to one player's targets: crouch through DUCK crossings,
/// jump over JUMP crossings, and deliberately do nothing on every `missEvery`-th
/// target so a HIT can be seen too. Deterministic from game time.
nonisolated struct LiveSyntheticPlayer: Sendable {
    var body = LiveSyntheticBody()
    var missEvery: Int? = 4
    /// Jump height as a share of body height (0.13: a clear jump; 0.05: a small hop).
    var hop = 0.13

    func body(at time: Double, targets: [LaserTarget]) -> LiveSyntheticBody {
        var b = body
        for (index, target) in targets.sorted(by: { $0.crossingTime < $1.crossingTime }).enumerated() {
            if let missEvery, (index + 1) % missEvery == 0 { continue }
            let c = target.crossingTime
            switch target.requiredMove {
            case .duck:
                b.crouch = max(b.crouch, 0.2 * Self.plateau(time, c - 0.9, c - 0.5, c + 0.45, c + 0.8))
            case .jump:
                let u = (time - (c - 0.3)) / 0.6
                if u > 0, u < 1 { b.lift = max(b.lift, 4 * hop * body.h * u * (1 - u)) }
            }
        }
        return b
    }

    static func plateau(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        func s(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }
        if t <= a || t >= d { return 0 }
        if t < b { return s((t - a) / (b - a)) }
        return t <= c ? 1 : 1 - s((t - c) / (d - c))
    }
}
#endif
