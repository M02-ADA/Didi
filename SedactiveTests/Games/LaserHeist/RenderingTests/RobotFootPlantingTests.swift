import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// Foot planting and lateral stepping for the 3D robot. Inputs are SYNTHETIC
/// (the deterministic `RobotDemoSequence` scenarios, or constructed planner
/// inputs), played like the device: 30 Hz body frames, a 60 Hz render loop
/// with the lab's render smoothing. Measures what the solved skeleton does in
/// hoverboard space. This proves the mechanics, not how real feet look.
@MainActor
struct RobotFootPlantingTests {
    typealias Side = RobotPoseTargets.Side

    struct Tick {
        let time: Double
        let feet: [PlayerID: RobotAvatarLayer.FootDiagnostics]
    }

    struct Metrics: CustomStringConvertible {
        var steps = 0
        /// Largest sideways slide of a foot while it is planted (skating).
        var plantedDrift: Float = 0
        /// Total sideways travel while planted, and while the robot's root moved sideways.
        var plantedTravel: Float = 0
        var maxHeight: Float = 0
        var minHeight: Float = 0
        /// Largest change between two rendered frames (teleport check).
        var maxFrameJumpX: Float = 0
        var maxFrameJumpY: Float = 0
        var maxReachShortfall: Float = 0
        var description: String {
            String(format: "steps %d · planted drift %.1f mm · planted travel %.1f mm · lift %.1f cm · min h %.1f mm · max jump/frame %.1f mm x %.1f mm y · reach %.1f mm",
                   steps, plantedDrift * 1000, plantedTravel * 1000, maxHeight * 100, minHeight * 1000,
                   maxFrameJumpX * 1000, maxFrameJumpY * 1000, maxReachShortfall * 1000)
        }
    }

    private func templates() async throws -> [PlayerID: Entity] { try #require(await RobotAvatarLayer.loadTemplates()) }

    /// Plays one scenario (4 s) and returns every rendered frame's diagnostics.
    private func play(_ scenario: RobotDemoScenario, planting: Bool, seconds: Double = RobotDemoScenario.duration) async throws -> [Tick] {
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: LaserScene(), calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        layer.footPlanting = planting
        layer.diagnosticsEnabled = true
        layer.smoothing = 0.03
        let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision,
                                         only: scenario)
        var ticks: [Tick] = []
        var lastFrame: UInt64 = 0
        for n in 1...Int(seconds * 60) - 1 {
            let time = Double(n) / 60
            let index = UInt64(time * RobotDemoSequence.frameRate)
            if index > lastFrame {
                let f = try sequence.frame(index)
                layer.apply(f.snapshot, joints: f.joints)
                lastFrame = index
            }
            layer.render(now: time)
            ticks.append(Tick(time: time, feet: layer.footDiagnostics))
        }
        return ticks
    }

    private func metrics(_ ticks: [Tick], _ player: PlayerID, _ side: Side, from: Double = 0, to: Double = .infinity) -> Metrics {
        var m = Metrics()
        var previous: RobotAvatarLayer.FootDiagnostics?
        for tick in ticks where tick.time >= from && tick.time <= to {
            guard let d = tick.feet[player] else { continue }
            m.steps = d.steps[side] ?? 0
            m.plantedDrift = max(m.plantedDrift, d.plantedDrift[side] ?? 0)
            m.maxHeight = max(m.maxHeight, d.height[side] ?? 0)
            m.minHeight = min(m.minHeight, d.height[side] ?? 0)
            m.maxReachShortfall = max(m.maxReachShortfall, d.reachShortfall[side] ?? 0)
            if let p = previous, let x = d.actualX[side], let px = p.actualX[side] {
                m.maxFrameJumpX = max(m.maxFrameJumpX, abs(x - px))
                m.maxFrameJumpY = max(m.maxFrameJumpY, abs((d.height[side] ?? 0) - (p.height[side] ?? 0)))
                if d.contact[side] == .planted, p.contact[side] == .planted { m.plantedTravel += abs(x - px) }
            }
            previous = d
        }
        if let first = ticks.first(where: { $0.time >= from })?.feet[player] { m.steps -= first.steps[side] ?? 0 }
        return m
    }

