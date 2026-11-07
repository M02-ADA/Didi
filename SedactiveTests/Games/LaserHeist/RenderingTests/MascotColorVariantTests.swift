import Foundation
import RealityKit
import Testing
import UIKit
@testable import Sedactive

/// The two approved colour variants of the mascot (Codex's
/// `LaserHeist-Mascot-Color-Variants`): P1 Lemon `#F6CA58`, P2 Tangerine
/// `#F78146`. Same mesh, skeleton, bind pose, size and solver; only the body
/// colour differs, and it follows the established `PlayerID`.
/// Body data is SYNTHETIC (the replay calibrations and the robot demo sequence).
@MainActor
struct MascotColorVariantTests {
    /// The body material keeps its historical slot name on both files.
    static let bodyMaterial = "Mascot_orange"
    static let earMaterial = "Ear_highlight"
    /// The authored body base colours (8-bit sRGB of the USDZ linear diffuse).
    /// Lit by the game's key/fill and neutral environment they render as the
    /// approved swatches, Lemon `#F6CA58` (measured `#F5CA58`) and Tangerine
    /// `#F78146`; that lit result is checked in screen captures, not here.
    static let lemonBody = SIMD3(255, 204, 94)        // linear (1.000, 0.601, 0.111)
    static let tangerineBody = SIMD3(254, 132, 77)    // the earlier orange `mascot.usdz`, unchanged

    private func templates() async throws -> [PlayerID: Entity] {
        try #require(await RobotAvatarLayer.loadTemplates())
    }

    private func model(_ entity: Entity) throws -> ModelEntity {
        try #require(RobotAvatarLayer.skinnedModel(in: entity))
    }

    /// Each material's name and base colour as 8-bit sRGB.
    static func colors(_ model: ModelEntity) -> [String: SIMD3<Int>] {
        var result: [String: SIMD3<Int>] = [:]
        for case let material as PhysicallyBasedMaterial in model.model?.materials ?? [] {
            result[material.name ?? "?"] = srgb(material.baseColor.tint)
        }
        return result
    }

    static func srgb(_ color: UIColor) -> SIMD3<Int> {
        let cg = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let c = cg?.components ?? [0, 0, 0]
        return SIMD3((0..<3).map { Int((min(1, max(0, c[$0])) * 255).rounded()) })
    }


    static func close(_ a: SIMD3<Int>?, _ b: SIMD3<Int>, within: Int = 2) -> Bool {
        guard let a else { return false }
        return (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= within }
    }

    /// The body colour a robot in the layer is showing.
    static func bodyColor(_ robot: RobotAvatarLayer.Robot?) -> SIMD3<Int>? {
        robot.flatMap { colors($0.model)[bodyMaterial] }
    }

    // MARK: - Mapping and loading

    @Test func eachPlayerHasItsOwnFixedResource() {
        #expect(RobotAvatarLayer.resourceName(for: .player1) == "mascot-p1-lemon")
        #expect(RobotAvatarLayer.resourceName(for: .player2) == "mascot-p2-tangerine")
        for player in PlayerID.allCases {
            #expect(Bundle.main.url(forResource: RobotAvatarLayer.resourceName(for: player), withExtension: "usdz") != nil)
        }
        // Every variant is the mascot, so both get the arm clearance.
        #expect(RobotAvatarLayer.headClearance)
    }

