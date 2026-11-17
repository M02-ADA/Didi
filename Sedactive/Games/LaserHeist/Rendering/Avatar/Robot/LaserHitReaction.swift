//
//  LaserHitReaction.swift
//  Sedactive
//

import Foundation
import simd

/// One mascot's reaction to a laser HIT (14 November 2026): a comic electric zap, as ONE
/// timeline whose curves drive the body and the VFX together.
///
///     0     50 ms        ~110 ms            ~380 ms              600 ms
///     IMPACT │ hit-stop │ RECOIL peak │ SHUDDER decays │ squash → overshoot → settle
///     white body, burst   ring out, coral charge pulses   current fades, sparks fall   back to live
///
/// - Contact (0–50 ms): the joints hold their last pose (presentation hit-stop); the body
///   compresses at once, its own surface flashes hot white and a comic burst stamps the
///   strike, so the first frame already changes. The frozen white silhouette IS the impact.
/// - Charge (~50–460 ms): the white gives way to a coral glow of the body's own surface that
///   swells three times with the shudder (never a strobe), while the current runs from the
///   strike across the struck part and a shock ring travels out.
/// - Recoil: a damped impulse (peaks ~110 ms, small overshoot ~280 ms) tilts the body away
///   from its partner and toward the camera (the beam's direction of travel); the trunk and
///   head follow a little later (overlapping action).
/// - Shudder (~80–380 ms): 16 Hz, small, decaying, out of phase between root, trunk, head and
///   shoulders, so it reads as current through the body, not tracking jitter.
/// - Recovery (~300–600 ms): a squash into a dip, a small stretch overshoot, then exactly the
///   live pose again.
///
/// Presentation only: every value is an offset added to the live tracked pose (never a
/// replacement), from RealityKit render time. Nothing here is read by gameplay, verdicts,
/// `GameClock` or diamond contact (`RobotAvatarLayer.diamondContactBody` reads the pose
/// without it). Tuning values are temporary (Kevin, 14 November 2026), from Simulator frames.
nonisolated struct LaserHitReaction: Equatable, Sendable {
    /// Where the beam met the mascot: high beams (a missed DUCK) hit the upper body, low
    /// beams (a missed JUMP) the legs.
    enum Region: Equatable, Sendable { case upper, lower }

    /// The whole reaction, after which every offset is exactly zero.
    static let duration = 0.6
    /// The presentation hit-stop: the affected mascot's joints hold their last pose.
    static let hitStop = 0.05
    /// A HIT within this time of the last one is the same hit (no restart, no stacking).
    static let retriggerGuard = 0.15
    /// Shudder frequency (Hz): fast enough to read as vibration at 60 fps, slow enough not to strobe.
    static let shudderFrequency = 16.0

    let region: Region
    /// The screen side the body is knocked toward: +1 right, −1 left.
    let side: Float
    let reduceMotion: Bool
    /// Varies the arcs and sparks between hits (deterministic for one hit).
    let seed: UInt32

    init(region: Region, side: Float, reduceMotion: Bool, seed: UInt32 = 1) {
        self.region = region
        self.side = side < 0 ? -1 : 1
        self.reduceMotion = reduceMotion
        self.seed = seed
    }

    /// The reaction at one moment.
    struct Frame: Equatable, Sendable {
        /// The joints keep the pose they showed (hit-stop); the root still follows tracking.
        var holdsPose = false
        /// Added to the mascot's root (lane metres).
        var rootOffset: SIMD3<Float> = .zero
        /// Whole-body tilt about the feet, radians: `roll` counter-clockwise on screen,
        /// `pitch` with the top toward the camera.
        var roll: Float = 0
        var pitch: Float = 0
        /// Height over width (1: none), about the same volume.
        var squash: Float = 1
        /// Added to the pose targets (`RobotPoseTargets`): trunk tilt, head roll, shrug (radians),
        /// pelvis dip (lane metres).
        var lean: Float = 0
        var headRoll: Float = 0
        var shoulderShrug: Float = 0
        var pelvisDip: Float = 0
        /// VFX intensities, 0…1: the electric arcs, the body glow, the contact burst.
        var arcs: Float = 0
        var glow: Float = 0
        var flash: Float = 0
        /// The mascot's OWN surface (its material's emission, 0…1): `bodyFlash` the hot-white
        /// impact frame held through the hit-stop, `charge` the coral current that pulses
        /// through the body afterwards. Its colours and shape stay readable underneath.
        var bodyFlash: Float = 0
        var charge: Float = 0
        /// Whether residual sparks show (they fly on their own curve from `sparkStart`).
        var sparks = false

        static let rest = Frame()
        var isRest: Bool { self == .rest }
    }

    /// When the residual sparks leave the contact point, and how long they live.
    static let sparkStart = 0.04
    static let sparkLife = 0.42

    // MARK: - Curves

    static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// The recoil impulse: 0 until the hit-stop ends, peak 1 at ~110 ms, a small overshoot
    /// (~−0.22 at ~280 ms), then nothing. A damped spring's response to a kick.
    static func recoil(_ tau: Double) -> Double {
        let v = tau - hitStop
        guard v > 0 else { return 0 }
        return exp(-v / 0.11) * sin(2 * .pi * 3.0 * v) / 0.525
    }

    /// The shudder's envelope: attacks at ~90 ms, strongest at ~110 ms, decays, gone by ~400 ms.
    static func shudderEnvelope(_ tau: Double) -> Double {
        guard tau > 0.08 else { return 0 }
        return smooth(0.08, 0.11, tau) * exp(-max(0, tau - 0.11) / 0.12) * (1 - smooth(0.34, 0.40, tau))
    }

    /// The shudder at a phase offset (radians): staggered between body parts.
    static func shudder(_ tau: Double, phase: Double) -> Double {
        shudderEnvelope(tau) * sin(2 * .pi * shudderFrequency * (tau - 0.08) + phase)
    }

    /// Height-over-width: contact compression, a stretch with the recoil, then a dip into the
    /// recovery that springs past rest and settles.
    static func squash(_ tau: Double, contact: Double, recovery: Double) -> Double {
        let contactPart = -contact * (1 - smooth(0.03, 0.12, tau))
        let stretch = 0.03 * max(0, recoil(tau))
        let into = smooth(0.28, 0.38, tau)
        let v = max(0, tau - 0.38)
        let spring = tau < 0.38 ? 1 : cos(2 * .pi * 3.2 * v) * exp(-v / 0.09)
        return 1 + contactPart + stretch - recovery * into * spring
    }

    func frame(at tau: Double) -> Frame {
        guard tau >= 0, tau < Self.duration else { return .rest }
        let degrees = Float.pi / 180
        // Everything lands exactly on rest at the end.
        let end = Float(1 - Self.smooth(0.52, Self.duration, tau))
        let r = Float(Self.recoil(tau))
        let lagged = Float(Self.recoil(tau - 0.025)), late = Float(Self.recoil(tau - 0.045))
        var f = Frame()
        if reduceMotion {
            // A gentle nudge and highlight: no hit-stop, shudder, arcs or sparks.
            f.roll = -side * 2.5 * degrees * r * end
            f.squash = 1 + Float(Self.squash(tau, contact: 0.02, recovery: 0.015) - 1) * end
            f.glow = Float(0.4 * Self.smooth(0, 0.08, tau) * (1 - Self.smooth(0.2, 0.55, tau)))
            f.flash = Float(0.5 * (1 - Self.smooth(0, 0.25, tau)))
            // One soft coral tint that rises and fades: no white frame, no pulsing.
            f.charge = Float(0.55 * Self.smooth(0, 0.08, tau) * (1 - Self.smooth(0.18, 0.5, tau)))
            return f
        }
        let s0 = Float(Self.shudder(tau, phase: 0)), s1 = Float(Self.shudder(tau, phase: 1.3))
        let s2 = Float(Self.shudder(tau, phase: -1.1)), s3 = Float(Self.shudder(tau, phase: 2.2))
        f.holdsPose = tau < Self.hitStop
        switch region {
        case .upper:
            // Struck at the chest and head: the top snaps away, the head whips after it.
            f.roll = (-side * 9 * r - 4.5 * s0) * degrees * end
            f.pitch = 7 * degrees * r * end
            f.rootOffset = [side * 0.035 * r + 0.016 * s1, 0, 0.04 * r]
            f.lean = (side * 6 * lagged + 5 * s1) * degrees * end
            f.headRoll = (side * 11 * late + 9 * s2) * degrees * end
            f.shoulderShrug = (side * 7 * lagged + 9 * s3) * degrees * end
            f.squash = Float(Self.squash(tau, contact: 0.06, recovery: 0.07))
        case .lower:
            // Struck at the legs: kicked up off the deck, the top folds back over them.
            f.roll = (-side * 6 * r - 4.5 * s0) * degrees * end
            f.pitch = -4 * degrees * r * end
            f.rootOffset = [side * 0.02 * r + 0.016 * s1, 0.05 * max(0, r), 0.025 * r]
            f.lean = (side * 4 * lagged + 5 * s1) * degrees * end
            f.headRoll = (side * 6 * late + 8 * s2) * degrees * end
            f.shoulderShrug = (side * 9 * lagged + 10 * s3) * degrees * end
            f.squash = Float(Self.squash(tau, contact: 0.08, recovery: 0.07))
        }
        f.rootOffset *= end
        f.squash = 1 + (f.squash - 1) * end
        // The recovery dip, with its own small rebound.
        let v = tau - 0.34
        f.pelvisDip = v > 0 ? Float(0.03 * sin(.pi * min(1, v / 0.16)) * exp(-v / 0.2)) * end : 0
        // Arcs: on at contact, brightest with the shudder, gone by ~460 ms.
        let arcs = Self.smooth(0, 0.03, tau) * (1 - Self.smooth(0.26, 0.46, tau))
        f.arcs = Float(arcs * (0.75 + 0.25 * Self.shudderEnvelope(tau)))
        f.glow = Float(0.6 * Self.smooth(0, 0.02, tau) * (1 - Self.smooth(0.15, 0.5, tau)))
        // The contact burst holds at full strength through the hit-stop, then burns off.
        f.flash = Float(1 - Self.smooth(0.04, 0.13, tau))
        f.bodyFlash = Float(Self.bodyFlash(tau))
        f.charge = Float(Self.charge(tau))
        f.sparks = tau >= Self.sparkStart && tau < Self.sparkStart + Self.sparkLife
        return f
    }

    /// The impact frame on the mascot's own surface: full during the hit-stop (the frozen pose
    /// reads as a hot-white silhouette), gone by ~100 ms. One flash per hit.
    static func bodyFlash(_ tau: Double) -> Double {
        guard tau >= 0 else { return 0 }
        return 1 - smooth(0.035, 0.1, tau)
    }

    /// Current pulsing through the body after the flash: three soft swells at 6 Hz (peaks
    /// ~70, ~235 and ~400 ms) that never drop below 65 % of their decaying envelope, so it
    /// reads as charge, not a strobe; gone by ~460 ms, before the recovery settles.
    static func charge(_ tau: Double) -> Double {
        guard tau > 0.03 else { return 0 }
        let envelope = smooth(0.03, 0.07, tau) * (1 - smooth(0.3, 0.46, tau))
        let pulse = 0.825 + 0.175 * cos(2 * .pi * 6 * (tau - 0.07))
        return envelope * pulse
    }

    /// Deterministic 0…1 noise for the arcs' and sparks' variation (no random state).
    static func noise(_ seed: UInt32, _ a: Int, _ b: Int = 0) -> Float {
        var h = seed &* 0x9E37_79B1 ^ UInt32(truncatingIfNeeded: a &* 0x85EB_CA6B) ^ UInt32(truncatingIfNeeded: b &* 0xC2B2_AE35)
        h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12; h = h &* 0x297A_2D39; h ^= h >> 15
        return Float(h % 10_000) / 10_000
    }
}
