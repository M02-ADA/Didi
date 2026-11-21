//
//  LaserTeamCalloutView.swift
//  Sedactive
//

import SwiftUI

// MARK: - Model

/// The one team callout on screen (PERFECT! / ZAPPED!). `GameplayScenePresenter` raises it in the
/// frame the completing verdict is shown (`LaserTeamOutcomeTracker`); a newer callout replaces an
/// older one, so they never pile up. Presentation only: no game state, score or timing lives here.
@MainActor @Observable
final class LaserTeamCalloutModel {
    struct Shown: Equatable {
        let serial: Int
        let kind: LaserTeamCalloutKind
        /// A DUCK/JUMP cue was on screen: the callout sits small, just under the HUD, clear of it.
        let compact: Bool
        let start: Date
        /// A cue appeared under a full-size callout: it gets out of the way from here.
        var yieldedAt: Date?
    }

    private(set) var shown: Shown?
    private var serial = 0

    func show(_ kind: LaserTeamCalloutKind, compact: Bool, at now: Date = .now) {
        serial += 1
        shown = Shown(serial: serial, kind: kind, compact: compact, start: now)
    }

    /// A DUCK/JUMP cue came up: a full-size callout in the cue's place leaves at once.
    func cueShownChanged(_ visible: Bool, at now: Date = .now) {
        guard visible, var current = shown, !current.compact, current.yieldedAt == nil else { return }
        current.yieldedAt = now
        shown = current
    }

    func finish(_ serial: Int) { if shown?.serial == serial { shown = nil } }
    func clear() { shown = nil }
}


// MARK: - Motion

