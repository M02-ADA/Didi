import CoreGraphics
import Foundation
import RealityKit
import Testing
@testable import Sedactive

@MainActor struct DiamondHUDFlightTests {
    private let generation = UUID()
    private let viewport = CGRect(x: 10, y: 20, width: 800, height: 600)
    private let score = CGRect(x: 40, y: 45, width: 20, height: 20)
    private func model() -> DiamondHUDFlightModel {
        let m = DiamondHUDFlightModel()
        m.geometry(.init(viewport: viewport, score: score))
        m.session(generation, running: true)
        return m
    }
    private func collect(_ m: DiamondHUDFlightModel, _ target: DiamondHUDFlightModel.Target = .bonus(1)) {
        m.collect(target, generation: generation, world: [1,2,3], reduceMotion: false) { _ in CGPoint(x: 300, y: 400) }
    }
    @Test func nativeProjectionInputAndActualLayoutAnchorArePreserved() throws {
        let m = model()
        m.collect(.bonus(1), generation: generation, world: [3,4,5], reduceMotion: false) { world in
            #expect(world == [3,4,5])
            return CGPoint(x: 300, y: 400)
        }
        let flight = try #require(m.flights.first)
        #expect(flight.start == CGPoint(x: 300, y: 400))
        #expect(flight.end == CGPoint(x: score.midX, y: score.midY))
        #expect(DiamondHUDFlightModel.point(from: flight.start, to: flight.end, progress: 0) == flight.start)
        #expect(DiamondHUDFlightModel.point(from: flight.start, to: flight.end, progress: 1) == flight.end)
    }
    @Test func duplicateAndIndependentNormalBonusTargets() {
        let m = model(); let normal = UUID()
        collect(m, .normal(normal)); collect(m, .normal(normal)); collect(m, .bonus(1)); collect(m, .bonus(2))
        #expect(m.flights.count == 3 && m.started == 3)
        #expect(Set(m.flights.map(\.id)).count == 3)
    }
    @Test func arrivalDoesNotReplayAndReplacementHasNewIdentity() throws {
        let m = model(); collect(m)
        let first = try #require(m.flights.first)
        m.arrived(first); m.arrived(first); collect(m)
        #expect(m.flights.isEmpty && m.arrivals == 1)
        collect(m, .bonus(2)); #expect(m.flights.count == 1 && m.started == 2)
    }
    @Test func stopPauseAndOldGenerationCompletionCannotResurrect() throws {
        let m = model(); collect(m); let first = try #require(m.flights.first)
        m.clear(); m.arrived(first); collect(m, .bonus(2)); #expect(m.flights.isEmpty)
        m.session(UUID(), running: true); m.arrived(first); collect(m)
        #expect(m.flights.isEmpty && m.arrivals == 0)
    }
    @Test func resizeCancelsAndRequiresNewFreshPlacement() {
        let m = model(); collect(m)
        m.geometry(.init(viewport: CGRect(x: 0, y: 0, width: 600, height: 800), score: score))
        #expect(m.flights.isEmpty)
        collect(m, .bonus(2)); #expect(m.flights.count == 1)
    }
    @Test func missingOrOffscreenGeometrySkipsCosmeticOnly() {
        let m = model()
        m.collect(.bonus(1), generation: generation, world: [0,0,0], reduceMotion: false) { _ in nil }
        m.collect(.bonus(2), generation: generation, world: [0,0,0], reduceMotion: false) { _ in CGPoint(x: -1,y: -1) }
        m.geometry(.init(viewport: viewport, score: nil)); collect(m,.bonus(3))
        #expect(m.started == 0 && m.flights.isEmpty)
    }
    @Test func reduceMotionHighlightsWithoutFlyingOrProjection() {
        let m = model()
        m.collect(.bonus(1), generation: generation, world: [0,0,0], reduceMotion: true) { _ in
            Issue.record("Reduce Motion must not need a moving token projection"); return nil
        }
        #expect(m.flights.isEmpty && m.arrivals == 1 && m.arrivalSerial == 1)
    }
    @Test func rapidCosmeticWorkIsBounded() {
        let m = model(); for id in 0..<1000 { collect(m, .bonus(id)) }
        #expect(m.flights.count == 16)
        m.clear(); #expect(m.flights.isEmpty)
    }
    @Test func actualBonusPresenterEmitsOnceWithOriginalTargetAndVisualPosition() async throws {
        let scene = LaserScene(); scene.installDiamondArt(try #require(await LaserScene.loadDiamondArtwork()))
        let view = DiamondTimePresentation(scene: scene)
        var collected = false; var received: [(Int,SIMD3<Float>)] = []
        view.source = { _ in [DiamondTimeDiamond(id: 7,lane:.player1,offsetX:0.2,heightAboveFloor:1,collected:collected)] }
        view.onCollected = { received.append(($0,$1)) }
        func state(_ t: Double) -> LaserGameState {
            LaserGameState(sessionGeneration:generation,phase:.diamondTime,gameTime:t,activityProgress:300,
                           teamHealth:5,teamScore:collected ? 25:0,encounters:[])
        }
        view.update(state:state(0),diamondTimeStartedAt:0)
        collected = true
        view.update(state:state(0.1),diamondTimeStartedAt:0)
        view.update(state:state(0.2),diamondTimeStartedAt:0)
        #expect(received.count == 1 && received.first?.0 == 7)
        #expect(abs((received.first?.1.y ?? 0) - 1) < 0.001)
        view.clear()
    }
}
