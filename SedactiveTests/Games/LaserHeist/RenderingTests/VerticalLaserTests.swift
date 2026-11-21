import Foundation
import RealityKit
import Testing
@testable import Sedactive

/// The vertical laser prototype (15 November 2026): presentation only, not in gameplay.
@MainActor
struct VerticalLaserTests {
    private let layout = LaserWorldLayout()

    private func laser(reduceMotion: Bool = false, x: Float = 0, z: Float = -10) -> VerticalLaser {
        let laser = VerticalLaser(layout: layout)
        laser.reduceMotion = reduceMotion
        laser.setPlacement(x: x, worldZ: z)
        return laser
    }

    /// Every drawn layer's state: enabled, world transform and opacity (the frame as drawn).
    private func frame(_ laser: VerticalLaser) -> [String] {
        var lines: [String] = []
        func walk(_ entity: Entity, _ path: String) {
            let opacity = entity.components[OpacityComponent.self]?.opacity ?? 1
            let m = entity.transformMatrix(relativeTo: nil)
            let values = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z] }
            lines.append("\(path) \(entity.isEnabled) \(opacity) " + values.map { String(format: "%.5f", $0) }.joined(separator: ","))
            for (i, child) in entity.children.enumerated() { walk(child, "\(path)/\(i)") }
        }
        walk(laser.root, "root")
        return lines
    }

    @Test func itHangsFromTheCeilingToAReceiverOnTheFloor() {
        let laser = laser()
        #expect(laser.topY < layout.corridorHeight && laser.topY > layout.corridorHeight - 0.4)
        #expect(laser.bottomY > layout.corridorFloorY && laser.bottomY < layout.corridorFloorY + 0.1)
        laser.present(.active(elapsed: 1))
        let span = try? #require(laser.litSpan)
        #expect(abs((span?.lowerBound ?? 0) - laser.bottomY) < 1e-5 && abs((span?.upperBound ?? 0) - laser.topY) < 1e-5)
    }

    @Test func farAwayItIsAnUnpoweredPathNotABeam() {
        let laser = laser(z: -60)
        laser.present(.inactive)
        #expect(laser.showsTrace && !laser.isEnergized && laser.litSpan == nil)
        // It emerges from the corridor's haze and stays at least ~0.1° wide far away.
        #expect(abs(laser.opacity - (1 - CorridorDepth.haze(atDistance: layout.cameraPosition.z + 60))) < 1e-5)
        #expect(laser.traceWidth >= (layout.cameraPosition.z + 60) * LaserGate.traceAngle - 1e-5)
        // From the warning distance in, the path is exactly the core's width.
        laser.setPlacement(x: 0, worldZ: -15)
        #expect(abs(laser.traceWidth - VerticalLaser.coreWidth) < 1e-6)
    }

    @Test("The beam pours down from the emitter and is complete exactly as the gate turns active",
          arguments: [false, true])
    func theBeamPoursDownAndIsCompleteAtActive(reduceMotion: Bool) throws {
        let laser = laser(reduceMotion: reduceMotion)
        var lastBottom = Float.infinity
        for step in 0...100 {
            let p = Float(step) / 100
            laser.present(.warning(progress: p))
            let span = try #require(laser.litSpan)
            // Always anchored at the emitter, only ever growing down, and short until the pour.
            #expect(abs(span.upperBound - laser.topY) < 1e-5)
            #expect(span.lowerBound <= lastBottom + 1e-5)
            lastBottom = span.lowerBound
            if p < VerticalLaser.extensionStart {
                #expect(laser.topY - span.lowerBound <= VerticalLaser.stubLength + 1e-5)
            }
            #expect(abs(laser.drawnCoreWidth - VerticalLaser.coreWidth) < 1e-6)
            #expect(laser.showsTrace)
        }
        #expect(abs(lastBottom - laser.bottomY) < 1e-5)
    }

    @Test func theCoreNeverChangesWidthOrPlaceWhileArmed() throws {
        let laser = laser(x: 0.7)
        for step in 0...60 {
            let t = Double(step) * 0.05
            laser.present(.active(elapsed: t), ambientTime: t * 1.3)
            let span = try #require(laser.litSpan)
            #expect(abs(span.lowerBound - laser.bottomY) < 1e-5 && abs(span.upperBound - laser.topY) < 1e-5)
            #expect(abs(laser.drawnCoreWidth - VerticalLaser.coreWidth) < 1e-6)
            #expect(laser.root.position.x == 0.7)
            #expect(!laser.showsTrace)
            // Only the landing bloom spreads the glow past its resting reach, briefly.
            if t >= VerticalLaser.impactDuration { #expect(abs(laser.lateralDecorationReach - VerticalLaser.glowReach) < 1e-5) }
        }
    }

    @Test func itPullsBackIntoTheEmitterAndPowersDownWithoutAPop() throws {
        let laser = laser()
        var lastBottom = laser.bottomY
        for step in 0...10 {
            let e = Double(step) / 10 * VerticalLaser.powerDownDuration * 0.99
            laser.present(.powerDown(elapsed: e))
            let span = try #require(laser.litSpan)
            #expect(span.lowerBound >= lastBottom - 1e-5 && abs(span.upperBound - laser.topY) < 1e-5)
            lastBottom = span.lowerBound
        }
        laser.present(.powerDown(elapsed: VerticalLaser.powerDownDuration))
        #expect(laser.litSpan == nil && !laser.isEnergized && !laser.showsTrace)
        laser.present(.off)
        #expect(laser.litSpan == nil && !laser.isEnergized && !laser.showsTrace)
    }

    @Test func aFrameDependsOnlyOnItsInputsSoItCanBeScrubbed() {
        let moments: [VerticalLaser.Phase] = [.inactive, .warning(progress: 0.3), .warning(progress: 0.55), .warning(progress: 0.8),
                                              .active(elapsed: 0.1), .active(elapsed: 2), .powerDown(elapsed: 0.12), .off]
        let scrubbed = laser()
        for moment in moments {
            let fresh = laser()
            fresh.present(moment, ambientTime: 4.2)
            // Reached after other moments, in any order, it draws the same frame.
            for other in moments.reversed() { scrubbed.present(other, ambientTime: 1.7) }
            scrubbed.present(moment, ambientTime: 4.2)
            #expect(frame(scrubbed) == frame(fresh))
        }
    }

    @Test("Its beam faces the camera wherever it stands across the corridor", arguments: [Float(-2), -0.7, 0, 0.7])
    func itsBeamFacesTheCamera(x: Float) {
        let laser = laser(x: x, z: -8)
        let expected = atan2(layout.cameraPosition.x - x, layout.cameraPosition.z + 8)
        #expect(abs(laser.facingAngle - expected) < 1e-4)
        #expect(laser.root.position == [x, 0, -8])
    }

    @Test func pastThePlayersItResolvesLikeAHorizontalGate() {
        let laser = laser(z: LaserHazard.resolveEnd + 0.01)
        #expect(laser.opacity < 1e-4)
        laser.setPlacement(x: 0, worldZ: 0)
        #expect(laser.opacity == 1)
    }
}
