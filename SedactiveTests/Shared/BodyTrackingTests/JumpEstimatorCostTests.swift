import Foundation
import Testing
@testable import Sedactive

/// Performance regression (Kevin, 22 November 2026; Edo-owned estimator, for his review): a player
/// standing steady keeps the estimator's still-soles run growing for as long as they stay within the
/// still band, so its per-frame cost must not grow with that run (it runs per player, per camera
/// frame, under the tracking lock the main thread also takes).
struct JumpEstimatorCostTests {
    /// Steady soles with tiny tracking noise (well inside the 1 % band), hips upright: 30 fps.
    private static func steady(_ frames: Int, startFrame: UInt64 = 0, start: Double = 0,
                               estimator: inout LiveJumpEstimator) -> Double {
        let begin = DispatchTime.now().uptimeNanoseconds
        for i in 0..<frames {
            let n = startFrame + UInt64(i) + 1, t = start + Double(i) / 30
            let jitter = 0.002 * sin(Double(n) * 1.7)
            _ = estimator.step(frameID: n, capturedAt: t, leftSole: jitter, rightSole: 0.004 + jitter,
                               standingLeftSole: 0, standingRightSole: 0.004, standingHeight: 1.6, calibrationRevision: 1,
                               hipY: 0.85, standingHip: 0.85, candidateRules: true)
        }
        return Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e3 / Double(frames)
    }

    @Test func aSteadyPlayersStepCostStaysFlatOverAFiveMinuteRound() {
        var estimator = LiveJumpEstimator()
        var costs: [Double] = []
        var frame: UInt64 = 0
        // Five minutes at 30 fps, measured per 30-second block (µs per step).
        for block in 0..<10 {
            costs.append(Self.steady(900, startFrame: frame, start: Double(block) * 30, estimator: &estimator))
            frame += 900
        }
        print("JUMP ESTIMATOR µs/step per 30 s block: " + costs.map { String(format: "%.1f", $0) }.joined(separator: " "))
        let early = costs[1], late = costs[9]
        #expect(late < max(3 * early, early + 10), "the cost must not grow through the round: \(early) → \(late) µs")
    }
}

/// Cost of building one game scene (what a re-created round view's `@State` initial values build).
@MainActor
struct LaserSceneConstructionCostTests {
    @Test func measureBuildingAFreshSceneAndItsPresentation() {
        _ = LaserScene() // warm caches
        var times: [Double] = []
        for _ in 0..<20 {
            let begin = DispatchTime.now().uptimeNanoseconds
            let scene = LaserScene()
            let presentation = LaserReplayPresentation()
            withExtendedLifetime((scene, presentation)) {}
            times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6)
        }
        let sorted = times.sorted()
        print(String(format: "LASERSCENE+PRESENTATION build ms: median %.2f max %.2f", sorted[sorted.count / 2], sorted.last!))
    }
}

/// `JumpStillRun` keeps exactly the run the earlier array kept (the original algorithm, below).
struct JumpStillRunTests {
    /// The original: append, then drop the oldest while more than one remain and the range exceeds the band.
    private struct Reference {
        var still: [(time: Double, raw: Double)] = []
        mutating func append(_ time: Double, _ raw: Double, band: Double) {
            still.append((time, raw))
            while still.count > 1, still.map(\.raw).max()! - still.map(\.raw).min()! > band { still.removeFirst() }
        }
    }

    /// A deterministic pseudo-random stream (no global RNG state).
    private struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    @Test(arguments: [1, 7, 42, 99])
    func itKeepsTheSameRunAsTheOriginalAlgorithm(seed: Int) {
        var rng = LCG(s: UInt64(seed))
        var run = JumpStillRun(), reference = Reference()
        var t = 0.0, level = 0.0, maxCount = 0
        for i in 0..<30_000 {
            t += 1.0 / 30
            // Long steady stretches (tiny jitter), steps, drifts, jumps and the occasional reset.
            let phase = (i / 1500) % 4
            switch phase {
            case 0: break
            case 1: level += (rng.next() - 0.5) * 0.002
            case 2: if rng.next() < 0.02 { level += (rng.next() - 0.5) * 0.2 }
            default: level = 0.1 * sin(Double(i) / 9)
            }
            let raw = level + (rng.next() - 0.5) * 0.004
            let band = 0.016 + (rng.next() < 0.1 ? rng.next() * 0.02 : 0)
            if phase != 0, rng.next() < 0.002 { run.removeAll(); reference.still = []; continue }
            run.append(time: t, raw: raw, band: band)
            reference.append(t, raw, band: band)
            maxCount = max(maxCount, reference.still.count)
            #expect(run.count == reference.still.count)
            #expect(run.firstTime == reference.still.first!.time && run.lastTime == reference.still.last!.time)
            #expect(run.maximum == reference.still.map(\.raw).max()! && run.minimum == reference.still.map(\.raw).min()!)
            let exact = reference.still.map(\.raw).reduce(0, +) / Double(reference.still.count)
            #expect(abs(run.mean - exact) < 1e-12, "mean differs only by rounding")
            if run.count != reference.still.count { Issue.record("diverged at \(i)"); return }
        }
        #expect(maxCount > 1100, "the stream includes runs long enough to compact (\(maxCount))")
    }
}