    private func report(_ scenario: RobotDemoScenario, _ ticks: [Tick], planting: Bool, players: [PlayerID] = [.player1]) {
        for player in players {
            for side in Side.allCases {
                print("FOOT-METRICS \(scenario.key) \(planting ? "planted" : "legacy") \(player == .player1 ? "P1" : "P2") \(side) \(metrics(ticks, player, side))")
            }
        }
    }

    /// Steps of one foot, in order (start time per step).
    private func stepStarts(_ ticks: [Tick], _ player: PlayerID, _ side: Side) -> [Double] {
        var starts: [Double] = []
        var last = 0
        for tick in ticks {
            let n = tick.feet[player]?.steps[side] ?? 0
            if n > last { starts.append(tick.time); last = n }
        }
        return starts
    }

    // MARK: - Standing, leaning, ducking: feet stay planted

    @Test func standingStillNeverSteps() async throws {
        let ticks = try await play(.idle, planting: true)
        report(.idle, ticks, planting: true, players: [.player1, .player2])
        for player in PlayerID.allCases {
            for side in Side.allCases {
                let m = metrics(ticks, player, side)
                #expect(m.steps == 0 && m.plantedDrift < 0.001 && m.maxHeight < 0.001, "\(player) \(side): \(m)")
            }
        }
    }

    /// A lean shifts the pelvis and tilts the trunk; ankles stay, so no step and no skating.
    /// The earlier behaviour carried both feet along with the hips.
    @Test(arguments: [RobotDemoScenario.leanRight, .leanLeft])
    func leaningKeepsBothFeetPlanted(_ scenario: RobotDemoScenario) async throws {
        let ticks = try await play(scenario, planting: true)
        let legacy = try await play(scenario, planting: false)
        report(scenario, ticks, planting: true)
        report(scenario, legacy, planting: false)
        let sign: Float = scenario == .leanRight ? 1 : -1
        let pelvis = ticks.compactMap { $0.feet[.player1]?.pelvisX }.map { $0 * sign }.max() ?? 0
        #expect(pelvis > 0.05, "the weight shift shows in the pelvis")
        for side in Side.allCases {
            let m = metrics(ticks, .player1, side)
            #expect(m.steps == 0 && m.plantedDrift < 0.003 && m.maxReachShortfall < 0.002, "\(side): \(m)")
            #expect(metrics(legacy, .player1, side).plantedDrift > 0.05, "legacy feet slid with the hips")
        }
    }

    @Test func duckingKeepsFeetPlantedThroughBalanceSway() async throws {
        let ticks = try await play(.duckPlanted, planting: true)
        report(.duckPlanted, ticks, planting: true)
        for side in Side.allCases {
            let m = metrics(ticks, .player1, side)
            #expect(m.steps == 0 && m.plantedDrift < 0.003 && m.minHeight > -0.002, "\(side): \(m)")
        }
    }

    // MARK: - Side steps