/// Every pose of the callout as a pure function of its age, so the motion is deterministic, testable
/// and allocates nothing over time. Distances are in em (the word's font size).
///
/// PERFECT! — "YES! WE DID IT!" (0.95 s). The whole word is readable from the first frame: it
/// launches from below, small and stretched tall, overshoots high at 75 ms, lands squashed wide at
/// 0.13 s and rebounds, settled by 0.34 s, tipped one way then the other. On the landing a jelly
/// ripple runs through the letters (16 ms apart) while a striped victory seal pops up behind the
/// word, gold rays flash out past it, confetti is thrown from both ends and stars arc away. Then
/// one celebration hop runs left to right under a gleam, the "!" flipping a full turn as it hops.
/// Exit: a squash of anticipation, then it zips up and shrinks away. The letters sit on a gentle
/// arch, tilted with it, so the word has a smiling silhouette.
/// ZAPPED! — "OH NO! WE GOT ZAPPED!" (0.9 s), in step with the struck mascot (`LaserHitReaction`):
/// it bangs in from the left, oversized, squashed and tipped back, onto a comic burst; it lands hard
/// at the mascot's hit-stop (50 ms) and recoils tall at the mascot's recoil peak (110 ms). Two
/// electric flashes (the first with the mascot's white impact frame) light the letters and bring
/// out cartoon bolts; the word buzzes on twos with a decaying jolt, then wobbles and sags, singed,
/// while leftover static crackles across the letter tops in short arcs with spark pops. Exit: the letters drop off one by one. The lettering is slanted and irregular.
/// Reduce Motion: no scale, travel, shake, wave, burst or flicker; a short fade in and out with
/// static accents. The arch, the slant and the irregular letters are layout, not motion.
nonisolated enum LaserTeamCalloutMotion {
    struct WordPose: Equatable {
        var opacity = 1.0, scale = 1.0, scaleX = 1.0, scaleY = 1.0, x = 0.0, y = 0.0, rotation = 0.0
    }
    struct LetterPose: Equatable {
        var opacity = 1.0, scale = 1.0, scaleX = 1.0, scaleY = 1.0, x = 0.0, y = 0.0, rotation = 0.0
    }

    // PERFECT!
    /// The overshoot apex, then the landing that starts the ripple and the accents.
    static let perfectApex = 0.075, perfectLanding = 0.13
    static let rippleStart = 0.11, rippleStep = 0.016, rippleLength = 0.16
    static let waveStart = 0.4, waveStep = 0.026, waveHop = 0.17
    static let perfectExit = 0.76, perfectZip = 0.82
    // ZAPPED!: its impact and recoil land with the struck mascot's.
    static let zapImpact = LaserHitReaction.hitStop
    static let zapRecoil = 0.11
    static let flashCenters = [0.03, 0.2]
    static let flashHalfWidth = 0.035
    /// The buzz is stepped on twos (24 poses a second), like hand-drawn boiling lines.
    static let buzzRate = 24.0
    static let buzzUntil = 0.45
    static let zapFallStart = 0.64, zapFallStep = 0.025, zapFallLength = 0.22
    /// The comic lettering's forward slant (a shear, em per em).
    static let zapSlant = -0.16

    static let yieldFade = 0.12

    static func text(_ kind: LaserTeamCalloutKind) -> String { kind == .perfect ? "PERFECT!" : "ZAPPED!" }

    static func duration(_ kind: LaserTeamCalloutKind, reduceMotion: Bool) -> Double {
        reduceMotion ? 0.95 : kind == .perfect ? 0.95 : 0.9
    }

    /// The whole word at age `t` (seconds). `yield` is the age a cue appeared, if one did.
    static func word(_ kind: LaserTeamCalloutKind, at t: Double, reduceMotion: Bool, yield: Double? = nil) -> WordPose {
        var pose = WordPose()
        let end = duration(kind, reduceMotion: reduceMotion)
        guard t >= 0, t < end else { pose.opacity = 0; return pose }
        if reduceMotion {
            pose.opacity = min(ramp(t, 0, 0.12), 1 - ramp(t, end - 0.2, end))
        } else if kind == .perfect {
            let a = perfectApex, l = perfectLanding
            pose.opacity = ramp(t, 0, 0.02)
            // Launch (small, stretched tall, from below) → apex (big, still stretched, high) →
            // landing (squashed wide) → rebound → settle.
            pose.scale = keyframes(t, [(0, 0.5), (a, 1.22), (l, 1.0), (0.2, 1.05), (0.28, 0.99), (0.34, 1)], ease: easeOut)
            pose.scaleX = keyframes(t, [(0, 0.78), (a, 0.88), (l, 1.2), (0.2, 0.95), (0.28, 1.02), (0.34, 1)], ease: easeInOut)
            pose.scaleY = keyframes(t, [(0, 1.35), (a, 1.18), (l, 0.8), (0.2, 1.06), (0.28, 0.98), (0.34, 1)], ease: easeInOut)
            pose.y = keyframes(t, [(0, 0.45), (a, -0.02), (l, 0.03), (0.2, -0.04), (0.28, 0)], ease: easeOut)
            pose.rotation = keyframes(t, [(0, -8), (a, -5), (l, 3), (0.2, -1.5), (0.3, 0.5), (0.38, 0)], ease: easeInOut)
            // Exit: squash down (anticipation), then zip up and shrink away.
            let crouch = sin(.pi * phase(t, perfectExit, end)) * (1 - phase(t, perfectZip, end))
            let zip = easeIn(phase(t, perfectZip, end))
            pose.scaleX *= 1 + 0.08 * crouch
            pose.scaleY *= (1 - 0.12 * crouch) * (1 + 0.35 * zip)
            pose.scale *= 1 - 0.7 * zip
            pose.y += 0.05 * crouch - 0.6 * zip
            pose.rotation += 6 * zip
            pose.opacity *= 1 - zip * zip
        } else {
            let i = zapImpact, r = zapRecoil
            pose.opacity = ramp(t, 0, 0.02)
            // Bang in from the left, oversized and squashed, tipped back → slam (the mascot's
            // hit-stop) → recoil tall (the mascot's recoil peak) → settle.
            pose.scale = keyframes(t, [(0, 1.55), (i, 0.88), (r, 1.12), (0.18, 0.97), (0.26, 1)], ease: easeOut)
            pose.scaleX = keyframes(t, [(0, 1.3), (i, 1.22), (r, 0.9), (0.18, 1.04), (0.26, 1)], ease: easeInOut)
            pose.scaleY = keyframes(t, [(0, 0.7), (i, 0.78), (r, 1.14), (0.18, 0.97), (0.26, 1)], ease: easeInOut)
            pose.x = keyframes(t, [(0, -0.3), (i, 0.07), (r, -0.04), (0.18, 0.015), (0.26, 0)], ease: easeOut)
            pose.rotation = keyframes(t, [(0, -10), (i, 5), (r, -4), (0.18, 2), (0.26, 0)], ease: easeInOut)
            // The buzz: a stepped, decaying jolt.
            if t < buzzUntil {
                let step = Int(t * buzzRate), amp = exp(-t / 0.16)
                pose.x += 0.06 * amp * (hash(step, 1) * 2 - 1)
                pose.y += 0.04 * amp * (hash(step, 2) * 2 - 1)
                pose.rotation += 3.5 * amp * (hash(step, 3) * 2 - 1)
            }
            // Wobble and sag, singed.
            let w = t - 0.3
            if w > 0 { pose.rotation += 4 * exp(-w / 0.14) * sin(2 * .pi * 5 * w) }
            pose.y += 0.05 * easeOut(phase(t, 0.3, 0.6))
            pose.rotation += 5 * easeIn(phase(t, zapFallStart, end))
            pose.opacity *= 1 - phase(t, end - 0.08, end)
        }
        if let yield, t >= yield { pose.opacity *= max(0, 1 - (t - yield) / yieldFade) }
        return pose
    }

    /// One letter at word age `t`: its layout (PERFECT!'s arch, ZAPPED!'s jolted baseline, static
    /// under Reduce Motion too) plus its own motion.
    static func letter(_ kind: LaserTeamCalloutKind, index: Int, count: Int, at t: Double, reduceMotion: Bool) -> LetterPose {
        var pose = LetterPose()
        if kind == .perfect {
            // A gentle arch: the middle letters ride higher, each tilted along the curve.
            let u = count > 1 ? 2 * Double(index) / Double(count - 1) - 1 : 0
            pose.y = -0.1 * (1 - u * u)
            pose.rotation = 7 * u
        } else {
            pose.rotation = zapTilt[index % zapTilt.count]
            pose.y = zapBaseline[index % zapBaseline.count]
        }
        guard !reduceMotion else { return pose }
        if kind == .perfect {
            // The landing's jelly ripple, letter by letter.
            let r = t - rippleStart - Double(index) * rippleStep
            if r > 0, r < rippleLength {
                let keys = [0, 0.05, 0.1, rippleLength]
                pose.scaleY = keyframes(r, zip(keys, [1, 0.82, 1.1, 1]).map { ($0, $1) }, ease: easeInOut)
                pose.scaleX = keyframes(r, zip(keys, [1, 1.12, 0.95, 1]).map { ($0, $1) }, ease: easeInOut)
                pose.y += keyframes(r, zip(keys, [0, 0.05, -0.07, 0]).map { ($0, $1) }, ease: easeInOut)
            }
            // The celebration hop, left to right; the "!" flips a full turn in its hop.
            let w = phase(t, waveStart + Double(index) * waveStep, waveStart + Double(index) * waveStep + waveHop)
            if w > 0, w < 1 {
                let s = sin(.pi * w)
                pose.y -= 0.21 * s
                pose.scaleY *= 1 + 0.12 * s
                pose.scaleX *= 1 - 0.07 * s
                if index == count - 1 {
                    pose.rotation += 360 * easeInOut(w)
                    pose.scale *= 1 + 0.25 * s
                } else {
                    pose.rotation += (index.isMultiple(of: 2) ? -5 : 5) * s
                }
            }
        } else {
            // In a flash the letters jolt apart, a new pose every buzz step (deterministic).
            if t < buzzUntil, flash(at: t) > 0.2 {
                let step = Int(t * buzzRate)
                pose.rotation += 8 * (hash(index, step) * 2 - 1)
                pose.y += 0.08 * (hash(index + 11, step) * 2 - 1)
                pose.x += 0.04 * (hash(index + 17, step) * 2 - 1)
                pose.scale = 1 + 0.08 * hash(index + 23, step)
            }
            // Exit: the letters drop off one by one, spinning.
            let fall = phase(t, zapFallStart + Double(index) * zapFallStep, zapFallStart + Double(index) * zapFallStep + zapFallLength)
            if fall > 0 {
                pose.y += 0.7 * fall * fall - 0.08 * sin(.pi * min(1, fall * 2))
                pose.rotation += (index.isMultiple(of: 2) ? 1 : -1) * 28 * fall
                pose.opacity = 1 - fall * fall
            }
        }
        return pose
    }

    /// ZAPPED!'s electric flash, 0…1: two brief flashes (the first with the mascot's white impact
    /// frame), then none (no strobing).
    static func flash(at t: Double) -> Double {
        flashCenters.map { max(0, 1 - abs(t - $0) / flashHalfWidth) }.max() ?? 0
    }

    /// ZAPPED!'s bolts: from the first flash's peak (after the bang, when the word has shrunk back
    /// under the HUD bar), on in each flash and in a stepped flicker until 0.26 s.
    static func boltsOn(at t: Double, reduceMotion: Bool) -> Bool {
        if reduceMotion { return true }
        guard t >= flashCenters[0], t < 0.26 else { return false }
        return flash(at: t) > 0.05 || hash(Int(t * buzzRate), 41) > 0.45
    }

    /// PERFECT!'s gleam across the letters: 0…1 across the word, nil when not sweeping.
    static func shine(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.36, t <= 0.58 else { return nil }
        return easeInOut(phase(t, 0.36, 0.58))
    }

    /// The burst's progress 0…1 (PERFECT!'s stars from the landing, 0.11–0.72 s; ZAPPED!'s sparks
    /// 0–0.28 s).
    static func burst(_ kind: LaserTeamCalloutKind, at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion else { return nil }
        let (start, end) = kind == .perfect ? (rippleStart, 0.72) : (0.0, 0.28)
        guard t >= start, t <= end else { return nil }
        return phase(t, start, end)
    }

    /// PERFECT!'s victory seal behind the word: its scale (pops up on the landing with an
    /// overshoot, sits, then pops away by 0.6 s), nil when not shown.
    static func seal(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.09, t < 0.6 else { return nil }
        let pop = keyframes(t, [(0.09, 0.2), (0.17, 1.14), (0.24, 0.96), (0.3, 1)], ease: easeOut)
        let away = phase(t, 0.48, 0.6)
        return pop * (1 + 0.06 * sin(.pi * min(1, away * 2))) * (1 - easeIn(away))
    }

    /// PERFECT!'s confetti, thrown from the landing: seconds since it was thrown, 0…0.7.
    static func confetti(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.11, t < 0.81 else { return nil }
        return t - 0.11
    }

    /// PERFECT!'s gold rays behind the word, 0…1 (0.06–0.44 s).
    static func rays(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.06, t <= 0.44 else { return nil }
        return phase(t, 0.06, 0.44)
    }

    /// ZAPPED!'s comic burst behind the word: its scale (pops in big, sits, shrinks away by 0.36 s).
    static func plate(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0, t < 0.36 else { return nil }
        let pop = keyframes(t, [(0, 1.18), (zapImpact, 0.96), (zapRecoil, 1.04), (0.2, 1)], ease: easeOut)
        return pop * (1 - easeIn(phase(t, 0.24, 0.36))) * (1 + 0.06 * flash(at: t))
    }

    /// ZAPPED!'s aftermath crackle: leftover static hopping over the singed letter tops. Each of
    /// three arcs fires twice for 60 ms, hopping along the word with short gaps, done by 0.78 s.
    static let crackleWindows: [(arc: Int, start: Double)] = [(0, 0.3), (2, 0.39), (1, 0.48), (0, 0.57), (2, 0.65), (1, 0.72)]
    static let crackleLife = 0.06

    /// The crackle window lit at `t` (its index into `crackleWindows`) and its age 0…1; nil between
    /// them, under Reduce Motion and outside 0.3–0.78 s. At most one arc at a time: no strobing.
    static func crackle(at t: Double, reduceMotion: Bool) -> (window: Int, age: Double)? {
        guard !reduceMotion else { return nil }
        for (i, w) in crackleWindows.enumerated() where t >= w.start && t < w.start + crackleLife {
            return (i, (t - w.start) / crackleLife)
        }
        return nil
    }

    /// How singed ZAPPED!'s letters look, 0…1 (they darken at the foot after the flashes).
    static func singe(at t: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : easeOut(phase(t, 0.24, 0.4))
    }

    static let zapTilt: [Double] = [-7, 5, -4, 6, -5, 4, -8]
    static let zapBaseline: [Double] = [0.02, -0.04, 0.03, -0.02, 0.04, -0.03, 0]

    // MARK: Curves

    static func phase(_ t: Double, _ start: Double, _ end: Double) -> Double { min(1, max(0, (t - start) / (end - start))) }
    static func ramp(_ t: Double, _ start: Double, _ end: Double) -> Double { phase(t, start, end) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeIn(_ x: Double) -> Double { x * x * x }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Piecewise curve through (time, value) keys, each segment eased.
    static func keyframes(_ t: Double, _ keys: [(Double, Double)], ease: (Double) -> Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.0 {
            return a.1 + (b.1 - a.1) * ease(phase(t, a.0, b.0))
        }
        return last.1
    }
    /// Deterministic 0…1 noise.
    static func hash(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663) &+ 0x9E37_79B9_7F4A_7C15
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((h ^ (h >> 31)) % 10_000) / 10_000
    }
}

