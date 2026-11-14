import Foundation
import Testing
@testable import Sedactive

/// Lean tuning (owner, 12 November 2026: steering worked on the iPad but felt slow). Measures the
/// first iPad build's tuning against the responsive one through the same chain the live round runs:
/// `RobotRetargeter` (filter, deadband, speed per lean) at 30 Hz poses → `LateralSteering`
/// (acceleration, braking, cap) at 60 Hz. SYNTHETIC rigid trunk leans with a realistic 0.2 s onset;
/// how a real lean feels still needs the iPad.
@MainActor
struct LeanResponsivenessTests {
    struct Setup {
        var name: String
        var deadband: Float, perShare: Float, filter: Double
        var tuning: LateralSteering.Tuning
        static let initial = Setup(name: "initial", deadband: 0.03, perShare: 12, filter: 0.06, tuning: .initial)
        static let responsive = Setup(name: "responsive", deadband: 0.02, perShare: 20, filter: 0.03, tuning: .responsive)
    }

    struct Run {
        var r: RobotRetargeter
        var s: LateralSteering
        let reference: AvatarReference
        var time = 0.0
        var velocities: [Float] = []

        init(_ setup: Setup) throws {
            let input = try LaserReplayScript.load().input
            let c = try #require(input.configuration.calibrations[.player1])
            reference = AvatarReference(calibration: c, layout: input.configuration.playerPlaneLayout)
            r = RobotRetargeter(reference: reference, robotLegRest: 0.5)
            r.leanSteerGain = RobotRetargeter.boardLeanSteerGain
            r.steerDeadbandShare = setup.deadband
            r.steerSpeedPerShare = setup.perShare
            r.steerFilterTime = setup.filter
            let half = PlayerHoverboard.halfWidth
            s = LateralSteering(lanes: [.player1: -0.7], bounds: -1.95...1.95, halfWidth: half)
            s.tuning = setup.tuning
        }

        var x: Float { s.boardX(.player1)! }

        /// One 30 Hz pose: a rigid trunk lean of `degrees` to the player's own RIGHT (screen right),
        /// plus optional jitter (game units) on the shoulders and head; then two 60 Hz steps.
        mutating func pose(_ degrees: Double, jitter: (Double, Double) = (0, 0)) {
            let h = reference.standingHeight, lane = reference.laneCenterX, hipY = reference.standingHipY
            let sin = Foundation.sin(degrees * .pi / 180)
            let shoulder = -(0.82 * h - hipY) * sin + jitter.0, head = -(0.9 * h - hipY) * sin + jitter.1
            func p(_ x: Double, _ y: Double) -> PresentationPoint { PresentationPoint(x: lane + x, y: y, confidence: 0.9) }
            var o = RobotRetargeter.Observation()
            o.calibrated = true
            o.centerX = lane
            o.joints = [.leftShoulder: p(shoulder + 0.13 * h, 0.82 * h), .rightShoulder: p(shoulder - 0.13 * h, 0.82 * h),
                        .leftHip: p(0.07 * h, hipY), .rightHip: p(-0.07 * h, hipY), .nose: p(head, 0.9 * h)]
            time += 1.0 / 30
            r.update(o, time: time)
            for _ in 0..<2 {
                s.step(dt: 1 / 60, inputs: [.player1: .init(targetSpeed: r.steerSpeed)])
                velocities.append(s.riders[.player1]!.velocity)
            }
        }

        /// Lean ramp: from `from` to `to` degrees over `seconds` (a person's onset or return).
        mutating func ramp(_ from: Double, _ to: Double, seconds: Double) {
            let n = max(1, Int(seconds * 30))
            for i in 1...n { pose(from + (to - from) * Double(i) / Double(n)) }
        }
    }

    struct Measures {
        var onset: Double?          // lean start → 5 cm travel (s)
        var buttonReach: Double?    // lean start → 0.45 m travel (s)
        var heldSpeed: Float        // steady speed at the held lean (m/s)
        var stopFromReturn: Float   // travel from the start of straightening up to rest (m)
        var stopFromNeutral: Float  // travel after the posture is neutral (m)
        var timeToRest: Double      // start of straightening up → velocity 0 (s)
    }