    @Test(arguments: [RobotDemoScenario.stepRight, .stepLeft])
    func aSideStepLiftsTheLeadingFootFirstAndKeepsTheSupportFootPlanted(_ scenario: RobotDemoScenario) async throws {
        let ticks = try await play(scenario, planting: true)
        report(scenario, ticks, planting: true)
        report(scenario, try await play(scenario, planting: false), planting: false)
        let lead: Side = scenario == .stepRight ? .right : .left, trail: Side = lead == .right ? .left : .right
        let leadStarts = stepStarts(ticks, .player1, lead), trailStarts = stepStarts(ticks, .player1, trail)
        // Out and back: each foot steps twice; going out the leading foot moves first.
        #expect(leadStarts.count == 2 && trailStarts.count == 2, "lead \(leadStarts) trail \(trailStarts)")
        if let l = leadStarts.first, let t = trailStarts.first { #expect(l < t) }
        for side in Side.allCases {
            let m = metrics(ticks, .player1, side)
            #expect(m.maxHeight > 0.02 && m.maxHeight < 0.08, "\(side) lifts: \(m)")
            #expect(m.plantedDrift < 0.003 && m.minHeight > -0.002, "\(side) no skating or penetration: \(m)")
            #expect(m.maxFrameJumpX < 0.03 && m.maxFrameJumpY < 0.02, "\(side) no snapping: \(m)")
            #expect(m.maxReachShortfall < 0.002, "\(side) reached: \(m)")
        }
        // While one foot steps, the other is planted.
        for tick in ticks {
            guard let d = tick.feet[.player1] else { continue }
            #expect(!(d.contact[.left] == .stepping && d.contact[.right] == .stepping), "both feet stepping at \(tick.time)")
        }
        // Responsiveness: the robot's leading foot passes half of its 16 cm move how long after the
        // player's leading ankle does (synthetic: the ankle's half-way point is 0.6 + 0.15 s)?
        let sign: Float = scenario == .stepRight ? 1 : -1
        let origin = try #require(ticks.first?.feet[.player1]?.actualX[lead])
        let half = try #require(ticks.first { sign * (($0.feet[.player1]?.actualX[lead] ?? origin) - origin) >= 0.08 }?.time)
        let delay = half - 0.75
        print(String(format: "FOOT-LATENCY %@ leading foot half-way %.0f ms after the ankle (30 ms render smoothing, 33 ms step confirmation, 0.12-0.25 s front-loaded step)",
                     scenario.key, delay * 1000))
        #expect(delay < 0.2)
        // Mid-hold (after stepping out): the feet stand where the player's feet are, about 16 cm across.
        let held = try #require(ticks.first { $0.time >= 2.2 }?.feet[.player1])
        let start = try #require(ticks.first?.feet[.player1])
        for side in Side.allCases {
            #expect(abs(sign * ((held.actualX[side] ?? 0) - (start.actualX[side] ?? 0)) - 0.16) < 0.03, "\(side) landed")
        }
    }

    @Test func twoConsecutiveStepsAndAQuickStop() async throws {
        let two = try await play(.twoSteps, planting: true)
        report(.twoSteps, two, planting: true)
        for side in Side.allCases {
            let m = metrics(two, .player1, side)
            #expect(m.steps >= 4 && m.steps <= 5 && m.plantedDrift < 0.003, "\(side): \(m)")
        }
        let stop = try await play(.stepThenStop, planting: true)
        report(.stepThenStop, stop, planting: true)
        for side in Side.allCases {
            // After the step settles, standing still: no further steps, no drift.
            let settled = metrics(stop, .player1, side, from: 1.5, to: 3.1)
            #expect(settled.steps == 0 && settled.plantedDrift < 0.002, "\(side) settled: \(settled)")
            #expect(metrics(stop, .player1, side).maxFrameJumpX < 0.035)
        }
    }

    // MARK: - Jump and transitions

    @Test(arguments: [RobotDemoScenario.p1JumpLand, .stepThenJump])
    func jumpingReleasesBothFeetAndReplantsOnLanding(_ scenario: RobotDemoScenario) async throws {
        let ticks = try await play(scenario, planting: true)
        report(scenario, ticks, planting: true)
        let airborne = ticks.filter { $0.feet[.player1]?.contact[.left] == .airborne }
        #expect(!airborne.isEmpty)
        for tick in ticks {
            guard let d = tick.feet[.player1] else { continue }
            // Both feet release together, and no step starts in the air.
            #expect((d.contact[.left] == .airborne) == (d.contact[.right] == .airborne), "at \(tick.time)")
        }
        let afterLanding = try #require(ticks.last?.feet[.player1])
        #expect(afterLanding.contact.values.allSatisfy { $0 == .planted })
        for side in Side.allCases {
            let m = metrics(ticks, .player1, side)
            #expect(m.minHeight > -0.002 && m.maxFrameJumpX < 0.03 && m.plantedDrift < 0.003, "\(side): \(m)")
        }
    }

    @Test func trackingLossMidStepNeverTeleportsAFoot() async throws {
        let ticks = try await play(.lossDuringStep, planting: true)
        report(.lossDuringStep, ticks, planting: true)
        for side in Side.allCases {
            let m = metrics(ticks, .player1, side)
            #expect(m.maxFrameJumpX < 0.03 && m.maxFrameJumpY < 0.02 && m.minHeight > -0.002, "\(side): \(m)")
            #expect(m.plantedDrift < 0.003 && m.maxReachShortfall < 0.002, "\(side): \(m)")
            // While lost (after the in-flight step lands): no new steps are invented.
            #expect(metrics(ticks, .player1, side, from: 1.35, to: 1.8).steps == 0)
        }
    }

    @Test func oneRobotStepsWhileTheOtherStandsWithBodySway() async throws {
        let ticks = try await play(.p1StepP2Idle, planting: true)
        report(.p1StepP2Idle, ticks, planting: true, players: [.player1, .player2])
        for side in Side.allCases {
            #expect(metrics(ticks, .player1, side).steps == 2)
            let p2 = metrics(ticks, .player2, side)
            #expect(p2.steps == 0 && p2.plantedDrift < 0.002, "P2 \(side): \(p2)")
        }
    }

    // MARK: - Planner rules (constructed input)

    private func planner() -> RobotFootPlanner { RobotFootPlanner(rest: [.left: -0.12, .right: 0.12]) }

    /// Standing noise (pelvis ±1.5 cm, ankles ±2 cm, 60 Hz, 10 s) never releases a foot.
    @Test func standingNoiseNeverStartsAStep() {
        var p = planner()
        var seed: UInt64 = 42
        func noise(_ amplitude: Float) -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * amplitude
        }
        for n in 0..<600 {
            var input = RobotFootPlanner.Input(pelvisX: noise(0.015), rootLift: abs(noise(0.008)), time: Double(n) / 60)
            input.footDelta = [.left: noise(0.02), .right: noise(0.02)]
            let out = p.update(input)
            #expect(out.footHeight.values.allSatisfy { $0 == 0 } && p.feet.values.allSatisfy { $0.contact == .planted }, "frame \(n)")
            #expect(abs((out.footX[.left] ?? 0) + 0.12) < 0.016, "left foot moved at \(n)")
        }
    }

