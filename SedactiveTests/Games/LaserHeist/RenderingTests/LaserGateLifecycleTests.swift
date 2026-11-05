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
