import RealityKit
import Testing
@testable import Sedactive

/// LH-05 presentation lifecycle: whatever order states and verdicts arrive in,
/// only the current state's parts stay lit, and no animation moves the judged band.
/// These check the resting values each change leaves behind; they do not tick
/// RealityKit animations.
@MainActor
struct LaserGateLifecycleTests {
    /// Minimal artwork with the part names `LaserGate` looks up in the RCP scene.
    @MainActor
    private struct Artwork {
        let root = Entity()
        let beam: Entity
        let core: Entity
        let glow: Entity
        let warning: Entity
        let active: [Entity]
        let disabled: [Entity]
        let rings: [Entity]
        let sparks: [Entity]

        init() {
            func child(_ name: String, of parent: Entity, _ model: Entity? = nil) -> Entity {
                let entity = model ?? Entity()
                entity.name = name
                parent.addChild(entity)
                return entity
            }
            let gate = child("Gate", of: root)
            beam = child("Beam", of: gate)
            core = child("Core", of: beam, ModelEntity(mesh: .generatePlane(width: 3.06, height: 0.022)))
            glow = child("Glow", of: beam)
            warning = child("Warning", of: beam)
            let mounts = ["EmitterLeft", "EmitterRight"].map { child($0, of: gate) }
            active = mounts.map { child("Active", of: $0) }
            disabled = mounts.map { child("Disabled", of: $0) }
            rings = mounts.map { child("WarningRing", of: $0) }
            sparks = mounts.map { child("HitSpark", of: $0) }
        }

        /// Parts that end up visible once the current change settles.
        var lit: Set<String> {
            var names: Set<String> = []
            for (name, parts) in [("core", [core]), ("glow", [glow]), ("warning", [warning]), ("active", active),
                                  ("disabled", disabled), ("ring", rings), ("spark", sparks)] {
                if parts.allSatisfy({ $0.isEnabled && ($0.components[OpacityComponent.self]?.opacity ?? 1) > 0 }) {
                    names.insert(name)
                }
            }
            return names
        }
    }

    private static let expected: [LaserGate.VisualState: Set<String>] = [
        .inactive: ["active"],
        .warning: ["active", "warning", "ring"],
        .active: ["active", "core", "glow"],
        .hit: ["active", "core", "glow", "spark"],
        .disabled: ["disabled"],
    ]

    @Test("Every state change leaves only the new state's parts lit")
    func noStalePartsAfterAnyTransition() throws {
        let artwork = Artwork()
        let gate = try #require(LaserGate(artwork: artwork.root))
        for from in LaserGate.VisualState.allCases {
            for to in LaserGate.VisualState.allCases where to != from {
                gate.setState(from)
                gate.setState(to)
                #expect(artwork.lit == Self.expected[to], "\(from) → \(to)")
            }
        }
    }

    @Test("State animations never move the beam or change the core's band")
    func judgedBandUnchangedByStates() throws {
        let artwork = Artwork()
        let gate = try #require(LaserGate(artwork: artwork.root))
        gate.setSpan(leftX: -1.4, rightX: 1.4)
        gate.setBandHeight(0.03)
        let beam = artwork.beam.transform.matrix
        let core = artwork.core.transform.matrix
        for state in LaserGate.VisualState.allCases + LaserGate.VisualState.allCases.reversed() {
            gate.setState(state)
            gate.setWarningProgress(0.7)
            #expect(artwork.beam.transform.matrix == beam, "\(state)")
            #expect(artwork.core.transform.matrix == core, "\(state)")
        }
    }

    @Test("A repeated verdict replaces the badge, and clearing hides all feedback")
    func feedbackReplacesAndClears() throws {
        let feedback = LaserFeedback()
        feedback.setImpactArt { Entity() }
        func entity(_ name: String) throws -> Entity { try #require(feedback.root.findEntity(named: name)) }

        feedback.setMoveCue(.duck, actionRemaining: 0.5)
        feedback.showOutcome(.hit, for: .player1, badgeAt: .zero, impactAt: .zero)
        feedback.showOutcome(.clear, for: .player1, badgeAt: .zero, impactAt: .zero)
        #expect(try entity("laserFeedback.badge.player1.clear").isEnabled)
        #expect(try !entity("laserFeedback.badge.player1.hit").isEnabled)
        #expect(try !entity("laserFeedback.badge.player1.unavailable").isEnabled)

        feedback.clear()
        for player in PlayerID.allCases {
            #expect(try !entity("laserFeedback.badge.\(player.rawValue)").isEnabled)
            #expect(try !entity("laserFeedback.impact.\(player.rawValue)").isEnabled)
        }
        #expect(try entity("laserFeedback.cue").components[OpacityComponent.self]?.opacity == 0)
    }
}

/// The art's fairness rule: a miss is judged at one band edge (a DUCK clears
/// below the lower edge, a JUMP above the upper one), so light, tracers and
/// the curtain spread only to the danger side. On the safe side, nothing
/// reaches past the edge by more than the clearance-sized fringe.
@MainActor
struct LaserGateDecorationTests {
    private static func gate() throws -> LaserGate {
        let root = Entity(), gate = Entity(), beam = Entity()
        gate.name = "Gate"; beam.name = "Beam"
        root.addChild(gate); gate.addChild(beam)
        let core = ModelEntity(mesh: .generatePlane(width: 3.06, height: 0.022))
        core.name = "Core"; beam.addChild(core)
        for name in ["Glow", "Warning"] { let part = Entity(); part.name = name; beam.addChild(part) }
        for side in ["EmitterLeft", "EmitterRight"] {
            let mount = Entity(); mount.name = side; gate.addChild(mount)
            for name in ["Active", "Disabled", "WarningRing", "HitSpark"] { let part = Entity(); part.name = name; mount.addChild(part) }
        }
        return try #require(LaserGate(artwork: root))
    }

    @Test("DUCK and JUMP light never spills past the safe edge", arguments: [LaserGate.DangerSide.above, .below])
    func safeEdgeStaysCrisp(side: LaserGate.DangerSide) throws {
        let gate = try Self.gate()
        gate.setSpan(leftX: -3.08, rightX: 0)
        gate.setDangerSide(side)
        for band: Float in [0.01, 0.016, 0.05] {
            gate.setBandHeight(band)
            for state in LaserGate.VisualState.allCases {
                gate.setState(state)
                let reach = gate.decorationReach
                let safe = side == .above ? reach.below : reach.above
                let danger = side == .above ? reach.above : reach.below
                #expect(safe <= LaserGate.safeFringe + 1e-5, "\(side) \(state) band \(band): \(reach)")
                if state == .active { #expect(danger > 0.1, "the curtain marks the danger side") }
            }
        }
    }

    @Test("A JUMP's curtain stops above the corridor floor")
    func jumpCurtainStaysAboveTheFloor() throws {
        let gate = try Self.gate()
        gate.setDangerSide(.below)
        gate.setBandHeight(0.016)
        gate.setFloorDrop(0.1)
        gate.setState(.active)
        #expect(gate.decorationReach.below <= 0.1 - 0.008)
    }
}