    /// No ankle evidence: a large weight shift moves the leading foot, then the trailing one.
    @Test func withoutAnklesABodyShiftStepsTheLeadingFootThenTheTrailingFoot() {
        var p = planner()
        var order: [Side] = []
        for n in 0..<120 {
            let x = Float(min(1, Double(n) / 18)) * 0.18
            _ = p.update(RobotFootPlanner.Input(pelvisX: x, rootLift: 0, time: Double(n) / 60))
            for side in Side.allCases where p.feet[side]?.contact == .stepping && order.last != side { order.append(side) }
        }
        #expect(order.first == .right && order.contains(.left), "\(order)")
        #expect(p.feet.allSatisfy { abs($0.value.x - (0.18 + (p.rest[$0.key] ?? 0))) < 0.03 })
        #expect(p.feet[.right]?.reason == .balance)
    }

    /// Tracked ankles that stay put keep the feet planted even when the hips move far (a deep lean),
    /// up to the reach guard.
    @Test func trackedStillAnklesHoldTheFeetUntilTheReachLimit() {
        var p = planner()
        for n in 0..<90 {
            let x = Float(min(1, Double(n) / 30)) * 0.12
            var input = RobotFootPlanner.Input(pelvisX: x, rootLift: 0, time: Double(n) / 60)
            input.footDelta = [.left: -x, .right: -x]  // ankles still: relative to the hips they move back
            _ = p.update(input)
        }
        #expect(p.feet.values.allSatisfy { $0.contact == .planted })
        #expect(abs((p.feet[.left]?.x ?? 0) + 0.12) < 1e-4 && abs((p.feet[.right]?.x ?? 0) - 0.12) < 1e-4)
        // Beyond the reach guard, the far foot steps (no stretching).
        var q = planner()
        for n in 0..<90 {
            let x = Float(min(1, Double(n) / 30)) * 0.3
            var input = RobotFootPlanner.Input(pelvisX: x, rootLift: 0, time: Double(n) / 60)
            input.footDelta = [.left: -x, .right: -x]
            _ = q.update(input)
        }
        #expect(q.feet[.left]?.reason == .reach || q.feet[.right]?.reason == .reach)
    }

    // MARK: - Cost

    @Test func plannerAndSolveForTwoRobotsFitAFrame() async throws {
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: LaserScene(), calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        layer.smoothing = 0.03
        let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision,
                                         only: .stepRight)
        let clock = ContinuousClock()
        var renders = 0
        let elapsed = try clock.measure {
            for n in 1..<240 {
                let time = Double(n) / 60
                if n.isMultiple(of: 2) { let f = try sequence.frame(UInt64(n / 2)); layer.apply(f.snapshot, joints: f.joints) }
                layer.render(now: time)
                renders += 1
            }
        }
        let perRender = (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) / Double(renders)
        print(String(format: "ROBOT-FEET-COST %.1f µs per rendered frame (two robots, retarget + planner + solve + joint write)", perRender * 1e6))
        #expect(perRender < 0.002)
    }
}
