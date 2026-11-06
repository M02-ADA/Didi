import Foundation
import Testing
@testable import Sedactive

/// The Debug live round's jump recognition, ORIGINAL vs TUNED, on the same
/// deterministic SYNTHETIC sole tracks (game units, a 1.6 m player, 30 fps,
/// seeded ankle jitter). This is presentation-side evidence only: the
/// checker's rule (lower sole above the beam while airborne) is not changed.
struct LiveJumpTuningTests {
    static let standing = 1.6
    static let fps = 30.0

    /// One recording: per-frame left/right sole heights (nil: ankle not visible).
    struct Recording {
        let name: String
        var left: [Double?]
        var right: [Double?]
    }

    /// Deterministic jitter in [−amplitude, amplitude] (LCG; standard deviation ≈ amplitude / √3).
    static func jitter(_ count: Int, amplitude: Double, seed: UInt64) -> [Double] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amplitude
        }
    }

    /// A parabolic hop of `peak` metres lasting `duration` s, starting at `start` s.
    static func hop(_ t: Double, start: Double, duration: Double, peak: Double) -> Double {
        let u = (t - start) / duration
        return u > 0 && u < 1 ? 4 * peak * u * (1 - u) : 0
    }

    /// 4 s recordings with ±1.2 cm of independent ankle jitter (sd ≈ 0.7 cm).
    static func recording(_ name: String, _ shape: (Double) -> (Double, Double), seed: UInt64 = 7) -> Recording {
        let n = Int(4 * fps)
        let jl = jitter(n, amplitude: 0.012, seed: seed), jr = jitter(n, amplitude: 0.012, seed: seed &+ 99)
        var r = Recording(name: name, left: [], right: [])
        for i in 0..<n {
            let (l, rr) = shape(Double(i) / fps)
            r.left.append(l + jl[i])
            r.right.append(rr + jr[i])
        }
        return r
    }

    static let standingStill = recording("standing noise") { _ in (0, 0) }
    /// Heels up onto the toes over 0.8 s (ankles +6 cm), held, then down.
    static let tiptoe = recording("slow tiptoe 6 cm") { t in
        let up = min(1, max(0, (t - 1) / 0.8)) - min(1, max(0, (t - 2.8) / 0.4))
        return (0.06 * up, 0.06 * up)
    }
    static let singleKnee = recording("one knee raised 25 cm") { t in (t > 1 && t < 2.5 ? 0.25 : 0, 0) }
    static let smallHop = recording("small hop 6 cm") { t in let h = hop(t, start: 2, duration: 0.3, peak: 0.06); return (h, h) }
    static let mediumHop = recording("hop 10 cm") { t in let h = hop(t, start: 2, duration: 0.35, peak: 0.10); return (h, h) }
    static let normalJump = recording("jump 20 cm") { t in let h = hop(t, start: 2, duration: 0.45, peak: 0.20); return (h, h) }
    /// The 10 cm hop with both ankles lost for one frame at the top.
    static let hopWithDropout: Recording = {
        var r = mediumHop
        let top = Int(2.17 * fps)
        r.left[top] = nil; r.right[top] = nil
        return Recording(name: "hop 10 cm, 1 frame dropout", left: r.left, right: r.right)
    }()
    /// Ankles lost for 10 frames while standing, back 2 cm higher (posture/depth shift).
    static let recoveryShift: Recording = {
        var r = recording("ankles lost, back 2 cm higher") { t in t > 2.33 ? (0.02, 0.02) : (0, 0) }
        for i in 60..<70 { r.left[i] = nil; r.right[i] = nil }
        return r
    }()

    static let all = [standingStill, tiptoe, singleKnee, smallHop, mediumHop, normalJump, hopWithDropout, recoveryShift]

    struct Result {
        var phases: [JumpPhase?] = []
        /// Airborne stretches (a dropout frame inside one does not split it).
        var jumps = 0
        var airborneFrames = 0
        var unknownFrames = 0
        /// Frames from the feet first being 2 cm up to the first airborne frame.
        var takeoffLatency: Int?
        var threshold = 0.0
    }

    static func run(_ tuning: LiveJumpTuning, _ r: Recording) -> Result {
        var d = LiveJumpDetector(tuning: tuning)
        var out = Result()
        var wasAirborne = false
        var feetUp: Int?
        for i in r.left.indices {
            let phase = d.update(left: r.left[i], right: r.right[i], at: Double(i) / fps, standing: standing)
            out.phases.append(phase)
            if let l = r.left[i], let rr = r.right[i], min(l, rr) > 0.02, feetUp == nil, i > 30 { feetUp = i }
            switch phase {
            case .airborne?:
                out.airborneFrames += 1
                if !wasAirborne { out.jumps += 1 }
                if out.takeoffLatency == nil, let up = feetUp { out.takeoffLatency = i - up }
                wasAirborne = true
            case nil:
                out.unknownFrames += 1  // keeps `wasAirborne`: unknown, not landed
            default:
                wasAirborne = false
            }
        }
        out.threshold = d.enterThreshold(standing: standing)
        return out
    }

    // MARK: - Must never count

    @Test func standingNoiseTiptoeAndOneKneeNeverJump() {
        for tuning in [LiveJumpTuning.original, .tuned] {
            for r in [Self.standingStill, Self.tiptoe, Self.singleKnee] {
                let result = Self.run(tuning, r)
                #expect(result.jumps == 0, "\(tuning.name): \(r.name) read as \(result.jumps) jump(s)")
            }
        }
    }

    @Test func confidenceLossNeverFabricatesAJump() {
        for tuning in [LiveJumpTuning.original, .tuned] {
            let result = Self.run(tuning, Self.recoveryShift)
            #expect(result.jumps == 0, "\(tuning.name)")
            // Frames without both ankles are reported as unknown, never as airborne or grounded.
            #expect(result.phases[60..<70].allSatisfy { $0 == nil })
        }
        // Recovery mid-air (ankles back already 12 cm up): no jump is invented from
        // the jump in the measurement; the tuned rule needs a seen takeoff.
        var r = Self.standingStill
        for i in 60..<70 { r.left[i] = nil; r.right[i] = nil }
        for i in 70..<76 { r.left[i] = 0.12; r.right[i] = 0.12 }
        #expect(Self.run(.tuned, r).jumps == 0)
    }

    // MARK: - Must count

    @Test func aSmallIntentionalHopIsRecognizedOnlyByTheTunedRule() {
        let tuned = Self.run(.tuned, Self.smallHop), original = Self.run(.original, Self.smallHop)
        #expect(tuned.jumps == 1 && original.jumps == 0)
        // 3% of a 1.6 m player (4.8 cm), still above the checker's ~3.2 cm JUMP beam.
        #expect(abs(tuned.threshold - 0.048) < 1e-9)
    }

    @Test func takeoffAndLandingAreOneCleanJump() {
        for r in [Self.mediumHop, Self.normalJump] {
            let tuned = Self.run(.tuned, r), original = Self.run(.original, r)
            #expect(tuned.jumps == 1 && original.jumps == 1, "\(r.name)")
            // Recognized no later than before, and for longer (lower landing threshold).
            #expect((tuned.takeoffLatency ?? 99) <= (original.takeoffLatency ?? 99))
            #expect(tuned.airborneFrames >= original.airborneFrames)
            // Grounded again within a frame of the feet landing, then stays grounded.
            let landed = Int((2 + (r.name == Self.mediumHop.name ? 0.35 : 0.45)) * Self.fps) + 2
            #expect(tuned.phases[landed...].allSatisfy { $0 == .grounded }, "\(r.name)")
        }
    }

    @Test func oneDroppedFrameDoesNotSplitOrEndTheJump() {
        let tuned = Self.run(.tuned, Self.hopWithDropout)
        #expect(tuned.jumps == 1 && tuned.unknownFrames == 1)
        let top = Int(2.17 * Self.fps)
        #expect(tuned.phases[top] == nil)  // the missing frame is never reported airborne
        #expect(tuned.phases[top + 1] == .airborne)  // the jump continues after it
        let original = Self.run(.original, Self.hopWithDropout)
        #expect(original.phases[top] == nil)
    }

    // MARK: - Before/after summary (printed; recorded in the robot README)

    @Test func printComparison() {
        print("JUMPCMP case | original: jumps, airborne frames, takeoff latency | tuned: jumps, airborne frames, takeoff latency")
        for r in Self.all {
            let o = Self.run(.original, r), t = Self.run(.tuned, r)
            func cell(_ x: Result) -> String { "\(x.jumps), \(x.airborneFrames), \(x.takeoffLatency.map(String.init) ?? "—")" }
            print("JUMPCMP \(r.name) | \(cell(o)) | \(cell(t))")
        }
        // Per-frame track of the small hop and the 10 cm hop, for the plot.
        for r in [Self.smallHop, Self.mediumHop] {
            let o = Self.run(.original, r), t = Self.run(.tuned, r)
            for i in 54..<78 {
                let sole = min(r.left[i] ?? .nan, r.right[i] ?? .nan)
                print(String(format: "JUMPTRACK %@,%d,%.4f,%d,%d", r.name, i, sole,
                             o.phases[i] == .airborne ? 1 : 0, t.phases[i] == .airborne ? 1 : 0))
            }
        }
    }
}