// MARK: - View

/// Where and how big the callout is, from the HUD's own scale (`GameplayHUD`: the Sketch artboard
/// 1210 × 834 pt), so it moves with the HUD on every viewport. Full size it sits on the HUD's title
/// line, in the DUCK/JUMP cue's place (the cue steps aside for a result, `LaserFeedback`): below the
/// top bar, above the mascots' heads (about 255 pt). Compact (a cue is up) it sits small just under
/// the top bar, clear of the cue.
nonisolated enum LaserTeamCalloutLayout {
    static func scale(_ size: CGSize) -> CGFloat { min(size.width / 1210, size.height / 834) }
    static func fontSize(compact: Bool, k: CGFloat) -> CGFloat { (compact ? 36 : 86) * k }
    static func center(compact: Bool, in size: CGSize) -> CGPoint {
        let k = scale(size)
        return CGPoint(x: size.width / 2, y: (compact ? 146 : 204) * k)
    }
}

struct LaserTeamCalloutView: View {
    let model: LaserTeamCalloutModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            #if DEBUG
            if let preview = Self.preview {
                // `-teamCalloutPreview perfect|zapped [age s] [compact] [reduced]`: the callout over the
                // running replay, frozen at one age (screenshots) or replayed every 2 s. Review only.
                TimelineView(.animation(paused: preview.age != nil)) { timeline in
                    let t = preview.age ?? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2)
                    Canvas { context, size in
                        LaserTeamCalloutPainter(kind: preview.kind, t: t, yield: nil, reduceMotion: preview.reduced || reduceMotion,
                            fontSize: LaserTeamCalloutLayout.fontSize(compact: preview.compact, k: LaserTeamCalloutLayout.scale(size)),
                            center: LaserTeamCalloutLayout.center(compact: preview.compact, in: size), compact: preview.compact).draw(in: &context)
                    }
                }
            }
            #endif
            if let shown = model.shown {
                let reduce = reduceMotion
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSince(shown.start)
                    let yield = shown.yieldedAt.map { $0.timeIntervalSince(shown.start) }
                    Canvas { context, size in
                        LaserTeamCalloutPainter(kind: shown.kind, t: t, yield: yield, reduceMotion: reduce,
                            fontSize: LaserTeamCalloutLayout.fontSize(compact: shown.compact, k: LaserTeamCalloutLayout.scale(size)),
                            center: LaserTeamCalloutLayout.center(compact: shown.compact, in: size), compact: shown.compact).draw(in: &context)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .task(id: shown.serial) {
                    // Leaves the view tree once played: no timeline keeps running afterwards.
                    let end = shown.yieldedAt.map { $0.timeIntervalSince(shown.start) + LaserTeamCalloutMotion.yieldFade }
                        ?? LaserTeamCalloutMotion.duration(shown.kind, reduceMotion: reduce)
                    try? await Task.sleep(for: .seconds(end + 0.05))
                    model.finish(shown.serial)
                }
                .accessibilityElement()
                .accessibilityLabel(shown.kind == .perfect ? "Perfect!" : "Zapped!")
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    #if DEBUG
    static let preview: (kind: LaserTeamCalloutKind, age: Double?, compact: Bool, reduced: Bool)? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-teamCalloutPreview") else { return nil }
        let rest = arguments.dropFirst(index + 1).prefix { !$0.hasPrefix("-") }
        return (rest.contains("zapped") ? .zapped : .perfect, rest.compactMap(Double.init).first,
                rest.contains("compact"), rest.contains("reduced"))
    }()
    #endif
}