    /// A comfortable lean of `degrees`: neutral, 0.2 s onset, held until 0.45 m (max 3 s), 0.2 s back.
    static func measure(_ setup: Setup, degrees: Double) throws -> Measures {
        var run = try Run(setup)
        for _ in 0..<15 { run.pose(0) }
        let x0 = run.x, t0 = run.time
        var onset: Double?, reach: Double?
        let n = 6 // 0.2 s onset
        for i in 1...n {
            run.pose(degrees * Double(i) / Double(n))
            if onset == nil, abs(run.x - x0) >= 0.05 { onset = run.time - t0 }
        }
        while run.time - t0 < 3 {
            run.pose(degrees)
            if onset == nil, abs(run.x - x0) >= 0.05 { onset = run.time - t0 }
            if reach == nil, abs(run.x - x0) >= 0.45 { reach = run.time - t0; break }
        }
        for _ in 0..<15 { run.pose(degrees) } // held a little at speed
        let held = abs(run.s.riders[.player1]!.velocity)
        let xReturn = run.x, tReturn = run.time
        run.ramp(degrees, 0, seconds: 0.2)
        let xNeutral = run.x
        var rest: Double?
        for _ in 0..<60 {
            run.pose(0)
            if rest == nil, run.s.riders[.player1]!.velocity == 0 { rest = run.time - tReturn }
        }
        return Measures(onset: onset, buttonReach: reach, heldSpeed: held, stopFromReturn: abs(run.x - xReturn),
                        stopFromNeutral: abs(run.x - xNeutral), timeToRest: rest ?? -1)
    }

    /// Standing "still" with Vision-like jitter on the shoulders and head (±`amount` h each; 0.008 h
    /// is about ±1.4 cm at 1.7 m) for 10 s: how far the board drifts.
    static func drift(_ setup: Setup, amount: Double = 0.008) throws -> Float {
        var run = try Run(setup)
        var seed: UInt64 = 0x5EDAC71E
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 2
        }
        let h = run.reference.standingHeight
        let x0 = run.x
        for _ in 0..<300 { run.pose(0, jitter: (amount * h * noise(), amount * h * noise())) }
        return abs(run.x - x0)
    }

    static func maximumSpeed(_ setup: Setup) throws -> Float {
        var run = try Run(setup)
        run.ramp(0, 35, seconds: 0.2)
        for _ in 0..<60 { run.pose(35) }
        return run.velocities.map(abs).max() ?? 0
    }

    @Test func theResponsiveTuningStartsSoonerReachesButtonsFasterAndStillStopsAndHolds() throws {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "—" }
        var table: [String] = []
        var results: [String: [Double: Measures]] = [:]
        for setup in [Setup.initial, .responsive] {
            for degrees in [8.0, 12.0, 15.0] {
                let m = try Self.measure(setup, degrees: degrees)
                results[setup.name, default: [:]][degrees] = m
                table.append(String(format: "TUNE %-10@ %4.0f° onset→5cm %@ · →0.45 m %@ · held %.2f m/s · stop from straightening %.3f m (%.2f s) · after neutral %.3f m",
                                    setup.name as NSString, degrees, f(m.onset), f(m.buttonReach), m.heldSpeed,
                                    m.stopFromReturn, m.timeToRest, m.stopFromNeutral))
            }
            table.append(String(format: "TUNE %-10@ max speed (35° lean) %.2f m/s · neutral drift over 10 s: %.4f m (±0.008 h jitter), %.4f m (±0.015 h), %.4f m (±0.025 h)",
                                setup.name as NSString, try Self.maximumSpeed(setup), try Self.drift(setup),
                                try Self.drift(setup, amount: 0.015), try Self.drift(setup, amount: 0.025)))
        }
        for line in table { print(line) }
        let old = try #require(results["initial"]), new = try #require(results["responsive"])
        for degrees in [8.0, 12.0, 15.0] {
            let o = try #require(old[degrees]), n = try #require(new[degrees])
            let newOnset = try #require(n.onset), newReach = try #require(n.buttonReach)
            #expect(newOnset < (o.onset ?? 9), "\(degrees)°: starts sooner")
            #expect(newReach < (o.buttonReach ?? 9), "\(degrees)°: reaches the button region sooner")
            #expect(n.heldSpeed > o.heldSpeed)
            #expect(n.stopFromNeutral < 0.03, "\(degrees)°: once upright it stops within 3 cm (\(n.stopFromNeutral))")
        }
        // A comfortable ~12° lean: moving within about a quarter second, at the buttons within a second,
        // and stopping within about 15 cm of where the player began to straighten up.
        let comfortable = try #require(new[12])
        #expect(try #require(comfortable.onset) <= 0.3)
        #expect(try #require(comfortable.buttonReach) <= 1.0)
        #expect(comfortable.stopFromReturn <= 0.15)
        #expect(try Self.maximumSpeed(.responsive) <= LateralSteering.Tuning.responsive.maximumSpeed + 1e-4)
        #expect(try Self.maximumSpeed(.responsive) > 1.9, "a strong lean reaches the cap")
        #expect(try Self.drift(.responsive) < 0.01, "standing still does not drift")
    }

    /// The shipped values are the responsive set.
    @Test func theShippedTuningIsTheResponsiveSet() {
        let r = RobotRetargeter(reference: nil, robotLegRest: 0.5)
        #expect(r.steerDeadbandShare == Setup.responsive.deadband && r.steerSpeedPerShare == Setup.responsive.perShare
                && r.steerFilterTime == Setup.responsive.filter)
        #expect(LateralSteering.tuning == .responsive)
    }
}
