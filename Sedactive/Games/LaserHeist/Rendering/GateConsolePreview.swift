//
//  GateConsolePreview.swift
//  Sedactive
//

#if DEBUG
import Foundation
import RealityKit
import SwiftUI

/// DEBUG review of a live gate's wall consoles without a camera: launch with
/// `-replay -gateConsolePreview [solo] [seconds]`. SYNTHETIC player poses (from the bundled
/// replay calibrations) go through the real retargeter, steering and solver: each player leans
/// toward their own wall, straightens up at the dock, then reaches HIGH, MIDDLE and LOW with a
/// straight arm. A button lights when the pose's wrist is inside its zone as the live judge places
/// it (`LaserLiveRoundGeometryV1` zone + the body centre + `RobotAvatarLayer.vaultReachShift`);
/// the preview has no entry/freshness rules and no game: presentation review only, never gameplay.
/// `seconds` holds the scripted moment (screenshots); otherwise it loops.
@MainActor
final class GateConsolePreview {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-gateConsolePreview") }

    static var requested: (solo: Bool, heldAt: Double?) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-gateConsolePreview") else { return (false, nil) }
        let rest = arguments[(index + 1)...].prefix { !$0.hasPrefix("-") }
        return (rest.contains("solo"), rest.compactMap(Double.init).first)
    }

    /// The script: lean to the wall, upright at the dock, then each button with a pause between.
    static let leanUntil = 2.4, dockedUntil = 3.0
    static let reaches: [(button: LaserVaultButton, from: Double, to: Double)] = [
        (.top, 3.0, 4.0), (.middle, 4.4, 5.4), (.bottom, 5.8, 6.8)]
    static let loop = 10.0

    private var subscription: EventSubscription?
    /// Kept for the preview's life (held moments still finish their press animations).
    private var vault: VaultPresentation?
    private var elapsed = 0.0
    private var frame: UInt64 = 0
    private var pressed: [PlayerID: Set<LaserVaultButton>] = [:]
    private var previousInside: [PlayerID: Set<LaserVaultButton>] = [:]
    private let generation = UUID()
    /// When every shown button was green: the gate opens a second later (so the greens can be seen).
    private var allPressedAt: Double?
    private let vaultID = UUID()

    func start(on content: RealityViewCameraContent, scene: LaserScene, robots: RobotAvatarLayer,
               configuration: BodyInputConfiguration, heldAt: Double?) throws {
        let roster = Set(robots.robots.keys)
        let round = try LaserRoundConfiguration(evidenceTiming: .init(windowBefore: 0.125, windowAfter: 0.125, deliveryAllowance: 0.125),
                                                clearanceMargin: 0.005, diamondPoints: 25)
        let vault = VaultPresentation(scene: scene, configuration: round)
        self.vault = vault
        vault.visiblePlayers = roster
        vault.liveConsoles = { [weak robots] player in robots?.consoles[player] }
        let references = configuration.calibrations.filter { roster.contains($0.key) }
            .mapValues { AvatarReference(calibration: $0, layout: configuration.playerPlaneLayout) }
        func step(to t: Double) {
            frame += 1
            var players: [PlayerID: PlayerBodySample] = [:], poses: [PlayerID: PresentationPoseSample] = [:]
            for (player, r) in references {
                guard let c = configuration.calibrations[player] else { continue }
                let (joints, wrist) = Self.pose(r, player: player, at: t)
                poses[player] = PresentationPoseSample(playerID: player, calibrationRevision: c.revision, joints: joints)
                if let sample = try? Self.sample(player, c, center: r.laneCenterX) { players[player] = sample }
                // The judge's zone for this capture: approved place + body centre + mascot distance.
                if let shift = robots.vaultReachShift(player, capturedAt: t) {
                    let h = r.standingHeight, out = LaserLiveRoundGeometryV1.outward(player)
                    var inside: Set<LaserVaultButton> = []
                    for (button, share) in LaserLiveRoundGeometryV1.vaultShares {
                        let zx = r.laneCenterX + out * share.out * h + shift, zy = share.y * h
                        if hypot(wrist.x - zx, wrist.y - zy) <= LaserLiveRoundGeometryV1.vaultRadiusShare * h { inside.insert(button) }
                    }
                    // Outside → inside, as the judge requires.
                    let new = inside.subtracting(previousInside[player, default: []]).subtracting(pressed[player, default: []])
                    if !new.isEmpty {
                        print(String(format: "[GateConsolePreview] t %.2f %@ pressed %@ · wrist (%.3f, %.3f) · shift %.3f",
                                     t, player.rawValue, new.map(\.rawValue).joined(separator: ","), wrist.x, wrist.y, shift))
                    }
                    pressed[player, default: []].formUnion(new)
                    previousInside[player] = inside
                }
            }
            robots.apply(BodySnapshot(sessionGeneration: generation, frameID: frame, capturedAt: t, cameraGeometryRevision: 1, players: players),
                         joints: PresentationPoseFrame(sessionGeneration: generation, frameID: frame, capturedAt: t, players: poses))
            let all = roster.allSatisfy { pressed[$0, default: []].count == LaserVaultButton.allCases.count }
            if all, allPressedAt == nil { allPressedAt = t }
            let opens = allPressedAt.map { t >= $0 + 1 } ?? false
            let state = LaserGameState(sessionGeneration: generation, phase: .vault, gameTime: t, activityProgress: 0, teamHealth: 5,
                                       teamScore: 0, encounters: [], missionProgress: 0,
                                       vault: LaserVaultState(id: vaultID, deadline: Self.dockedUntil + round.vaultDuration + 1,
                                                              buttons: pressed, opened: opens))
            vault.update(state: state, travelDistance: 0)
        }
        if let heldAt {
            var t = 0.0
            while t < heldAt { t += 1.0 / 30; step(to: t) }
            return
        }
        subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            guard let self else { return }
            elapsed += event.deltaTime
            if elapsed > Self.loop { elapsed = 0; pressed = [:]; previousInside = [:]; allPressedAt = nil; vault.reset() }
            step(to: elapsed + Double(frame) * 1e-6)
        }
    }

    private static func sample(_ player: PlayerID, _ c: PlayerCalibration, center: Double) throws -> PlayerBodySample {
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        return PlayerBodySample(playerID: player, calibrationRevision: c.revision, trackingStatus: .reliable,
                                geometry: BodyGeometry(crownY: try v(1.7), leftWristY: try v(1), rightWristY: try v(1),
                                                       leftSoleY: try v(0), rightSoleY: try v(0), centerX: try v(center)),
                                jumpState: JumpState(phase: .grounded, validity: .valid))
    }

    /// The scripted pose at `t` (unmirrored plane) and its outer wrist.
    static func pose(_ r: AvatarReference, player: PlayerID, at t: Double) -> ([PresentationJoint: PresentationPoint], SIMD2<Double>) {
        let h = r.standingHeight, L = r.laneCenterX, hipY = r.standingHipY
        let out = LaserLiveRoundGeometryV1.outward(player)
        // Lean to the wall first; LOW, like its zone, also takes a slight lean (0.06 h) while reaching.
        let reaching = reaches.first(where: { t >= $0.from && t < $0.to })
        var reachK = 0.0
        if let r = reaching {
            let u: Double = (t - r.from) / (r.to - r.from)
            reachK = min(1.0, min(u, 1.0 - u) * 4.0)
        }
        var lean: Double = 0
        if t < leanUntil { lean = out * 0.09 * min(1.0, t / 0.3) }
        _ = reachK
        let s = lean * h, head = s * (0.9 * h - hipY) / (0.82 * h - hipY)
        // A real arm: upper arm 0.186 h, forearm 0.146 h (shoulder→wrist 0.332 h).
        let upper = 0.186 * h, fore = 0.146 * h
        let outer = SIMD2(s + out * 0.13 * h, 0.82 * h), inner = SIMD2(s - out * 0.13 * h, 0.82 * h)
        func hanging(_ sh: SIMD2<Double>, _ side: Double) -> (SIMD2<Double>, SIMD2<Double>) {
            let dir = simd_normalize(SIMD2(0.08 * side, -1))
            return (sh + dir * upper, sh + dir * (upper + fore))
        }
        var arm = hanging(outer, out)
        if let reach = reaches.first(where: { t >= $0.from && t < $0.to }), let share = LaserLiveRoundGeometryV1.vaultShares[reach.button] {
            // A deliberate reach (a straight sweep up the column would pass through the other
            // buttons' zones, as it would for a player): the hand rises close to the body to the
            // button's height, then the arm extends sideways to its straight-arm point, the elbow
            // bent as needed on the way (two segments of fixed length).
            let u = (t - reach.from) / (reach.to - reach.from), k = min(1, min(u, 1 - u) * 4)
            let target = SIMD2(out * share.out * h, share.y * h)
            let end = outer + simd_normalize(target - outer) * min(simd_length(target - outer), (upper + fore) * 0.98)
            let raised = SIMD2(out * 0.2 * h, end.y)
            let wrist = k < 0.5 ? arm.1 + (raised - arm.1) * (k * 2) : raised + (end - raised) * ((k - 0.5) * 2)
            let v = wrist - outer, d = min(simd_length(v), upper + fore - 1e-6), dir = v / simd_length(v)
            let cosA = (upper * upper + d * d - fore * fore) / (2 * upper * d), angle = acos(max(-1, min(1, cosA)))
            let turn = -out * angle
            let elbowDir = SIMD2(dir.x * cos(turn) - dir.y * sin(turn), dir.x * sin(turn) + dir.y * cos(turn))
            arm = (outer + elbowDir * upper, outer + dir * d)
        }
        let ia = hanging(inner, -out)
        let (oe, ow, ie, iw): (PresentationJoint, PresentationJoint, PresentationJoint, PresentationJoint) = out > 0
            ? (.leftElbow, .leftWrist, .rightElbow, .rightWrist) : (.rightElbow, .rightWrist, .leftElbow, .leftWrist)
        func p(_ v: SIMD2<Double>) -> PresentationPoint { PresentationPoint(x: L + v.x, y: v.y, confidence: 0.9) }
        let joints: [PresentationJoint: PresentationPoint] = [
            .leftShoulder: p(SIMD2(s + 0.13 * h, 0.82 * h)), .rightShoulder: p(SIMD2(s - 0.13 * h, 0.82 * h)),
            .leftHip: p(SIMD2(0.07 * h, hipY)), .rightHip: p(SIMD2(-0.07 * h, hipY)), .nose: p(SIMD2(head, 0.9 * h)),
            oe: p(arm.0), ow: p(arm.1), ie: p(ia.0), iw: p(ia.1)]
        return (joints, SIMD2(L + arm.1.x, arm.1.y))
    }
}
#endif