/// Draws one frame of the callout as cartoon arcade lettering: a thick dark rim that merges the
/// letters into one sticker silhouette, a deep purple extruded slab under them, and a bevelled face
/// (a cream rim light on the top edges, a cel-shaded gradient, a candy glint). Around it,
/// PERFECT!'s seal, rays, confetti and stars or ZAPPED!'s comic burst, bolts, sparks and crackle. Drawn in
/// passes (all rims, then all slabs, then all faces) so no letter's rim covers its neighbour's face.
struct LaserTeamCalloutPainter {
    let kind: LaserTeamCalloutKind
    let t: Double
    let yield: Double?
    let reduceMotion: Bool
    let fontSize: CGFloat
    let center: CGPoint
    /// Small, under the top bar: the effects spread sideways, not up into the bar.
    var compact = false

    /// One word's colours: the face from top to foot, its rim light, the slab and the rim.
    struct Style {
        let face: [Color]
        let rimLight: Color
        let glow: Color
    }
    static let rim = Color(red: 0.11, green: 0.04, blue: 0.26)
    static let slab = Color(red: 0.27, green: 0.11, blue: 0.52)
    static let perfect = Style(face: [Color(red: 1, green: 0.93, blue: 0.42), Color(red: 1, green: 0.78, blue: 0.13),
                                      Color(red: 1, green: 0.52, blue: 0.1)],
                               rimLight: Color(red: 1, green: 0.98, blue: 0.84), glow: Color(red: 1, green: 0.78, blue: 0.2))
    static let zapped = Style(face: [Color(red: 1, green: 0.47, blue: 0.62), Color(red: 1, green: 0.23, blue: 0.5),
                                     Color(red: 0.96, green: 0.22, blue: 0.26)],
                              rimLight: Color(red: 1, green: 0.74, blue: 0.48), glow: Color(red: 1, green: 0.3, blue: 0.5))
    static let gold = Color(red: 1, green: 0.84, blue: 0.24)
    static let cream = Color(red: 1, green: 0.97, blue: 0.82)
    static let electric = Color(red: 0.49, green: 0.96, blue: 1)
    static let boltYellow = Color(red: 1, green: 0.96, blue: 0.6)
    static let sealColors = [Color(red: 0.62, green: 0.32, blue: 0.95), Color(red: 0.42, green: 0.17, blue: 0.78)]
    static let confettiColors = [Color(red: 1, green: 0.84, blue: 0.24), Color(red: 1, green: 0.97, blue: 0.82),
                                 Color(red: 1, green: 0.42, blue: 0.66), Color(red: 0.49, green: 0.96, blue: 1)]
    static let burstColors = [Color(red: 1, green: 0.85, blue: 0.35), Color(red: 1, green: 0.55, blue: 0.22)]
    /// How far above the word's centre any effect may reach, in em: the HUD's top bar ends about
    /// 0.93 em above it at full size (`LaserTeamCalloutLayout`).
    static let headroom: CGFloat = 0.85
    /// How far below it: the mascots' heads start about 0.7 em under the word's centre.
    static let footroom: CGFloat = 0.66

    /// Rim thickness and slab depth, in em.
    static let rimWidth: CGFloat = 0.1
    static let slabDepth: CGFloat = 0.13
    /// Twelve directions make a round, even rim.
    static let rimDirections: [CGSize] = (0..<12).map { i in
        let a = Double(i) / 12 * 2 * .pi
        return CGSize(width: cos(a), height: sin(a))
    }

    static func font(size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }

