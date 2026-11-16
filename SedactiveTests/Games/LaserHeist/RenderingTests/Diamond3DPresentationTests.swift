import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct Diamond3DPresentationTests {
    private func art() async throws -> DiamondArt {
        let artwork = try #require(await LaserScene.loadDiamondArtwork())
        let gem = try #require(artwork.findEntity(named: "Gem"))
        #expect(artwork.findEntity(named: "Sparkle") != nil)
        let bounds = gem.visualBounds(relativeTo: gem)
        #expect(abs(bounds.extents.x - 0.3) < 0.001)
        #expect(abs(bounds.extents.y - 0.2543) < 0.001)
        #expect(abs(bounds.extents.z - 0.09) < 0.001, "true depth, not the old flat quad")
        #expect(length(bounds.center) < 0.001, "resetting Gem.transform must preserve its pivot")
        func materialCount(_ e: Entity) -> Int {
            (e as? ModelEntity)?.model?.materials.count ?? e.children.reduce(0) { $0 + materialCount($1) }
        }
        #expect(materialCount(gem) == 8)
        return try #require(DiamondArt(artwork: artwork))
    }
    @Test func approvedResourceLoadsWithDepthAndSparkle() async throws { _ = try await art() }

    @Test func actualGemOverlapsPosedMascotBodyAfterLateralMovement() async throws {
        let scene = LaserScene()
        let input = try LaserReplayScript.load().input.configuration
        let avatars = RobotAvatarLayer(scene: scene, calibrations: input.calibrations,
            layout: input.playerPlaneLayout, templates: try await RobotAvatarLayer.loadTemplates())
        let robot = try #require(avatars.robots[.player1])
        let skeleton = robot.solver.skeleton
        let gem = try await art().makeDiamond()
        let joints = skeleton.world(robot.model.jointTransforms).position
        for name in ["Head", "Chest", "Forearm_L", "Hand_R", "Shin_L", "Foot_R"] {
            let joint = try #require(skeleton(name))
            gem.root.position = robot.model.convert(position: joints[joint], to: nil)
            let sphere = gem.bodyContactSphere
            #expect(avatars.diamondContactBody(.player1).contains {
                $0.overlaps(center: sphere.center, radius: sphere.radius)
            }, "Expected the gem to touch \(name)")
        }
        let before = gem.bodyContactSphere
        robot.container.position.x += 3
        #expect(!avatars.diamondContactBody(.player1).contains {
            $0.overlaps(center: before.center, radius: before.radius)
        })
        gem.root.position = robot.model.convert(position: joints[try #require(skeleton("Chest"))], to: nil)
        let shifted = gem.bodyContactSphere
        #expect(avatars.diamondContactBody(.player1).contains {
            $0.overlaps(center: shifted.center, radius: shifted.radius)
        })
    }

    @Test func diamondTimeSpawnCatalogClearsStandingMascotsAndStillAllowsHeadPickup() async throws {
        let scene = LaserScene()
        let input = try LaserReplayScript.load().input.configuration
        let layout = input.playerPlaneLayout
        let avatars = RobotAvatarLayer(scene: scene, calibrations: input.calibrations,
            layout: layout, templates: try await RobotAvatarLayer.loadTemplates())
        let gem = try await art().makeDiamond()
        let bodies = PlayerID.allCases.flatMap { avatars.diamondContactBody($0) }
        for player in PlayerID.allCases {
            let calibration = try #require(input.calibrations[player])
            let height = LaserLiveRoundGeometryV1.standingHeight(calibration, layout: layout)
            let lane = layout.centerX(for: player)
            let placements = try LaserLiveRoundGeometryV1.diamondPlacements(player: player, lane: lane, height: height)
            for target in placements {
                let shown = scene.mapping.mascotPoint(x: target.position.x, y: target.position.y,
                    player: player, laneCenter: lane, standingHeight: height)
                gem.root.position = [shown.center.x, shown.center.y, scene.mapping.interactionPlaneZ + 0.15]
                let sphere = gem.bodyContactSphere
                #expect(!bodies.contains { $0.overlaps(center: sphere.center, radius: sphere.radius) },
                        "Spawn overlaps a standing mascot: \(player) \(target.position)")
            }
        }
        gem.root.position = try #require(avatars.extremityPoints(of: .player1)).headTop
        let head = gem.bodyContactSphere
        #expect(avatars.diamondContactBody(.player1).contains { $0.overlaps(center: head.center, radius: head.radius) })
    }

    @Test func sidewaysMovementBringsTheCheekIntoContactWithAGem() async throws {
        let scene = LaserScene()
        let avatars = RobotAvatarLayer(scene: scene, players: [.player1],
                                      templates: try await RobotAvatarLayer.loadTemplates(), withBoards: false)
        let robot = try #require(avatars.robots[.player1])
        let gem = try await art().makeDiamond()
        gem.root.position = robot.model.convert(position: [-0.62, 0.90, 0.08], to: nil)
        let sphere = gem.bodyContactSphere
        func touchesGem() -> Bool {
            avatars.diamondContactBody(.player1).contains {
                $0.overlaps(center: sphere.center, radius: sphere.radius)
            }
        }
        #expect(!touchesGem())
        robot.container.position.x -= 0.13 * RobotAvatarLayer.modelScale
        #expect(touchesGem())
        robot.container.position.x += 0.13 * RobotAvatarLayer.modelScale
        #expect(!touchesGem())
    }

    @Test func collectionIsOnceAndFourClonesAreIndependent() async throws {
        let art = try await art()
        let diamonds = (0..<4).map { _ in art.makeDiamond() }
        for d in diamonds { d.showIdle(); #expect(d.phase == .idle) }
        let first = diamonds[0]
        first.collect(); let count = first.root.children.first?.children.count
        first.collect(); first.showIdle()
        #expect(first.phase == .collected)
        #expect(first.root.children.first?.children.count == count)
        #expect(diamonds.dropFirst().allSatisfy { $0.phase == .idle })
        for d in diamonds { d.retire() }
    }
    @Test func passageGemShowsItsSideAndKeepsItsContactRadius() async throws {
        let diamond = try await art().makeDiamond(passage: true)
        let gem = try #require(diamond.root.findEntity(named: "PassageGem"))
        let bounds = gem.visualBounds(relativeTo: gem)
        #expect(abs(bounds.extents.x - 0.30) < 0.001)
        #expect(abs(bounds.extents.y - 0.2543) < 0.001)
        #expect(abs(bounds.extents.z - bounds.extents.x) < 0.001, "the front and side share the same width")
        #expect(length(bounds.center) < 0.001)
        diamond.showIdle(reduceMotion: false)
        let initial = diamond.bodyContactSphere
        diamond.updatePassagePose(age: 0, reduceMotion: false)
        #expect(abs(gem.orientation.angle) > 0.7)
        #expect(abs(gem.orientation.act([0, -1, 0]).x) < 0.0001)
        #expect(abs(initial.radius - 0.15) < 0.001)
        let turned = gem.orientation
        diamond.updatePassagePose(age: 1.2, reduceMotion: false)
        #expect(simd_length(gem.orientation.vector - turned.vector) > 0.5)
        #expect(simd_distance(diamond.bodyContactSphere.center, initial.center) < 0.0001)
        #expect(abs(diamond.bodyContactSphere.radius - initial.radius) < 0.0001)
        diamond.updatePassagePose(age: 1.2, reduceMotion: true)
        #expect(abs(gem.orientation.angle) < 0.0001)
        diamond.collect(reduceMotion: true)
        #expect(diamond.root.findEntity(named: "diamond.passageBurst") == nil)
    }

    @Test func facetGlintUsesTheGemMaterialsAndRespectsReduceMotion() async throws {
        let diamond = try await art().makeDiamond(passage: true)
        diamond.showIdle(reduceMotion: false)
        let mesh = try #require(diamond.root.findEntity(named: "FacetedGem") as? ModelEntity)
        func intensities() -> [Float] {
            (mesh.model?.materials ?? []).compactMap { ($0 as? PhysicallyBasedMaterial)?.emissiveIntensity }
        }
        diamond.updatePassagePose(age: 0.18, reduceMotion: true)
        let steady = intensities()
        #expect(steady.count > 2)
        diamond.updatePassagePose(age: 0.18, reduceMotion: false)
        let glint = intensities()
        #expect(zip(glint, steady).filter { $0 > $1 }.count == 2)
        diamond.updatePassagePose(age: 0.55, reduceMotion: true)
        #expect(intensities() == steady)
    }

    @Test func luminousRimSharesTheGemPivotThroughRotationAndStopsOnPickup() async throws {
        let art = try await art()
        let diamond = art.makeDiamond(passage: true)
        let gem = try #require(diamond.root.findEntity(named: "PassageGem"))
        let rim = try #require(diamond.root.findEntity(named: "diamond.passageRim"))
        #expect(art.makeDiamond().root.findEntity(named: "diamond.passageRim") == nil)
        diamond.root.position = [1.4, 1.2, -4]
        diamond.showIdle(reduceMotion: false)
        diamond.updatePassagePose(age: 0.27, glow: .approaching, reduceMotion: false)
        #expect(rim.isEnabled)
        #expect(rim.transform.rotation == gem.transform.rotation)
        #expect(rim.transform.translation == gem.transform.translation)
        let approach = try #require(rim.components[OpacityComponent.self]).opacity
        diamond.updatePassagePose(age: 0.64, glow: .collectible, reduceMotion: false)
        #expect(rim.transform.rotation == gem.transform.rotation)
        #expect(try #require(rim.components[OpacityComponent.self]).opacity > approach)
        diamond.collect(reduceMotion: true)
        #expect(!rim.isEnabled)
    }

    @Test func softAuraStaysBehindTheGemOnTheCameraSightline() async throws {
        let asset = try await art()
        let diamond = asset.makeDiamond(passage: true)
        let aura = try #require(diamond.root.findEntity(named: "diamond.passageAura") as? ModelEntity)
        let gem = try #require(diamond.root.findEntity(named: "PassageGem"))
        #expect(asset.makeDiamond().root.findEntity(named: "diamond.passageAura") == nil)
        let auraWidth = aura.visualBounds(relativeTo: aura).extents.x
        #expect(auraWidth > 0.30 && auraWidth < 0.80)
        diamond.showIdle(reduceMotion: false)
        let camera: SIMD3<Float> = [0, 1.05, 3.1]
        for side: Float in [-1.4, 1.4] {
            diamond.root.position = [side, 1.2, 0.1]
            diamond.updatePassagePose(age: 0.4, glow: .collectible, cameraPosition: camera, reduceMotion: false)
            let gemRay = gem.position(relativeTo: nil) - camera
            let auraRay = aura.position(relativeTo: nil) - camera
            #expect(aura.isEnabled)
            #expect(simd_length(auraRay) > simd_length(gemRay))
            #expect(simd_length(simd_cross(simd_normalize(gemRay), simd_normalize(auraRay))) < 0.0001)
        }
        diamond.collect(reduceMotion: true)
        #expect(!aura.isEnabled)
    }

    @Test func passageBurstUsesEightShardsAndResetsCleanly() async throws {
        let art = try await art()
        let passage = art.makeDiamond(passage: true)
        let bonus = art.makeDiamond()
        passage.collect(reduceMotion: false)
        bonus.collect(reduceMotion: false)
        let burst = try #require(passage.root.findEntity(named: "diamond.passageBurst"))
        #expect(burst.children.filter { $0.name == "diamond.pickupShard" }.count == 8)
        #expect(burst.findEntity(named: "diamond.pickupRing") != nil)
        #expect(bonus.root.findEntity(named: "diamond.passageBurst") == nil)
        passage.reset()
        #expect(passage.root.findEntity(named: "diamond.passageBurst") == nil)
    }

    @Test func reduceMotionHasNoFlashAndRetirementCannotRevive() async throws {
        let diamond = try await art().makeDiamond()
        diamond.showIdle(reduceMotion: true)
        diamond.collect(reduceMotion: true)
        #expect(diamond.root.findEntity(named: "diamond.flash")?.isEnabled == false)
        let host = Entity(); host.addChild(diamond.root)
        diamond.retire(); diamond.reset(); diamond.showIdle(); diamond.collect()
        #expect(diamond.phase == .removed && diamond.root.parent == nil)
        #expect(host.children.isEmpty)
    }
    @Test func bonusEffectRetiresEvenWhenCollectedOutcomeRemainsInSource() async throws {
        let scene = LaserScene()
        scene.installDiamondArt(try #require(await LaserScene.loadDiamondArtwork()))
        let view = DiamondTimePresentation(scene: scene)
        var collected = false
        view.source = { _ in [DiamondTimeDiamond(id: 1, lane: .player1, offsetX: 0,
            heightAboveFloor: 1, collected: collected)] }
        let generation = UUID()
        func state(_ time: Double) -> LaserGameState {
            LaserGameState(sessionGeneration: generation, phase: .diamondTime, gameTime: time,
                activityProgress: 300, teamHealth: 5, teamScore: collected ? 25 : 0, encounters: [])
        }
        view.update(state: state(0), diamondTimeStartedAt: 0)
        #expect(view.floatingIDs == [1])
        collected = true
        view.update(state: state(0.01), diamondTimeStartedAt: 0)
        view.update(state: state(0.02), diamondTimeStartedAt: 0)
        #expect(view.collections == 1)
        view.update(state: state(0.5), diamondTimeStartedAt: 0)
        #expect(scene.root.findEntity(named: "diamondTime.diamond.1") == nil)
        view.update(state: state(1), diamondTimeStartedAt: 0)
        #expect(view.collections == 1 && view.floatingIDs.isEmpty)
        view.clear()
    }
}
