//
//  LaserHazard.swift
//  Sedactive
//

import RealityKit
import UIKit

/// One visible laser: the Option 1 gate artwork (or the code-built fallback)
/// spanning `span`, with its solid core exactly on `band`, at a world depth.
///
/// The scene's shared laser spans the whole corridor (previews). Gameplay uses
/// lane-local hazards, one per judged target, so each player sees the band
/// their own target is judged against. Rendering only: it never decides a
/// band, a time or a verdict (TEAM_ALIGNMENT §B, §C).
@MainActor
final class LaserHazard {
    let root = Entity()
    private(set) var gate: LaserGate?
    /// Last state requested, kept for the code fallback (which has no states) and for tests.
    private(set) var state: LaserGate.VisualState?
    private(set) var span: ClosedRange<Float>
    /// Judged band, in game units above the floor.
    private(set) var band: ClosedRange<Float>
    private(set) var emittersShown: (left: Bool, right: Bool) = (true, true)
    var mapping: GameWorldMapping {
        didSet { applyGeometry() }
    }
    private let fallbackThickness: Float
    private var fallbackBeam: [Entity] = []
    private var fallbackEmitters: [Entity] = []

    init(name: String, span: ClosedRange<Float>, band: ClosedRange<Float>, mapping: GameWorldMapping,
         fallbackThickness: Float) {
        self.span = span
        self.band = band
        self.mapping = mapping
        self.fallbackThickness = fallbackThickness
        root.name = name
        buildFallback()
        applyGeometry()
    }

    var worldZ: Float { root.position.z }

    /// Replaces the fallback with the gate artwork. Returns the gate, or `nil`
    /// (keeping the fallback) when the artwork lacks a named part.
    @discardableResult
    func install(artwork: Entity) -> LaserGate? {
        guard gate == nil, let gate = LaserGate(artwork: artwork) else { return nil }
        for part in fallbackBeam + fallbackEmitters {
            part.removeFromParent()
        }
        fallbackBeam = []
        fallbackEmitters = []
        self.gate = gate
        root.addChild(gate.root)
        if let state { gate.setState(state) } else { gate.setState(.active) }
        applyGeometry()
        return gate
    }

    func setSpan(_ span: ClosedRange<Float>) {
        self.span = span
        applyGeometry()
    }

    /// Shows or hides each end's emitter; a lane-local half hides its inner one.
    func setEmitters(left: Bool, right: Bool) {
        emittersShown = (left, right)
        applyGeometry()
    }

    func setBand(lowerEdge: Float, upperEdge: Float) {
        band = lowerEdge...max(upperEdge, lowerEdge)
        setDepth(root.position.z)
        applyGeometry()
    }

    func setDepth(_ worldZ: Float) {
        root.position = mapping.laserPosition(heightAboveFloor: (band.lowerBound + band.upperBound) / 2, worldZ: worldZ)
    }

    func setState(_ newState: LaserGate.VisualState) {
        state = newState
        gate?.setState(newState)
    }

    func setWarningProgress(_ progress: Float) {
        gate?.setWarningProgress(progress)
    }

    private func applyGeometry() {
        let bandHeight = (band.upperBound - band.lowerBound) * mapping.metersPerGameUnit
        if let gate {
            gate.setSpan(leftX: span.lowerBound, rightX: span.upperBound)
            gate.setBandHeight(bandHeight)
            gate.setEmittersVisible(left: emittersShown.left, right: emittersShown.right)
            return
        }
        for part in fallbackBeam {
            part.position.x = (span.lowerBound + span.upperBound) / 2
            part.scale = [span.upperBound - span.lowerBound, bandHeight / fallbackThickness, 1]
        }
        for (emitter, (x, shown)) in zip(fallbackEmitters, [(span.lowerBound, emittersShown.left), (span.upperBound, emittersShown.right)]) {
            emitter.position.x = x
            emitter.isEnabled = shown
        }
    }

    /// A unit-wide core and glow scaled to the span and band, plus two emitter blocks.
    private func buildFallback() {
        let red = UIColor(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)
        let thickness = fallbackThickness
        var coreMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        coreMaterial.color = .init(tint: red)
        let core = ModelEntity(mesh: .generateBox(size: [1, thickness, thickness]), materials: [coreMaterial])
        core.name = "\(root.name).core"
        var glowMaterial = coreMaterial
        glowMaterial.blending = .transparent(opacity: 0.18)
        let glow = ModelEntity(mesh: .generateBox(size: [1, thickness * 4, thickness * 2]), materials: [glowMaterial])
        glow.name = "\(root.name).glow"
        root.addChild(core)
        root.addChild(glow)
        fallbackBeam = [core, glow]
        var emitterMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        emitterMaterial.color = .init(tint: UIColor(red: 0x2B / 255, green: 0x27 / 255, blue: 0x66 / 255, alpha: 1))
        for _ in 0..<2 {
            let emitter = ModelEntity(mesh: .generateBox(size: [0.08, 0.08, 0.08]), materials: [emitterMaterial])
            root.addChild(emitter)
            fallbackEmitters.append(emitter)
        }
    }
}
