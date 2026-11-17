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
/// PERFECT! — a small arcade victory (1.0 s). The whole word bursts out of a squashed seed
/// (0.45×, wide and flat) to a tall stretched 1.32×, lands squashed, rebounds and settles by
/// 0.33 s; inside it the letters pop in a 22 ms cascade, each tipped the other way and righting
/// itself. A gold shockwave ring and a star burst go out on the pop; once settled the word wobbles
/// and the letters do one quick Mexican wave while a gleam sweeps across. Exit: a little dip, then
/// it zooms up and away.
/// ZAPPED! — a cartoon electric mishap (0.9 s). It slams in from 1.85× squashed flat, compresses,
/// rebounds tall and buzzes (a decaying jitter and wobble). Three short electric flashes in the
/// first 0.35 s jolt the letters, light them white and turn their rim electric cyan, with bolts and
/// sparks; then two little smoke puffs rise off the singed word and it droops away.
/// Reduce Motion: no scale, travel, shake, wave, burst or flicker; a short fade in and out with
/// static accents.
nonisolated enum LaserTeamCalloutMotion {
    struct WordPose: Equatable {
        var opacity = 1.0, scale = 1.0, scaleX = 1.0, scaleY = 1.0, x = 0.0, y = 0.0, rotation = 0.0
    }
    struct LetterPose: Equatable {
        var opacity = 1.0, scale = 1.0, scaleX = 1.0, scaleY = 1.0, y = 0.0, rotation = 0.0
    }

    static let letterCascade = 0.022
    static let letterPop = 0.22
    static let waveStart = 0.42, waveStep = 0.028, waveHop = 0.16
    static let yieldFade = 0.12
    static let flashCenters = [0.04, 0.17, 0.31]
    static let flashHalfWidth = 0.035

    static func text(_ kind: LaserTeamCalloutKind) -> String { kind == .perfect ? "PERFECT!" : "ZAPPED!" }

    static func duration(_ kind: LaserTeamCalloutKind, reduceMotion: Bool) -> Double {
        reduceMotion ? 0.95 : kind == .perfect ? 1.0 : 0.9
    }

    /// The whole word at age `t` (seconds). `yield` is the age a cue appeared, if one did.
    static func word(_ kind: LaserTeamCalloutKind, at t: Double, reduceMotion: Bool, yield: Double? = nil) -> WordPose {
        var pose = WordPose()
        let end = duration(kind, reduceMotion: reduceMotion)
        guard t >= 0, t < end else { pose.opacity = 0; return pose }
        if reduceMotion {
            pose.opacity = min(ramp(t, 0, 0.12), 1 - ramp(t, end - 0.2, end))
        } else if kind == .perfect {
            pose.opacity = ramp(t, 0, 0.04)
            pose.scale = keyframes(t, [(0, 0.45), (0.09, 1.32), (0.17, 0.9), (0.25, 1.06), (0.33, 1)], ease: easeOut)
            pose.scaleX = keyframes(t, [(0, 1.25), (0.09, 0.88), (0.17, 1.14), (0.25, 0.97), (0.33, 1)], ease: easeInOut)
            pose.scaleY = keyframes(t, [(0, 0.7), (0.09, 1.18), (0.17, 0.86), (0.25, 1.03), (0.33, 1)], ease: easeInOut)
            pose.rotation = keyframes(t, [(0.33, 0), (0.43, -4), (0.53, 3), (0.62, -1.5), (0.7, 0)], ease: easeInOut)
            // Exit: anticipation dip, then zoom up and away.
            let dip = phase(t, 0.8, 0.86), out = easeIn(phase(t, 0.86, end))
            pose.scale *= 1 - 0.06 * sin(.pi * dip) + 0.32 * out
            pose.y = -0.28 * out
            pose.opacity *= 1 - out
        } else {
            pose.opacity = ramp(t, 0, 0.03)
            pose.scale = keyframes(t, [(0, 1.85), (0.05, 0.8), (0.11, 1.14), (0.18, 0.95), (0.25, 1)], ease: easeOut)
            pose.scaleX = keyframes(t, [(0, 1.3), (0.05, 1.18), (0.11, 0.9), (0.18, 1.04), (0.25, 1)], ease: easeInOut)
            pose.scaleY = keyframes(t, [(0, 0.62), (0.05, 0.78), (0.11, 1.14), (0.18, 0.97), (0.25, 1)], ease: easeInOut)
            if t < 0.32 {
                pose.x = 0.22 * exp(-t / 0.085) * sin(2 * .pi * 19 * t)
                pose.rotation = 6 * exp(-t / 0.11) * sin(2 * .pi * 13 * t)
            }
            // Exit: droops and drops away, a little deflated.
            let out = easeIn(phase(t, 0.7, end))
            pose.rotation -= 7 * out
            pose.y = 0.18 * out
            pose.scaleY *= 1 - 0.15 * out
            pose.opacity *= 1 - out
        }
        if let yield, t >= yield { pose.opacity *= max(0, 1 - (t - yield) / yieldFade) }
        return pose
    }

    /// One letter at word age `t`.
    static func letter(_ kind: LaserTeamCalloutKind, index: Int, count: Int, at t: Double, reduceMotion: Bool) -> LetterPose {
        var pose = LetterPose()
        if kind == .zapped {
            // ZAPPED! keeps its irregular, jolted lettering (static under Reduce Motion too).
            pose.rotation = zapTilt[index % zapTilt.count]
            pose.y = zapBaseline[index % zapBaseline.count]
        }
        guard !reduceMotion else { return pose }
        if kind == .perfect {
            let u = t - Double(index) * letterCascade
            let tip = index.isMultiple(of: 2) ? -10.0 : 10.0
            pose.opacity = ramp(u, 0, 0.05)
            pose.scale = keyframes(u, [(0, 0.3), (0.1, 1.18), (0.16, 0.94), (letterPop, 1)], ease: easeOut)
            pose.y = keyframes(u, [(0, 0.4), (0.1, -0.2), (0.16, 0.05), (letterPop, 0)], ease: easeOut)
            pose.rotation = keyframes(u, [(0, tip), (0.1, -tip * 0.4), (letterPop, 0)], ease: easeOut)
            // The celebration wave: each letter hops once, left to right.
            let w = phase(t, waveStart + Double(index) * waveStep, waveStart + Double(index) * waveStep + waveHop)
            if w > 0, w < 1 {
                pose.y -= 0.13 * sin(.pi * w)
                pose.scaleY = 1 + 0.08 * sin(.pi * w)
                pose.scaleX = 1 - 0.05 * sin(.pi * w)
            }
        } else if t < 0.36, flash(at: t) > 0.2 {
            // During each flash the letters jolt, differently each frame (deterministic).
            let frame = Int(t * 30)
            pose.rotation += 7 * (hash(index, frame) * 2 - 1)
            pose.y += 0.07 * (hash(index + 11, frame) * 2 - 1)
            pose.scale = 1 + 0.06 * hash(index + 23, frame)
        }
        return pose
    }

    /// ZAPPED!'s electric flash, 0…1: three brief flashes, then none (no strobing).
    static func flash(at t: Double) -> Double {
        flashCenters.map { max(0, 1 - abs(t - $0) / flashHalfWidth) }.max() ?? 0
    }

    /// PERFECT!'s gleam across the letters: 0…1 across the word, nil when not sweeping.
    static func shine(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.36, t <= 0.58 else { return nil }
        return easeInOut(phase(t, 0.36, 0.58))
    }

    /// The burst's progress 0…1 (PERFECT!'s stars 0.06–0.75 s, ZAPPED!'s sparks 0–0.3 s).
    static func burst(_ kind: LaserTeamCalloutKind, at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion else { return nil }
        let (start, end) = kind == .perfect ? (0.06, 0.75) : (0.0, 0.3)
        guard t >= start, t <= end else { return nil }
        return phase(t, start, end)
    }

    /// PERFECT!'s shockwave ring on the pop, 0…1 (0.05–0.36 s).
    static func ring(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.05, t <= 0.36 else { return nil }
        return phase(t, 0.05, 0.36)
    }

    /// ZAPPED!'s smoke puffs off the singed word, 0…1 (0.3–0.85 s).
    static func smoke(at t: Double, reduceMotion: Bool) -> Double? {
        guard !reduceMotion, t >= 0.3, t <= 0.85 else { return nil }
        return phase(t, 0.3, 0.85)
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

/// Draws one frame of the callout: depth, outline, gradient letters with a gloss, the gleam or the
/// electric flicker, sparkles, ring, bolts or smoke. Drawn in passes so no letter's outline covers
/// its neighbour's face.
struct LaserTeamCalloutPainter {
    let kind: LaserTeamCalloutKind
    let t: Double
    let yield: Double?
    let reduceMotion: Bool
    let fontSize: CGFloat
    let center: CGPoint
    /// Small, under the top bar: the effects spread sideways, not up into the bar.
    var compact = false

    static let outline = Color(red: 0.17, green: 0.08, blue: 0.37)
    static let depth = Color(red: 0.10, green: 0.04, blue: 0.24)
    static let gold = [Color(red: 1, green: 0.97, blue: 0.68), Color(red: 1, green: 0.84, blue: 0.2), Color(red: 1, green: 0.58, blue: 0.08)]
    static let coral = [Color(red: 1, green: 0.66, blue: 0.62), Color(red: 1, green: 0.3, blue: 0.42), Color(red: 0.88, green: 0.1, blue: 0.3)]
    static let electric = Color(red: 0.49, green: 0.96, blue: 1)
    static let smokeColor = Color(red: 0.62, green: 0.56, blue: 0.78)
    /// How far above the word's centre any effect may reach, in em: the HUD's top bar ends about
    /// 0.93 em above it at full size (`LaserTeamCalloutLayout`).
    static let headroom: CGFloat = 0.85

    func draw(in context: inout GraphicsContext) {
        let word = LaserTeamCalloutMotion.word(kind, at: t, reduceMotion: reduceMotion, yield: yield)
        guard word.opacity > 0.001 else { return }
        let f = fontSize
        let font = Font.system(size: f, weight: .black, design: .rounded)
        let characters = Array(LaserTeamCalloutMotion.text(kind))
        let glyphs = characters.map { context.resolve(Text(String($0)).font(font).foregroundStyle(.white)) }
        let widths = glyphs.map { $0.measure(in: CGSize(width: f * 2, height: f * 2)).width }
        let spacing = -0.02 * f
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, glyphs.count - 1))
        let height = f * 1.2
        let vertical: CGFloat = compact ? 0.55 : 1

        var ctx = context
        ctx.opacity = word.opacity
        ctx.translateBy(x: center.x + word.x * f, y: center.y + word.y * f)
        ctx.rotate(by: .degrees(word.rotation))
        // Effects around the word scale with the pop but not with its squash.
        var around = ctx
        around.scaleBy(x: word.scale, y: word.scale)
        ctx.scaleBy(x: word.scale * word.scaleX, y: word.scale * word.scaleY)

        drawBackGlow(in: &around, width: total, height: height)
        if kind == .perfect { drawRing(in: &around, width: total, height: height * vertical) }
        else { drawBolts(in: &around, width: total, height: height) }

        var x = -total / 2
        let letters: [(glyph: GraphicsContext.ResolvedText, center: CGPoint, pose: LaserTeamCalloutMotion.LetterPose)] =
            glyphs.enumerated().map { index, glyph in
                let pose = LaserTeamCalloutMotion.letter(kind, index: index, count: glyphs.count, at: t, reduceMotion: reduceMotion)
                let c = CGPoint(x: x + widths[index] / 2, y: pose.y * f)
                x += widths[index] + spacing
                return (glyph, c, pose)
            }
        let ring = (0..<8).map { i -> CGSize in
            let a = Double(i) / 8 * 2 * .pi
            return CGSize(width: cos(a) * 0.08 * f, height: sin(a) * 0.08 * f)
        }
        let flash = kind == .zapped && !reduceMotion ? LaserTeamCalloutMotion.flash(at: t) : 0
        // Pass 1: the extruded depth; pass 2: the outline (electric cyan in a flash); pass 3: faces.
        for pass in 0..<3 {
            for letter in letters where letter.pose.opacity > 0.001 {
                var l = ctx
                l.opacity *= letter.pose.opacity
                l.translateBy(x: letter.center.x, y: letter.center.y)
                l.rotate(by: .degrees(letter.pose.rotation))
                l.scaleBy(x: letter.pose.scale * letter.pose.scaleX, y: letter.pose.scale * letter.pose.scaleY)
                switch pass {
                case 0:
                    l.addFilter(.colorMultiply(Self.depth))
                    for offset in ring { l.draw(letter.glyph, at: CGPoint(x: offset.width, y: offset.height + 0.11 * f), anchor: .center) }
                case 1:
                    l.addFilter(.colorMultiply(flash > 0.3 ? Self.electric : Self.outline))
                    for offset in ring { l.draw(letter.glyph, at: CGPoint(x: offset.width, y: offset.height), anchor: .center) }
                default:
                    drawFace(letter.glyph, in: &l, letterX: letter.center.x, wordWidth: total, flash: flash)
                }
            }
        }
        if kind == .perfect { drawSparkles(in: &around, width: total, height: height * vertical) }
        else {
            drawSparks(in: &around, width: total, height: height * vertical)
            drawSmoke(in: &around, width: total, height: height)
        }
    }

    private func drawFace(_ glyph: GraphicsContext.ResolvedText, in l: inout GraphicsContext, letterX: CGFloat,
                          wordWidth: CGFloat, flash: Double) {
        let f = fontSize
        let box = CGRect(x: -f, y: -0.62 * f, width: 2 * f, height: 1.24 * f)
        let colors = kind == .perfect ? Self.gold : Self.coral
        let shine = kind == .perfect ? LaserTeamCalloutMotion.shine(at: t, reduceMotion: reduceMotion) : nil
        l.drawLayer { layer in
            layer.clipToLayer { mask in mask.draw(glyph, at: .zero, anchor: .center) }
            layer.fill(Path(box), with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: box.minY + 0.2 * f),
                                                        endPoint: CGPoint(x: 0, y: box.maxY - 0.22 * f)))
            // Gloss on the upper part of each letter, like a candy shell.
            layer.fill(Path(CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 0.46)),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.55), .white.opacity(0.06)]),
                                             startPoint: CGPoint(x: 0, y: box.minY), endPoint: CGPoint(x: 0, y: box.midY)))
            if let shine {
                // One diagonal gleam travelling across the whole word, letter by letter.
                let bandX = -wordWidth / 2 - 0.4 * f + (wordWidth + 0.8 * f) * shine - letterX
                var band = Path()
                band.move(to: CGPoint(x: bandX - 0.12 * f, y: box.maxY)); band.addLine(to: CGPoint(x: bandX + 0.18 * f, y: box.minY))
                band.addLine(to: CGPoint(x: bandX + 0.4 * f, y: box.minY)); band.addLine(to: CGPoint(x: bandX + 0.1 * f, y: box.maxY))
                band.closeSubpath()
                layer.fill(band, with: .color(.white.opacity(0.8)))
            }
            if flash > 0 { layer.fill(Path(box), with: .color(.white.opacity(0.45 * flash))) }
        }
    }

    private func drawBackGlow(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        let f = fontSize
        let strength: Double
        let color: Color
        if kind == .perfect {
            strength = reduceMotion ? 0.3 : 0.3 + 0.25 * (LaserTeamCalloutMotion.burst(.perfect, at: t, reduceMotion: false).map { sin(.pi * $0) } ?? 0)
            color = Self.gold[1]
        } else {
            strength = reduceMotion ? 0.25 : 0.22 + 0.4 * LaserTeamCalloutMotion.flash(at: t)
            color = Self.coral[1]
        }
        // Light, not paint: added over the dark corridor, and only as the word arrives.
        let arrival = reduceMotion ? 1 : LaserTeamCalloutMotion.ramp(t, 0.02, 0.16)
        guard arrival > 0 else { return }
        var glow = ctx
        glow.blendMode = .plusLighter
        let radius = width / 2 + 0.35 * f
        glow.scaleBy(x: 1, y: height / (2 * radius))
        glow.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)),
                  with: .radialGradient(Gradient(colors: [color.opacity(strength * arrival), color.opacity(0)]),
                                        center: .zero, startRadius: 0, endRadius: radius))
    }

    /// PERFECT!'s gold shockwave: one thin additive ring racing out from the pop.
    private func drawRing(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard let p = LaserTeamCalloutMotion.ring(at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize, e = LaserTeamCalloutMotion.easeOut(p)
        var r = ctx
        r.blendMode = .plusLighter
        let rx = (width / 2 + 0.1 * f) * (0.75 + 0.7 * e), ry = min((height / 2) * (0.7 + 0.45 * e), Self.headroom * f)
        r.stroke(Path(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry)),
                 with: .color(Self.gold[0].opacity(0.85 * (1 - p))), lineWidth: 0.12 * f * (1 - p) + 1)
    }

    /// Four-point gold stars bursting out around the word (PERFECT!); four quiet static ones under
    /// Reduce Motion.
    private func drawSparkles(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        let f = fontSize
        let rx = width / 2 + 0.25 * f, ry = height / 2 + 0.1 * f
        if let p = LaserTeamCalloutMotion.burst(.perfect, at: t, reduceMotion: reduceMotion) {
            let ry = ry * 0.78 // the burst's top stays under the HUD bar
            for i in 0..<14 {
                let angle = (Double(i) + 0.4 * LaserTeamCalloutMotion.hash(i, 7)) / 14 * 2 * .pi
                let reach = 0.7 + 0.6 * LaserTeamCalloutMotion.easeOut(p) + 0.25 * LaserTeamCalloutMotion.hash(i, 3)
                let big = i.isMultiple(of: 4)
                let size = ((big ? 0.17 : 0.1) + 0.07 * LaserTeamCalloutMotion.hash(i, 5)) * f * sin(.pi * min(1, p * 1.1))
                star(in: &ctx, at: CGPoint(x: cos(angle) * rx * reach, y: sin(angle) * ry * reach), size: size,
                     rotation: 120 * p * (i.isMultiple(of: 2) ? 1 : -1), color: i.isMultiple(of: 3) ? .white : Self.gold[0])
            }
        } else if reduceMotion {
            for (i, point) in [CGPoint(x: -1, y: -0.8), CGPoint(x: 1, y: -0.7), CGPoint(x: -0.9, y: 0.75), CGPoint(x: 0.95, y: 0.8)].enumerated() {
                star(in: &ctx, at: CGPoint(x: point.x * rx, y: point.y * ry), size: 0.13 * f, rotation: Double(i) * 20, color: Self.gold[0])
            }
        }
    }

    /// Electric sparks spraying from the word as it slams in (ZAPPED!).
    private func drawSparks(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard let p = LaserTeamCalloutMotion.burst(.zapped, at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize
        for i in 0..<12 {
            let angle = (Double(i) + 0.5 * LaserTeamCalloutMotion.hash(i, 9)) / 12 * 2 * .pi
            let r0 = 0.55 + 0.8 * LaserTeamCalloutMotion.easeOut(p), r1 = r0 + 0.28 * (1 - p)
            let a = CGPoint(x: cos(angle) * (width / 2 + 0.1 * f) * r0, y: sin(angle) * (height / 2) * 0.8 * r0)
            let b = CGPoint(x: cos(angle) * (width / 2 + 0.1 * f) * r1, y: sin(angle) * (height / 2) * 0.8 * r1)
            var line = Path(); line.move(to: a); line.addLine(to: b)
            ctx.stroke(line, with: .color((i.isMultiple(of: 2) ? Self.electric : .white).opacity(1 - p)),
                       style: StrokeStyle(lineWidth: 0.06 * f, lineCap: .round))
        }
    }

    /// Two little cartoon smoke puffs rising off the singed word (ZAPPED!).
    private func drawSmoke(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        guard !compact, let p = LaserTeamCalloutMotion.smoke(at: t, reduceMotion: reduceMotion) else { return }
        let f = fontSize
        for (i, side) in [-1.0, 1.0].enumerated() {
            let local = LaserTeamCalloutMotion.phase(p, Double(i) * 0.15, 1)
            guard local > 0 else { continue }
            let r = (0.1 + 0.1 * LaserTeamCalloutMotion.easeOut(local)) * f
            let c = CGPoint(x: side * (width / 2 + 0.05 * f + 0.15 * f * local), y: -0.2 * f - 0.22 * f * local)
            let fade = sin(.pi * local) * 0.7
            for (dx, dy, k) in [(0.0, 0.0, 1.0), (-0.55, 0.25, 0.7), (0.55, 0.25, 0.75)] {
                let rr = r * k
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + dx * r - rr, y: c.y + dy * r - rr, width: 2 * rr, height: 2 * rr)),
                         with: .color(Self.smokeColor.opacity(fade)))
            }
        }
    }

    /// Zig-zag lightning with a fork around the word, only during each flash (a fresh shape per
    /// flash); one static pair under Reduce Motion.
    private func drawBolts(in ctx: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        let f = fontSize
        let flash = reduceMotion ? 0.6 : LaserTeamCalloutMotion.flash(at: t)
        guard flash > 0.05 else { return }
        let seed = reduceMotion ? 0 : (LaserTeamCalloutMotion.flashCenters.firstIndex { abs(t - $0) <= LaserTeamCalloutMotion.flashHalfWidth } ?? 0)
        let lift: CGFloat = compact ? 0.5 : 1
        let anchors: [(CGPoint, CGPoint)] = [
            (CGPoint(x: -width / 2 - 0.6 * f, y: -0.6 * f * lift), CGPoint(x: -width / 2 + 0.1 * f, y: 0.05 * f)),
            (CGPoint(x: width / 2 + 0.6 * f, y: 0.55 * f), CGPoint(x: width / 2 - 0.1 * f, y: -0.1 * f)),
            (CGPoint(x: -0.15 * width, y: -Self.headroom * f * lift), CGPoint(x: -0.05 * width, y: -height / 2 + 0.05 * f)),
            (CGPoint(x: 0.3 * width, y: height / 2 + 0.45 * f), CGPoint(x: 0.22 * width, y: height / 2 - 0.05 * f)),
        ]
        for (i, (a, b)) in anchors.enumerated() where reduceMotion ? i < 2 : true {
            var bolt = Path(); bolt.move(to: a)
            var points: [CGPoint] = []
            for step in 1...4 {
                let s = CGFloat(step) / 5
                let jitter = (LaserTeamCalloutMotion.hash(i * 7 + step, seed) - 0.5) * 0.4 * f
                let p = CGPoint(x: a.x + (b.x - a.x) * s + jitter, y: a.y + (b.y - a.y) * s - jitter)
                points.append(p); bolt.addLine(to: p)
            }
            bolt.addLine(to: b)
            // A short fork off the bolt's middle.
            if !reduceMotion {
                let m = points[1]
                bolt.move(to: m)
                bolt.addLine(to: CGPoint(x: m.x + (b.y - a.y) * 0.25, y: m.y - (b.x - a.x) * 0.25))
            }
            ctx.stroke(bolt, with: .color(Self.electric.opacity(0.55 * flash)), style: StrokeStyle(lineWidth: 0.17 * f, lineCap: .round, lineJoin: .round))
            ctx.stroke(bolt, with: .color(.white.opacity(flash)), style: StrokeStyle(lineWidth: 0.07 * f, lineCap: .round, lineJoin: .round))
        }
    }

    private func star(in ctx: inout GraphicsContext, at point: CGPoint, size: CGFloat, rotation: Double, color: Color) {
        guard size > 0.5 else { return }
        var s = ctx
        s.translateBy(x: point.x, y: point.y)
        s.rotate(by: .degrees(rotation))
        var path = Path()
        for i in 0..<8 {
            let r = i.isMultiple(of: 2) ? size : size * 0.28
            let a = Double(i) / 8 * 2 * .pi - .pi / 2
            let p = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        s.fill(path, with: .color(Self.outline.opacity(0.85)))
        s.scaleBy(x: 0.7, y: 0.7)
        s.fill(path, with: .color(color))
    }
}