    func draw(in context: inout GraphicsContext) {
        let word = LaserTeamCalloutMotion.word(kind, at: t, reduceMotion: reduceMotion, yield: yield)
        guard word.opacity > 0.001 else { return }
        let f = fontSize
        let style = kind == .perfect ? Self.perfect : Self.zapped
        let characters = Array(LaserTeamCalloutMotion.text(kind))
        let glyphs = characters.map { context.resolve(Text(String($0)).font(Self.font(size: f)).foregroundStyle(.white)) }
        let widths = glyphs.map { $0.measure(in: CGSize(width: f * 2, height: f * 2)).width }
        // Tight: the rims overlap into one silhouette.
        let spacing = -0.03 * f
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, glyphs.count - 1))
        let height = f * 1.2
        let vertical: CGFloat = compact ? 0.55 : 1

        var ctx = context
        ctx.opacity = word.opacity
        ctx.translateBy(x: center.x + word.x * f, y: center.y + word.y * f)
        // The wide backdrops (rays, shockwave, comic burst) stay level and keep their own size, so
        // a tipped or popped word never swings them up into the HUD bar.
        var level = ctx
        ctx.rotate(by: .degrees(word.rotation))
        // Bolts tip with the word but keep their size (they never grow into the HUD bar).
        var tipped = ctx
        // Effects around the word scale with the pop but not with its squash.
        var around = ctx
        around.scaleBy(x: word.scale, y: word.scale)
        ctx.scaleBy(x: word.scale * word.scaleX, y: word.scale * word.scaleY)
        if kind == .zapped { ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: LaserTeamCalloutMotion.zapSlant, d: 1, tx: 0, ty: 0)) }

        drawBackGlow(in: &around, style: style, width: total, height: height)
        if kind == .perfect {
            drawRays(in: &level, width: total, height: height * vertical)
            drawSeal(in: &level, width: total, height: height * vertical)
        } else {
            drawPlate(in: &level, width: total, height: height * vertical)
            drawBolts(in: &tipped, width: total, height: height * vertical, front: false)
        }

        var x = -total / 2
        let letters: [(glyph: GraphicsContext.ResolvedText, center: CGPoint, pose: LaserTeamCalloutMotion.LetterPose)] =
            glyphs.enumerated().map { index, glyph in
                let pose = LaserTeamCalloutMotion.letter(kind, index: index, count: glyphs.count, at: t, reduceMotion: reduceMotion)
                let c = CGPoint(x: x + widths[index] / 2 + pose.x * f, y: pose.y * f)
                x += widths[index] + spacing
                return (glyph, c, pose)
            }
        let flash = kind == .zapped && !reduceMotion ? LaserTeamCalloutMotion.flash(at: t) : 0
        let rimRadius = Self.rimWidth * f, depth = Self.slabDepth * f
        // Pass 1: the rim around face and slab; pass 2: the slab; pass 3: the faces.
        for pass in 0..<3 {
            for letter in letters where letter.pose.opacity > 0.001 {
                var l = ctx
                l.opacity *= letter.pose.opacity
                l.translateBy(x: letter.center.x, y: letter.center.y)
                l.rotate(by: .degrees(letter.pose.rotation))
                l.scaleBy(x: letter.pose.scale * letter.pose.scaleX, y: letter.pose.scale * letter.pose.scaleY)
                switch pass {
                case 0:
                    l.addFilter(.colorMultiply(Self.rim))
                    for drop in [0, depth] {
                        for d in Self.rimDirections {
                            l.draw(letter.glyph, at: CGPoint(x: d.width * rimRadius, y: d.height * rimRadius + drop), anchor: .center)
                        }
                    }
                case 1:
                    l.addFilter(.colorMultiply(Self.slab))
                    for step in 1...3 { l.draw(letter.glyph, at: CGPoint(x: 0, y: depth * CGFloat(step) / 3), anchor: .center) }
                default:
                    drawFace(letter.glyph, in: &l, style: style, letterX: letter.center.x, wordWidth: total, flash: flash)
                }
            }
        }
        if kind == .perfect {
            drawConfetti(in: &level, width: total)
            drawStars(in: &around, width: total, height: height * vertical)
        }
        else {
            drawBolts(in: &tipped, width: total, height: height * vertical, front: true)
            drawSparks(in: &tipped, width: total, height: height * vertical)
            drawCrackle(in: &ctx, width: total)
        }
    }

    // MARK: Lettering

    private func drawFace(_ glyph: GraphicsContext.ResolvedText, in l: inout GraphicsContext, style: Style,
                          letterX: CGFloat, wordWidth: CGFloat, flash: Double) {
        let f = fontSize
        let box = CGRect(x: -f, y: -0.62 * f, width: 2 * f, height: 1.24 * f)
        let shine = kind == .perfect ? LaserTeamCalloutMotion.shine(at: t, reduceMotion: reduceMotion) : nil
        let singe = kind == .zapped ? LaserTeamCalloutMotion.singe(at: t, reduceMotion: reduceMotion) : 0
        l.drawLayer { layer in
            layer.clipToLayer { mask in mask.draw(glyph, at: .zero, anchor: .center) }
            // The rim light: the whole letter in it, then the body over it, set down a touch, so a
            // bright bevel stays along every top edge.
            layer.fill(Path(box), with: .color(style.rimLight))
            layer.drawLayer { body in
                body.clipToLayer { mask in mask.draw(glyph, at: CGPoint(x: 0.012 * f, y: 0.05 * f), anchor: .center) }
                // Cel shading: three flat bands, not a smooth airbrush.
                let bands: [(CGFloat, CGFloat, Color)] = [(-0.62, -0.12, style.face[0]), (-0.12, 0.16, style.face[1]), (0.16, 0.62, style.face[2])]
                for (top, bottom, color) in bands {
                    body.fill(Path(CGRect(x: box.minX, y: top * f, width: box.width, height: (bottom - top) * f)), with: .color(color))
                }
                if singe > 0 {
                    body.fill(Path(CGRect(x: box.minX, y: 0.1 * f, width: box.width, height: 0.52 * f)),
                              with: .linearGradient(Gradient(colors: [Self.rim.opacity(0), Self.rim.opacity(0.45 * singe)]),
                                                    startPoint: CGPoint(x: 0, y: 0.1 * f), endPoint: CGPoint(x: 0, y: 0.4 * f)))
                }
            }
            // A candy glint on each letter's upper left.
            var glint = Path(roundedRect: CGRect(x: -0.24 * f, y: -0.3 * f, width: 0.16 * f, height: 0.07 * f), cornerRadius: 0.035 * f)
            glint = glint.applying(CGAffineTransform(rotationAngle: -0.5))
            layer.fill(glint, with: .color(.white.opacity(0.85)))
            if let shine {
                // One diagonal gleam travelling across the whole word, letter by letter.
                let bandX = -wordWidth / 2 - 0.4 * f + (wordWidth + 0.8 * f) * shine - letterX
                var band = Path()
                band.move(to: CGPoint(x: bandX - 0.12 * f, y: box.maxY)); band.addLine(to: CGPoint(x: bandX + 0.18 * f, y: box.minY))
                band.addLine(to: CGPoint(x: bandX + 0.4 * f, y: box.minY)); band.addLine(to: CGPoint(x: bandX + 0.1 * f, y: box.maxY))
                band.closeSubpath()
                layer.fill(band, with: .color(.white.opacity(0.85)))
            }
            // A flash heats the letters white-hot; the dark rim keeps them readable.
            if flash > 0 { layer.fill(Path(box), with: .color(Self.cream.opacity(0.6 * flash))) }
        }
    }

    private func drawBackGlow(in ctx: inout GraphicsContext, style: Style, width: CGFloat, height: CGFloat) {
        let f = fontSize
        let strength: Double
        if kind == .perfect {
            strength = reduceMotion ? 0.3 : 0.28 + 0.3 * (LaserTeamCalloutMotion.rays(at: t, reduceMotion: false).map { sin(.pi * $0) } ?? 0)
        } else {
            strength = reduceMotion ? 0.25 : 0.22 + 0.4 * LaserTeamCalloutMotion.flash(at: t)
        }
        // Light, not paint: added over the dark corridor, and only as the word arrives.
        let arrival = reduceMotion ? 1 : LaserTeamCalloutMotion.ramp(t, 0.02, 0.14)
        guard arrival > 0 else { return }
        var glow = ctx
        glow.blendMode = .plusLighter
        let radius = width / 2 + 0.35 * f
        glow.scaleBy(x: 1, y: height / (2 * radius))
        glow.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)),
                  with: .radialGradient(Gradient(colors: [style.glow.opacity(strength * arrival), style.glow.opacity(0)]),
                                        center: .zero, startRadius: 0, endRadius: radius))
    }

    // MARK: PERFECT!

    /// Gold light rays fanning out behind the word on the landing, turning slowly as they fade.
    private func drawRays(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard !compact, let p = LaserTeamCalloutMotion.rays(at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize, e = LaserTeamCalloutMotion.easeOut(p)
        var r = ctx
        r.blendMode = .plusLighter
        let rx = width / 2 + 0.5 * f, ry = min(height / 2 + 0.3 * f, Self.headroom * f)
        // The longest ray (1.15 rx) ends exactly at `ry`: never up into the HUD bar.
        r.scaleBy(x: 1, y: ry / (rx * 1.15))
        let turn = 0.25 * e
        for i in 0..<14 {
            let a = Double(i) / 14 * 2 * .pi + turn
            let inner = rx * (0.3 + 0.2 * e), outer = rx * (0.6 + 0.55 * e) * (i.isMultiple(of: 2) ? 1 : 0.78)
            let half = i.isMultiple(of: 2) ? 0.1 : 0.065
            var wedge = Path()
            wedge.move(to: CGPoint(x: cos(a - half) * inner, y: sin(a - half) * inner))
            wedge.addLine(to: CGPoint(x: cos(a) * outer, y: sin(a) * outer))
            wedge.addLine(to: CGPoint(x: cos(a + half) * inner, y: sin(a + half) * inner))
            wedge.closeSubpath()
            r.fill(wedge, with: .color((i.isMultiple(of: 2) ? Self.cream : Self.gold).opacity((i.isMultiple(of: 2) ? 0.7 : 0.5) * sin(.pi * p))))
        }
    }

    /// The victory seal: a rounded, scalloped badge (not ZAPPED!'s spiky bang) in bright violet,
    /// with slowly turning sunburst stripes and a gold rim, popping up behind the word on the
    /// landing. It gives PERFECT! a solid shape to sit on, then pops away.
    private func drawSeal(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard !compact, let scale = LaserTeamCalloutMotion.seal(at: t, reduceMotion: reduceMotion), scale > 0.01 else { return }
        let f = fontSize
        // Raised a little: it shows above the letters, and its foot stays clear of the mascots.
        let lift = 0.09 * f
        let rx = (width / 2 + 0.42 * f) * scale, ry = min((height / 2 + 0.16 * f) * scale, Self.footroom * f + lift)
        var ctx = ctx
        ctx.translateBy(x: 0, y: -lift)
        var path = Path()
        let bumps = 22.0, points = 132
        for i in 0..<points {
            let a = Double(i) / Double(points) * 2 * .pi
            let r = 1 - 0.07 * (0.5 - 0.5 * cos(bumps * a))
            let p = CGPoint(x: cos(a) * rx * r, y: sin(a) * ry * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.stroke(path, with: .color(Self.rim), style: StrokeStyle(lineWidth: 0.16 * f, lineJoin: .round))
        ctx.fill(path, with: .radialGradient(Gradient(colors: Self.sealColors), center: .zero, startRadius: 0, endRadius: rx))
        var stripes = ctx
        stripes.clip(to: path)
        let turn = 0.6 * t
        for i in 0..<12 where i.isMultiple(of: 2) {
            let a0 = Double(i) / 12 * 2 * .pi + turn, a1 = Double(i + 1) / 12 * 2 * .pi + turn
            var wedge = Path()
            wedge.move(to: .zero)
            wedge.addLine(to: CGPoint(x: cos(a0) * rx * 1.2, y: sin(a0) * ry * 1.2))
            wedge.addLine(to: CGPoint(x: cos(a1) * rx * 1.2, y: sin(a1) * ry * 1.2))
            wedge.closeSubpath()
            stripes.fill(wedge, with: .color(.white.opacity(0.12)))
        }
        ctx.stroke(path, with: .color(Self.gold), style: StrokeStyle(lineWidth: 0.05 * f, lineJoin: .round))
    }

    /// Confetti thrown sideways and up from both ends of the word on the landing, tumbling as it
    /// falls back (14 chips: gold, cream, pink, cyan); never above the headroom.
    private func drawConfetti(in ctx: inout GraphicsContext, width: CGFloat) {
        guard !compact, let tau = LaserTeamCalloutMotion.confetti(at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize, gravity = 5.2 * f
        let fade = 1 - LaserTeamCalloutMotion.phase(tau, 0.5, 0.7)
        for i in 0..<14 {
            let h = { (k: Int) in CGFloat(LaserTeamCalloutMotion.hash(i, k)) }
            let side: CGFloat = i.isMultiple(of: 2) ? -1 : 1
            let x0 = side * (0.42 + 0.08 * h(1)) * width, y0 = -0.3 * f
            let vx = side * (1.1 + 1.4 * h(2)) * f, vy = -(1.5 + 0.5 * h(3)) * f
            let time = CGFloat(tau)
            let x = x0 + vx * time
            let y = min(Self.footroom * f, max(-Self.headroom * f + 0.08 * f, y0 + vy * time + 0.5 * gravity * time * time))
            var c = ctx
            c.opacity *= Double(fade)
            c.translateBy(x: x, y: y)
            let spin = Double(h(4) * 6 + 8) * tau * (side < 0 ? -1 : 1)
            c.rotate(by: .radians(spin))
            // Tumbling: the chip turns edge-on and back.
            let flip = max(0.15, abs(cos(spin * 1.7)))
            let chip = CGRect(x: -0.085 * f, y: -0.05 * f * flip, width: 0.17 * f, height: 0.1 * f * flip)
            c.fill(Path(roundedRect: chip.insetBy(dx: -0.018 * f, dy: -0.018 * f), cornerRadius: 0.03 * f), with: .color(Self.rim))
            c.fill(Path(roundedRect: chip, cornerRadius: 0.02 * f), with: .color(Self.confettiColors[i % Self.confettiColors.count]))
        }
    }

    /// Six chunky stars arcing away from the landing, twinkling; four quiet static ones under
    /// Reduce Motion.
    private func drawStars(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        let f = fontSize
        let rx = width / 2 + 0.15 * f, ry = height / 2
        if let p = LaserTeamCalloutMotion.burst(.perfect, at: t, reduceMotion: reduceMotion) {
            for i in 0..<6 {
                let side = i.isMultiple(of: 2) ? -1.0 : 1.0
                // Mostly sideways and up, from both ends.
                let a = (0.15 + 0.7 * Double(i / 2) / 2 + 0.08 * LaserTeamCalloutMotion.hash(i, 3)) * .pi / 2
                let travel = LaserTeamCalloutMotion.easeOut(p)
                let px = side * (cos(a) * rx * (0.8 + 0.55 * travel))
                let py = -sin(a) * ry * (0.5 + 0.9 * travel) + 0.45 * f * p * p
                let y = max(py, -Self.headroom * f + 0.15 * f)
                let twinkle = sin(.pi * min(1, p * 1.15)) * (0.85 + 0.15 * sin(18 * p + Double(i)))
                let size = (i < 2 ? 0.3 : 0.22) * f * twinkle
                star(in: &ctx, at: CGPoint(x: px, y: y), size: size, rotation: 140 * p * side,
                     color: i % 3 == 0 ? .white : Self.gold)
            }
        } else if reduceMotion {
            for (i, point) in [CGPoint(x: -1, y: -0.8), CGPoint(x: 1, y: -0.7), CGPoint(x: -0.9, y: 0.75), CGPoint(x: 0.95, y: 0.8)].enumerated() {
                star(in: &ctx, at: CGPoint(x: point.x * (rx + 0.1 * f), y: point.y * ry), size: 0.15 * f, rotation: Double(i) * 20, color: Self.gold)
            }
        }
    }

    private func star(in ctx: inout GraphicsContext, at point: CGPoint, size: CGFloat, rotation: Double, color: Color) {
        guard size > 0.5 else { return }
        var s = ctx
        s.translateBy(x: point.x, y: point.y)
        s.rotate(by: .degrees(rotation))
        var path = Path()
        for i in 0..<8 {
            let r = i.isMultiple(of: 2) ? size : size * 0.4
            let a = Double(i) / 8 * 2 * .pi - .pi / 2
            let p = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        s.stroke(path, with: .color(Self.rim), style: StrokeStyle(lineWidth: size * 0.3, lineJoin: .round))
        s.fill(path, with: .color(color))
    }

    // MARK: ZAPPED!

    /// The comic burst behind the word: a spiky warm-orange bang with a dark rim.
    private func drawPlate(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard !compact, let scale = LaserTeamCalloutMotion.plate(at: t, reduceMotion: reduceMotion), scale > 0.01 else { return }
        let f = fontSize
        let rx = (width / 2 + 0.28 * f) * scale, ry = min((height / 2 + 0.06 * f) * scale, Self.footroom * f)
        var path = Path()
        let spikes = 18
        for i in 0..<(spikes * 2) {
            let a = Double(i) / Double(spikes * 2) * 2 * .pi
            let r = i.isMultiple(of: 2) ? 1.0 : 0.74 + 0.1 * LaserTeamCalloutMotion.hash(i, 5)
            let p = CGPoint(x: cos(a) * rx * r, y: sin(a) * ry * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        var p = ctx
        p.rotate(by: .degrees(-6 + 20 * LaserTeamCalloutMotion.easeIn(LaserTeamCalloutMotion.phase(t, 0.24, 0.36))))
        p.stroke(path, with: .color(Self.rim), style: StrokeStyle(lineWidth: 0.09 * f, lineJoin: .round))
        p.fill(path, with: .radialGradient(Gradient(colors: Self.burstColors), center: .zero, startRadius: 0, endRadius: rx))
    }

    /// Cartoon lightning bolts, filled pale yellow with a dark rim and an electric glow: behind the
    /// word at its sides, in front at its top corners. A fresh pose each buzz step.
    private func drawBolts(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat, front: Bool) {
        guard LaserTeamCalloutMotion.boltsOn(at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize
        let step = reduceMotion ? 0 : Int(t * LaserTeamCalloutMotion.buzzRate)
        let lift: CGFloat = compact ? 0.45 : 1
        let all: [(CGPoint, Double, Bool)] = [
            (CGPoint(x: -width / 2 - 0.3 * f, y: -0.05 * f), -35, false),
            (CGPoint(x: width / 2 + 0.32 * f, y: 0.08 * f), 150, false),
            (CGPoint(x: -0.3 * width, y: -0.4 * f * lift), -15, true),
            (CGPoint(x: 0.36 * width, y: -0.36 * f * lift), 20, true),
        ]
        for (i, (anchor, angle, isFront)) in all.enumerated() where isFront == front && (!reduceMotion || i < 2) {
            var b = ctx
            let wobble = (LaserTeamCalloutMotion.hash(i, step) - 0.5) * 24
            b.translateBy(x: anchor.x, y: anchor.y)
            b.rotate(by: .degrees(angle + wobble))
            let s = (0.5 + 0.12 * LaserTeamCalloutMotion.hash(i + 5, step)) * f * (compact ? 0.7 : 1)
            if LaserTeamCalloutMotion.hash(i + 9, step) > 0.5 { b.scaleBy(x: -1, y: 1) }
            let path = Self.bolt.applying(CGAffineTransform(scaleX: s, y: s))
            var glow = b
            glow.blendMode = .plusLighter
            glow.stroke(path, with: .color(Self.electric.opacity(0.55)), style: StrokeStyle(lineWidth: 0.14 * f, lineJoin: .round))
            b.stroke(path, with: .color(Self.rim), style: StrokeStyle(lineWidth: 0.06 * f, lineJoin: .round))
            b.fill(path, with: .color(Self.boltYellow))
        }
    }

    /// The classic zig-zag bolt, 1 em long, pointing down from its anchor.
    static let bolt: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -0.12, y: -0.5)); p.addLine(to: CGPoint(x: 0.2, y: -0.5))
        p.addLine(to: CGPoint(x: 0.04, y: -0.08)); p.addLine(to: CGPoint(x: 0.24, y: -0.08))
        p.addLine(to: CGPoint(x: -0.14, y: 0.5)); p.addLine(to: CGPoint(x: -0.02, y: 0.06))
        p.addLine(to: CGPoint(x: -0.22, y: 0.06)); p.closeSubpath()
        return p
    }()

    /// Electric sparks spraying from the slam.
    private func drawSparks(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard let p = LaserTeamCalloutMotion.burst(.zapped, at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize
        for i in 0..<12 {
            let angle = (Double(i) + 0.5 * LaserTeamCalloutMotion.hash(i, 9)) / 12 * 2 * .pi
            let r0 = 0.95 + 0.55 * LaserTeamCalloutMotion.easeOut(p), r1 = r0 + 0.3 * (1 - p)
            let clampY = { (y: CGFloat) in min(Self.footroom * f, max(-Self.headroom * f, y)) }
            let a = CGPoint(x: cos(angle) * (width / 2 + 0.1 * f) * r0, y: clampY(sin(angle) * (height / 2) * 0.85 * r0))
            let b = CGPoint(x: cos(angle) * (width / 2 + 0.1 * f) * r1, y: clampY(sin(angle) * (height / 2) * 0.85 * r1))
            var line = Path(); line.move(to: a); line.addLine(to: b)
            ctx.stroke(line, with: .color(Self.rim.opacity(0.8 * (1 - p))), style: StrokeStyle(lineWidth: 0.1 * f, lineCap: .round))
            ctx.stroke(line, with: .color((i.isMultiple(of: 2) ? Self.electric : Self.boltYellow).opacity(1 - p)),
                       style: StrokeStyle(lineWidth: 0.05 * f, lineCap: .round))
        }
    }

    /// The aftermath crackle: one short electric arc at a time jumping between two neighbouring
    /// letter tops (pale yellow core, electric glow, dark rim), a spark pop at each end, a fresh
    /// jagged shape each buzz step. Drawn on the letters' own layer, so it rides their slant and sag.
    private func drawCrackle(in ctx: inout GraphicsContext, width: CGFloat) {
        guard !compact, let lit = LaserTeamCalloutMotion.crackle(at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize
        let window = LaserTeamCalloutMotion.crackleWindows[lit.window]
        // Spans over the letter tops: between Z–A–P, P–P–E and E–D–!.
        let spans: [(CGFloat, CGFloat)] = [(-0.42, -0.14), (-0.08, 0.18), (0.2, 0.44)]
        let (x0, x1) = spans[window.arc]
        let a = CGPoint(x: x0 * width, y: -0.42 * f), b = CGPoint(x: x1 * width, y: -0.4 * f)
        let step = Int(t * LaserTeamCalloutMotion.buzzRate)
        // Later windows are smaller: the charge is running out.
        let strength = CGFloat(1 - 0.35 * Double(lit.window) / Double(LaserTeamCalloutMotion.crackleWindows.count - 1))
        var arc = Path()
        arc.move(to: a)
        // A sharp zig-zag (alternating up and down kinks), lifted a little off the letters.
        for k in 1...4 {
            let s = CGFloat(k) / 5
            let lift = -0.12 * f * strength * sin(.pi * s)
            let kink = (k.isMultiple(of: 2) ? 1 : -1) * (0.08 + 0.08 * CGFloat(LaserTeamCalloutMotion.hash(k + 31 * lit.window, step))) * f * strength
            arc.addLine(to: CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s + lift + kink))
        }
        arc.addLine(to: b)
        var glow = ctx
        glow.blendMode = .plusLighter
        glow.stroke(arc, with: .color(Self.electric.opacity(0.7)), style: StrokeStyle(lineWidth: 0.17 * f * strength, lineCap: .round, lineJoin: .miter))
        ctx.stroke(arc, with: .color(Self.rim), style: StrokeStyle(lineWidth: 0.1 * f * strength, lineCap: .round, lineJoin: .miter))
        ctx.stroke(arc, with: .color(Self.boltYellow), style: StrokeStyle(lineWidth: 0.05 * f * strength, lineCap: .round, lineJoin: .miter))
        // Spark pops where the arc touches down: biggest as it strikes, shrinking as it ends.
        let pop = CGFloat(0.19 * (1 - 0.6 * lit.age)) * f * strength
        star(in: &ctx, at: a, size: pop, rotation: 20 * Double(step), color: .white)
        star(in: &ctx, at: b, size: pop * 0.8, rotation: -20 * Double(step), color: Self.boltYellow)
    }
}
