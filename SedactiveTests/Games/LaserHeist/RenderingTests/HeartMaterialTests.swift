import Foundation
import RealityKit
import Testing
import UIKit
@testable import Sedactive

@MainActor struct HeartMaterialTests {
    @Test func hudPaletteUsesExactSRGBBaseAndHighlightInFourPBRRegions() async throws {
        let heart = try await HeartArt.load().makeHeart(generation: UUID())
        let mesh = try #require(heart.root.findEntity(named: "GEO_LH_Heart") as? ModelEntity)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let expected = [[226, 57, 65], [235, 106, 68], [211, 53, 60], [195, 48, 55]].map {
            $0.map { linear(CGFloat($0) / 255) }
        }
        let materials = try #require(mesh.model).materials
        #expect(materials.count == 4)
        for (index, value) in materials.enumerated() {
            let m = try #require(value as? PhysicallyBasedMaterial)
            let color = try #require(m.baseColor.tint.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, intent: .relativeColorimetric, options: nil)?.components)
            for channel in 0..<3 { #expect(abs(color[channel] - expected[index][channel]) < 0.00001) }
            #expect(m.roughness.scale == 0.6 && m.metallic.scale == 0)
            #expect(m.specular.scale == 0.5)
            let emission = try #require(m.emissiveColor.color.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, intent: .relativeColorimetric, options: nil)?.components)
            for channel in 0..<3 { #expect(abs(emission[channel] - color[channel]) < 0.00001) }
            #expect(m.emissiveIntensity == HeartCollectible.shadowFill)
            print("HEART_PBR \(index) color=\(color) roughness=\(m.roughness.scale) specular=\(m.specular.scale) emissionColor=\(m.emissiveColor.color.cgColor) intensity=\(m.emissiveIntensity)")
        }
        #expect(heart.root.findEntity(named: "heart.flash")?.isEnabled == false)
    }

    @Test func neutralFillIsScopedToEachHeartAndDoesNotLeakToOtherEntities() async throws {
        let art = try await HeartArt.load()
        let a = art.makeHeart(generation: UUID()), b = art.makeHeart(generation: UUID())
        let host = Entity(); host.addChild(a.root); host.addChild(b.root)
        let first = try #require(a.root.findEntity(named: "heart.body"))
        let second = try #require(b.root.findEntity(named: "heart.body"))
        #expect(a.root.components[ImageBasedLightComponent.self] != nil)
        #expect(b.root.components[ImageBasedLightComponent.self] != nil)
        #expect(try #require(first.components[ImageBasedLightReceiverComponent.self]).imageBasedLight === a.root)
        #expect(try #require(second.components[ImageBasedLightReceiverComponent.self]).imageBasedLight === b.root)
        #expect(host.components[ImageBasedLightReceiverComponent.self] == nil)
        a.useDefaultEnvironmentForComparison()
        #expect(first.components[ImageBasedLightReceiverComponent.self] == nil)
        #expect(second.components[ImageBasedLightReceiverComponent.self] != nil)
        a.retire()
        #expect(a.root.parent == nil && b.root.parent === host)
    }
    @Test(arguments: [false, true]) func idleHaloIsBoundedAndRemovedOnCollectionAndRetirement(reduceMotion: Bool) async throws {
        let art = try await HeartArt.load()
        let heart = art.makeHeart(generation: UUID())
        let glow = try #require(heart.root.findEntity(named: "heart.idleGlow"))
        heart.showIdle(reduceMotion: reduceMotion)
        #expect(glow.isEnabled && glow.children.count == 3)
        let mesh = try #require(heart.root.findEntity(named: "GEO_LH_Heart"))
        #expect(abs(mesh.visualBounds(relativeTo: mesh).extents.x - 0.3) < 0.001)
        for (index, shell) in glow.children.enumerated() {
            let model = try #require((shell as? ModelEntity)?.model)
            #expect(model.materials.allSatisfy { ($0 as? UnlitMaterial)?.faceCulling == .front })
            for value in model.materials {
                let material = try #require(value as? UnlitMaterial)
                let expected = index == 0 ? [235.0, 106, 68] : [226.0, 57, 65]
                let actual = try #require(material.color.tint.cgColor.converted(
                    to: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, intent: .relativeColorimetric, options: nil)?.components)
                for channel in 0..<3 {
                    let srgb = expected[channel] / 255
                    let linear = srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
                    #expect(abs(actual[channel] - linear) < 0.00001)
                }
            }
            #expect(shell.scale.x >= 1 && shell.scale.x <= 1.12)
        }
        heart.collect(generation: heart.generation, target: heart.target, now: 1, reduceMotion: reduceMotion)
        #expect(!glow.isEnabled)
        heart.retire(); heart.showIdle()
        #expect(!glow.isEnabled && heart.root.parent == nil)
        let replacement = art.makeHeart(generation: UUID())
        replacement.showIdle(reduceMotion: true)
        #expect(replacement.root.findEntity(named: "heart.idleGlow")?.isEnabled == true)
        #expect(!glow.isEnabled)
    }

}
