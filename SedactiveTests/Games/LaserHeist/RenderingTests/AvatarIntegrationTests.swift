import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The avatar foundation inside the existing LaserHeist scene: asset failure,
/// the `AvatarReference` seam, the CP1-only crouch estimate, the shared loader,
/// teardown, and the real replay round (lasers, vault) with both mascots
/// attached. Body data is the bundled SYNTHETIC replay or constructed samples.
@MainActor
struct AvatarIntegrationTests {
    private final class TestBundleToken {}

    // MARK: - Asset loading fails clearly

    @Test func aMissingAssetIsReportedNotSilentlySkipped() async throws {
        let bundle = Bundle(for: TestBundleToken.self)  // the test bundle has no avatars
        await #expect(throws: RobotAvatarLayer.LoadError.missingResource("mascot-p1-lemon")) {
            _ = try await RobotAvatarLayer.loadTemplates(bundle: bundle)
        }
        await #expect(throws: RobotAvatarLayer.LoadError.missingResource("mascot-p2-tangerine")) {
            _ = try await RobotAvatarLayer.loadTemplate(for: .player2, bundle: bundle)
        }
        #expect(throws: RobotAvatarLayer.LoadError.noSkinnedModel("empty")) {
            try RobotAvatarLayer.validate(Entity(), name: "empty")
        }
    }

    @Test func aRigMissingRequiredJointsIsNamed() async throws {
        let model = try #require(RobotAvatarLayer.skinnedModel(in: try await RobotAvatarLayer.loadTemplate(for: .player1)))
        #expect(RobotAvatarLayer.missingJoints(paths: model.jointNames, bind: model.jointTransforms).isEmpty)
        let kept = model.jointNames.indices.filter { !model.jointNames[$0].hasSuffix("/Head") && !model.jointNames[$0].hasSuffix("Foot_R") }
        let missing = RobotAvatarLayer.missingJoints(paths: kept.map { model.jointNames[$0] }, bind: kept.map { model.jointTransforms[$0] })
        #expect(Set(missing) == ["Head", "Foot_R"])
        #expect(RobotAvatarLayer.LoadError.missingJoints("x", missing).description.contains("Head"))
    }

    @Test func sharedTemplatesLoadOnceAndAreReused() async throws {
        let first = try await RobotAvatarLayer.sharedTemplates()
        let second = try await RobotAvatarLayer.sharedTemplates()
        for player in PlayerID.allCases { #expect(first[player] === second[player]) }
        #expect(first[.player1] !== first[.player2])  // two resources, two templates
    }

    // MARK: - The reference seam

    /// The adapter reads only the accepted calibration and converts it to game
    /// units; driving the rig through it or through the calibration is identical.
    @Test func theReferenceAdapterMatchesTheCalibrationPath() throws {
        let input = try LaserReplayScript.load().input
        let layout = input.configuration.playerPlaneLayout
        for (player, calibration) in input.configuration.calibrations {
            let reference = AvatarReference(calibration: calibration, layout: layout)
            #expect(reference.playerID == player && reference.calibrationRevision == calibration.revision)
            #expect(abs(reference.standingHeight - calibration.mapping.gameY(imageY: calibration.standingCrownImageY, layout: layout)) < 1e-9)
            #expect(reference.standingHeight > reference.standingHipY && reference.standingHipY > reference.standingLeftAnkleY)
            #expect(reference.laneCenterX == layout.centerX(for: player))
        }
        let sequence = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision,
                                         only: .asymmetricArms)
        let calibration = try #require(input.configuration.calibrations[.player1])
        var a = RobotRetargeter(calibration: calibration, layout: layout, robotLegRest: 0.293)
        var b = RobotRetargeter(reference: AvatarReference(calibration: calibration, layout: layout), robotLegRest: 0.293)
        for index in UInt64(1)...40 {
            let f = try sequence.frame(index)
            a.update(sample: f.snapshot.players[.player1], joints: f.joints.players[.player1], time: f.snapshot.capturedAt)
            b.update(sample: f.snapshot.players[.player1], joints: f.joints.players[.player1], time: f.snapshot.capturedAt)
        }
        #expect(a.targets == b.targets && a.lift == b.lift && a.sway == b.sway)
    }

    // MARK: - CP1-only crouch (replay, no joints)

    private func sample(_ c: PlayerCalibration, _ layout: PlayerPlaneLayout, crown: Double, sole: Double = 0) throws -> PlayerBodySample {
        func v(_ x: Double) throws -> EstimatedScalar { try EstimatedScalar(value: x, validity: .valid) }
        return PlayerBodySample(playerID: c.playerID, calibrationRevision: c.revision, trackingStatus: .reliable,
            geometry: BodyGeometry(crownY: try v(crown), leftWristY: try v(0.8), rightWristY: try v(0.8),
                                   leftSoleY: try v(sole), rightSoleY: try v(sole), centerX: try v(layout.centerX(for: c.playerID))),
            jumpState: JumpState(phase: sole > 0.05 ? .airborne : .grounded, validity: .valid))
    }

    /// Without joints, a crown below standing lowers the avatar (both legs
    /// bend); standing restores it; a jump lifts it without a crouch.
    @Test func withoutJointsTheCrownDropShowsADuck() throws {
        let input = try LaserReplayScript.load().input
        let layout = input.configuration.playerPlaneLayout
        let c = try #require(input.configuration.calibrations[.player2])
        let reference = AvatarReference(calibration: c, layout: layout)
        var r = RobotRetargeter(reference: reference, robotLegRest: 0.293)
        var t = 0.0
        func feed(crown: Double, sole: Double = 0, frames: Int = 20) throws {
            for _ in 0..<frames {
                t += 1.0 / 30
                r.update(sample: try sample(c, layout, crown: crown, sole: sole), joints: nil, time: t)
            }
        }
        try feed(crown: reference.standingHeight)
        #expect(r.targets.pelvisDrop < 0.002)
        try feed(crown: reference.standingHeight * 0.85)  // a 15% duck
        let ducked = r.targets.pelvisDrop
        #expect(ducked > 0.05 && ducked <= 0.293 * 0.55 + 1e-4, "drop \(ducked)")
        #expect(r.targets.footLift.values.allSatisfy { $0 == 0 } && r.lift < 0.001)
        try feed(crown: reference.standingHeight)
        #expect(r.targets.pelvisDrop < 0.002)
        try feed(crown: reference.standingHeight + 0.2, sole: 0.2)
        #expect(r.lift > 0.1 && r.targets.pelvisDrop < 0.002)
    }

    /// Recalibration rebuilds the layer from new references (new revision, any
    /// heights): colours stay with the PlayerID and both stay one size.
    @Test func coloursFollowThePlayerIDAcrossRecalibration() async throws {
        let input = try LaserReplayScript.load().input
        let layout = input.configuration.playerPlaneLayout
        let templates = try await RobotAvatarLayer.sharedTemplates()
        func references(p1Height: Double, p2Height: Double, revision: UInt64) -> [PlayerID: AvatarReference] {
            Dictionary(uniqueKeysWithValues: [(PlayerID.player1, p1Height), (.player2, p2Height)].map { player, height in
                (player, AvatarReference(playerID: player, calibrationRevision: revision, standingHeight: height,
                                         standingHipY: height * 0.53, standingLeftAnkleY: 0.05, standingRightAnkleY: 0.05,
                                         laneCenterX: layout.centerX(for: player)))
            })
        }
        for (p1, p2, revision) in [(1.7, 1.1, UInt64(1)), (1.0, 1.9, 2)] {
            let layer = RobotAvatarLayer(scene: LaserScene(), references: references(p1Height: p1, p2Height: p2, revision: revision),
                                         templates: templates)
            let a = try #require(layer.robots[.player1]), b = try #require(layer.robots[.player2])
            #expect(MascotColorVariantTests.close(MascotColorVariantTests.bodyColor(a), MascotColorVariantTests.lemonBody))
            #expect(MascotColorVariantTests.close(MascotColorVariantTests.bodyColor(b), MascotColorVariantTests.tangerineBody))
            #expect(a.container.scale == b.container.scale && a.container.scale == SIMD3(repeating: RobotAvatarLayer.modelScale))
            #expect(a.retargeter.reference?.calibrationRevision == revision)
            layer.remove()
        }
    }

    // MARK: - Teardown

    @Test func removeTakesAvatarsAndLightsAwayAndRestoresPictograms() async throws {
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await RobotAvatarLayer.sharedTemplates())
        #expect(layer.robots.count == 2)
        #expect(scene.root.findEntity(named: "robot.lights") != nil)
        for player in PlayerID.allCases {
            #expect(scene.players[player]?.findEntity(named: "player.\(player.rawValue).robot") != nil)
            #expect(scene.players[player]?.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled == false)
        }
        layer.remove()
        layer.remove()  // idempotent
        #expect(layer.robots.isEmpty && scene.root.findEntity(named: "robot.lights") == nil)
        for player in PlayerID.allCases {
            #expect(scene.players[player]?.findEntity(named: "player.\(player.rawValue).robot") == nil)
            #expect(scene.players[player]?.findEntity(named: "player.\(player.rawValue).surface")?.isEnabled == true)
        }
        // A new layer (Retry) adds exactly one set again.
        let again = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await RobotAvatarLayer.sharedTemplates())
        func count(_ name: String) -> Int {
            func walk(_ e: Entity) -> Int { (e.name == name ? 1 : 0) + e.children.reduce(0) { $0 + walk($1) } }
            return walk(scene.root)
        }
        #expect(count("robot.lights") == 1 && count("player.player1.robot") == 1 && count("player.player2.robot") == 1)
        again.remove()
    }

    // MARK: - The replay round with avatars, lasers and the vault

    private func named(_ name: String, in parent: Entity, _ entity: Entity? = nil) -> Entity {
        let entity = entity ?? Entity()
        entity.name = name
        parent.addChild(entity)
        return entity
    }

    /// A scene with door artwork, as in `VaultPresentationTests`.
    private func sceneWithDoor() -> LaserScene {
        let scene = LaserScene()
        let artwork = Entity()
        let door = named("VaultDoorRoot", in: artwork)
        _ = named("UnlockedLight", in: door)
        for side in ["LeftDoorPanel", "RightDoorPanel"] {
            _ = named("Art", in: named(side, in: door), ModelEntity(mesh: .generatePlane(width: 2.4, height: 3.2)))
        }
        scene.installVaultDoor(artwork)
        return scene
    }

    private struct RoundRecord {
        var judgements: [ReplayTargetResult] = []
        var p1MaxDrop: Float = 0
        var p2MaxDrop: Float = 0
        var maxLift: [PlayerID: Float] = [:]
        var attachedEveryFrame = true
        var vault = VaultPresentation.Diagnostics()
    }

    private func playRound(withAvatars: Bool) async throws -> (RoundRecord, LaserScene, GameplayScenePresenter) {
        let script = try LaserReplayScript.load().freshRound(generation: UUID())
        let session = GameSessionCoordinator(script: script)
        try await session.start()
        let scene = sceneWithDoor()
        if withAvatars {
            scene.robotAvatars = RobotAvatarLayer(scene: scene, calibrations: script.input.configuration.calibrations,
                                                  layout: script.input.configuration.playerPlaneLayout,
                                                  templates: try await RobotAvatarLayer.sharedTemplates())
        }
        let presenter = GameplayScenePresenter(scene: scene, configuration: script.configuration, encounters: script.encounters)
        var record = RoundRecord()
        for tick in 0...Int(script.duration * 30 + 1) {
            try await session.advance(to: Double(tick) / 30)
            guard let state = session.state else { continue }
            presenter.apply(state: state, events: session.events, snapshot: session.latestSnapshot)
            if let robots = scene.robotAvatars {
                record.p1MaxDrop = max(record.p1MaxDrop, robots.robots[.player1]?.retargeter.targets.pelvisDrop ?? 0)
                record.p2MaxDrop = max(record.p2MaxDrop, robots.robots[.player2]?.retargeter.targets.pelvisDrop ?? 0)
                for player in PlayerID.allCases {
                    record.maxLift[player] = max(record.maxLift[player] ?? 0, robots.robots[player]?.retargeter.lift ?? 0)
                    if robots.robots[player]?.container.parent !== scene.players[player] { record.attachedEveryFrame = false }
                }
            }
        }
        #expect(session.phase == .finished)
        record.judgements = session.results
        record.vault = presenter.vault.diagnostics
        return (record, scene, presenter)
    }

    /// The whole replay round with both mascots: they stay on their lanes
    /// through the lasers and the vault, duck and jump with the replay's
    /// bodies, and the verdicts and vault presentation are exactly those
    /// without avatars. Then teardown leaves nothing behind.
    @Test func theReplayRoundRunsUnchangedWithBothMascotsAttached() async throws {
        let (plain, _, _) = try await playRound(withAvatars: false)
        let (posed, scene, presenter) = try await playRound(withAvatars: true)
        #expect(plain.judgements == posed.judgements && !posed.judgements.isEmpty)
        #expect(plain.vault == posed.vault)
        #expect(posed.vault.reveals == 1 && posed.vault.opens == 1 && posed.vault.activations == 6)
        #expect(posed.attachedEveryFrame)
        // Duck lasers lower the avatars. At the jump laser the replay's P2 soles
        // are 0.025 game units up (CLEAR) and P1's stay on the floor (HIT): only P2 lifts.
        #expect(posed.p1MaxDrop > 0.02 && posed.p2MaxDrop > 0.02, "drops \(posed.p1MaxDrop) \(posed.p2MaxDrop)")
        #expect((posed.maxLift[.player2] ?? 0) > 0 && posed.maxLift[.player1] == 0, "lift \(posed.maxLift)")
        let robots = try #require(scene.robotAvatars)
        #expect(robots.robots[.player1].map { MascotColorVariantTests.close(MascotColorVariantTests.bodyColor($0), MascotColorVariantTests.lemonBody) } == true)
        #expect(robots.robots[.player2].map { MascotColorVariantTests.close(MascotColorVariantTests.bodyColor($0), MascotColorVariantTests.tangerineBody) } == true)
        presenter.stop()
        robots.remove()
        scene.robotAvatars = nil
        #expect(scene.vaultDoorDepth == nil && scene.root.findEntity(named: "robot.lights") == nil)
        #expect(scene.players[.player1]?.findEntity(named: "player.player1.robot") == nil)
    }

    // MARK: - The mascots don't cover the vault's feedback

    private func project(_ point: SIMD3<Float>, in scene: LaserScene, aspect: Float) -> SIMD2<Float> {
        let camera = scene.layout.cameraPosition
        let forward = normalize(scene.layout.cameraTarget - camera)
        let right = normalize(cross(forward, [0, 1, 0]))
        let up = cross(right, forward)
        let d = point - camera
        let t = tan(scene.layout.cameraVerticalFieldOfView * .pi / 360)
        let depth = dot(d, forward)
        return [0.5 + dot(d, right) / (depth * t * aspect) / 2, 0.5 - dot(d, up) / (depth * t) / 2]
    }

    private func screenRect(_ center: SIMD3<Float>, size: SIMD2<Float>, in scene: LaserScene, aspect: Float) -> SIMD4<Float> {
        let corners = [SIMD2<Float>(-1, -1), [1, -1], [-1, 1], [1, 1]].map {
            project(center + SIMD3($0.x * size.x / 2, $0.y * size.y / 2, 0), in: scene, aspect: aspect)
        }
        return [corners.map(\.x).min()!, corners.map(\.x).max()!, corners.map(\.y).min()!, corners.map(\.y).max()!]
    }

    private func overlaps(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        !(a.y <= b.x || b.y <= a.x || a.w <= b.z || b.w <= a.z)
    }

    /// Standing mascots (their real bounds) leave the six indicators, the
    /// countdown bar and number, and the completion outlines visible on every
    /// iPad landscape size.
    @Test(arguments: [(1366, 1024), (1210, 834), (1194, 834), (1180, 820), (1133, 744)])
    func standingMascotsLeaveTheVaultFeedbackVisible(viewport: (width: Int, height: Int)) async throws {
        let input = try LaserReplayScript.load().input
        let scene = sceneWithDoor()
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await RobotAvatarLayer.sharedTemplates())
        let aspect = Float(viewport.width) / Float(viewport.height)
        let mascots = PlayerID.allCases.compactMap { player -> SIMD4<Float>? in
            guard let bounds = layer.robots[player]?.container.visualBounds(relativeTo: nil) else { return nil }
            return screenRect([bounds.center.x, bounds.center.y, bounds.max.z], size: [bounds.extents.x, bounds.extents.y],
                              in: scene, aspect: aspect)
        }
        #expect(mascots.count == 2)
        let door = scene.layout.vaultDoorStopZ
        var feedback: [(String, SIMD4<Float>)] = [
            ("countdown", screenRect([0, VaultPresentation.countdownHeight, door + 0.04],
                                     size: [VaultPresentation.countdownWidth, 0.16], in: scene, aspect: aspect)),
            ("number", screenRect([0, VaultPresentation.digitCenterY, door + 0.05],
                                  size: [0.36, VaultPresentation.digitHeight], in: scene, aspect: aspect)),
        ]
        for player in PlayerID.allCases {
            let x = (player == .player1 ? -1 : 1) * VaultPresentation.indicatorColumnX
            feedback.append(("\(player) outline", screenRect([x, VaultPresentation.outlineCenterY, VaultPresentation.indicatorDepthZ + 0.045],
                                                             size: VaultPresentation.outlineSize, in: scene, aspect: aspect)))
        }
        for (name, rect) in feedback {
            for mascot in mascots { #expect(!overlaps(rect, mascot), "\(name) under a mascot at \(viewport)") }
        }
        layer.remove()
    }
}