    @Test func bothVariantsLoadAsSeparateTemplatesWithTheirColours() async throws {
        let t = try await templates()
        let p1 = try #require(t[.player1]), p2 = try #require(t[.player2])
        #expect(p1 !== p2)
        let c1 = Self.colors(try model(p1)), c2 = Self.colors(try model(p2))
        print("VARIANTCOLORS p1 \(c1.sorted { $0.key < $1.key }) p2 \(c2.sorted { $0.key < $1.key })")
        // Material base colours (the lit, measured result is checked on screen).
        #expect(Self.close(c1[Self.bodyMaterial], Self.lemonBody), "P1 body \(String(describing: c1[Self.bodyMaterial]))")
        #expect(Self.close(c2[Self.bodyMaterial], Self.tangerineBody), "P2 body \(String(describing: c2[Self.bodyMaterial]))")
        // Only the body and ear highlight differ; every other surface is shared.
        #expect(Set(c1.keys) == Set(c2.keys) && c1.count == 7)
        for (name, color) in c1 where ![Self.bodyMaterial, Self.earMaterial].contains(name) {
            #expect(c2[name] == color, "\(name) differs")
        }
        // Same matte finish on both.
        for entity in [p1, p2] {
            let materials = try model(entity).model?.materials.compactMap { $0 as? PhysicallyBasedMaterial } ?? []
            #expect(materials.count == 7 && materials.allSatisfy { $0.metallic.scale < 0.01 && $0.roughness.scale > 0.85 })
            // No glow on the body: zero emission.
            let body = try #require(materials.first { $0.name == Self.bodyMaterial })
            #expect(body.emissiveIntensity == 0 || Self.srgb(body.emissiveColor.color) == .zero,
                    "body emission \(Self.srgb(body.emissiveColor.color)) × \(body.emissiveIntensity)")
        }
    }

    // MARK: - Identical rig and geometry

    @Test func bothVariantsShareJointsBindPoseAndGeometry() async throws {
        let t = try await templates()
        let a = try model(try #require(t[.player1])), b = try model(try #require(t[.player2]))
        #expect(a.jointNames.count == 20 && a.jointNames == b.jointNames)
        for (x, y) in zip(a.jointTransforms, b.jointTransforms) {
            #expect(simd_distance(x.translation, y.translation) < 1e-6 && simd_distance(x.scale, y.scale) < 1e-6)
            #expect(abs(simd_dot(x.rotation.vector, y.rotation.vector)) > 1 - 1e-6)
        }
        // Same skinned vertices and triangles.
        func vertices(_ m: ModelEntity) -> [SIMD3<Float>] {
            m.model?.mesh.contents.models.flatMap { $0.parts.flatMap { $0.positions.elements } } ?? []
        }
        func triangles(_ m: ModelEntity) -> [UInt32] {
            m.model?.mesh.contents.models.flatMap { $0.parts.flatMap { $0.triangleIndices?.elements ?? [] } } ?? []
        }
        let va = vertices(a), vb = vertices(b)
        #expect(!va.isEmpty && va.count == vb.count)
        #expect(zip(va, vb).allSatisfy { simd_distance($0, $1) < 1e-6 })
        #expect(triangles(a) == triangles(b))
        // Same size, soles on the deck.
        let ba = try #require(t[.player1]).visualBounds(relativeTo: nil), bb = try #require(t[.player2]).visualBounds(relativeTo: nil)
        #expect(simd_distance(ba.min, bb.min) < 1e-5 && simd_distance(ba.max, bb.max) < 1e-5)
        #expect(abs(ba.extents.y - RobotSkeleton.modelHeight) < 0.005 && abs(ba.min.y) < 0.005)
    }

    // MARK: - In the scene

    @Test func lemonStandsLeftAndTangerineRightAtOneSize() async throws {
        let input = try LaserReplayScript.load().input
        let scene = LaserScene()
        let layer = RobotAvatarLayer(scene: scene, calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        let p1 = try #require(layer.robots[.player1]), p2 = try #require(layer.robots[.player2])
        #expect(Self.close(Self.bodyColor(p1), Self.lemonBody) && Self.close(Self.bodyColor(p2), Self.tangerineBody))
        #expect(p1.container.parent === scene.players[.player1] && p2.container.parent === scene.players[.player2])
        let a = p1.container.visualBounds(relativeTo: nil), b = p2.container.visualBounds(relativeTo: nil)
        #expect(a.center.x < 0 && b.center.x > 0)  // P1 left lane, P2 right lane
        #expect(p1.container.scale == p2.container.scale && p1.container.scale == SIMD3(repeating: RobotAvatarLayer.modelScale))
        #expect(abs(a.extents.y - b.extents.y) < 1e-4 && abs(a.min.y - b.min.y) < 1e-4 && abs(a.center.z - b.center.z) < 1e-4)
        // Rear view: both face −Z (away from the camera at +Z); no turn on either.
        for robot in [p1, p2] {
            let forward = robot.container.convert(direction: [0, 0, -1], to: nil)
            #expect(simd_dot(simd_normalize(forward), [0, 0, -1]) > 0.999)
        }
        layer.remove()
    }

    @Test func soloShowsOnlyLemon() async throws {
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: LaserScene(), calibrations: input.configuration.calibrations.filter { $0.key == .player1 },
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        #expect(Array(layer.robots.keys) == [.player1])
        #expect(Self.close(Self.bodyColor(layer.robots[.player1]), Self.lemonBody))
    }

    /// Different-coloured clones animate on their own skeletons: P1 jumps while
    /// P2 stands, then P2 crouches while P1 stands; the idle one keeps its pose.
    @Test func variantsAnimateIndependently() async throws {
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: LaserScene(), calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        let p2Bind = try #require(layer.robots[.player2]).model.jointTransforms
        let jump = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: .p1JumpLand)
        var p1Peak: Float = 0, p2Peak: Float = 0
        for index in UInt64(1)...40 {
            let f = try jump.frame(index)
            layer.apply(f.snapshot, joints: f.joints)
            p1Peak = max(p1Peak, layer.robots[.player1]!.container.position.y)
            p2Peak = max(p2Peak, layer.robots[.player2]!.container.position.y)
        }
        #expect(p1Peak > 0.1 && p2Peak == 0)
        let p2Now = try #require(layer.robots[.player2]).model.jointTransforms
        #expect(zip(p2Bind, p2Now).allSatisfy { simd_distance($0.translation, $1.translation) < 1e-3 })
        #expect(Self.close(Self.bodyColor(layer.robots[.player1]), Self.lemonBody))
        #expect(Self.close(Self.bodyColor(layer.robots[.player2]), Self.tangerineBody))
    }

    /// Losing and regaining tracking keeps each robot's entity and colour.
    @Test func trackingLossKeepsEachPlayersEntityAndColour() async throws {
        let input = try LaserReplayScript.load().input
        let layer = RobotAvatarLayer(scene: LaserScene(), calibrations: input.configuration.calibrations,
                                     layout: input.configuration.playerPlaneLayout, templates: try await templates())
        let before = layer.robots.mapValues { ObjectIdentifier($0.model) }
        let loss = RobotDemoSequence(configuration: input.configuration, cameraGeometryRevision: input.cameraGeometryRevision, only: .trackingLoss)
        var sawUnavailable = false
        for index in UInt64(1)...120 {
            let f = try loss.frame(index)
            layer.apply(f.snapshot, joints: f.joints)
            sawUnavailable = sawUnavailable || layer.robots.values.contains { !$0.retargeter.isAvailable }
            #expect(layer.robots.mapValues { ObjectIdentifier($0.model) } == before)
            #expect(Self.close(Self.bodyColor(layer.robots[.player1]), Self.lemonBody))
            #expect(Self.close(Self.bodyColor(layer.robots[.player2]), Self.tangerineBody))
        }
        #expect(sawUnavailable, "the scenario never lost tracking")
    }
}
