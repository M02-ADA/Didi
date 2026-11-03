//
//  LaserScene.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import RealityKit
import UIKit
#if canImport(RealityKitContent)
import RealityKitContent
#endif

/// Every adjustable position and size in the LaserHeist world, in meters.
/// Tune the scene here; RealityKit's camera does the perspective. When the
/// Reality Composer Pro corridor loads, its named anchors override the player
/// lanes and laser spawn depth below.
struct LaserWorldLayout {
    // Fallback corridor, used only when the authored scene is unavailable.
    // It runs from `corridorNearZ` (behind the camera) down to `corridorFarZ`.
    var corridorWidth: Float = 3.2
    var corridorHeight: Float = 2.8
    var corridorNearZ: Float = 6
    var corridorFarZ: Float = -26
    var fixtureSpacing: Float = 2

    // Fixed virtual camera at roughly chest height, framed like the Hi-Fi:
    // the vanishing point sits near the screen centre and players fill the lower half.
    var cameraPosition: SIMD3<Float> = [0, 1.05, 3.1]
    var cameraTarget: SIMD3<Float> = [0, 1.0, -10]
    var cameraVerticalFieldOfView: Float = 50

    // Placeholder players: size is width x height, scale is per player.
    var parentSize: SIMD2<Float> = [0.74, 1.75]
    var childSize: SIMD2<Float> = [0.52, 1.2]
    var parentScale: Float = 1
    var childScale: Float = 1

    // One horizontal laser. Height and thickness are preview values only; the
    // judged band comes from Jevon's target geometry through `setLaserBand`.
    var laserHeightAboveFloor: Float = 1.25
    var laserSpawnZ: Float = -22
    var laserCoreThickness: Float = 0.022

    // Temporary DUCK/JUMP cue: above the players, in front of the corridor.
    var moveCuePosition: SIMD3<Float> = [0, 2.0, 0.6]
}

/// Builds and owns the LaserHeist RealityKit world: camera, corridor, player
/// surfaces, lasers and their player feedback. It only renders; positions,
/// states, moves and verdicts come from callers, and later from Jevon's game
/// state (TEAM_ALIGNMENT §B, §C).
@MainActor
final class LaserScene {
    enum EnvironmentSource: String {
        case realityComposerPro = "Reality Composer Pro"
        case codeFallback = "code fallback"
    }

    /// Scene name inside the `RealityKitContent` package.
    static let authoredSceneName = "LaserCorridor"
    /// Group of flat player and laser stand-ins that exist only for arranging
    /// the corridor in Reality Composer Pro. The runtime builds the real ones.
    static let editorPreviewsName = "EditorPreviews"
    /// Option 1 laser gate artwork inside the `RealityKitContent` package.
    static let laserGateSceneName = "LaserGate"

    let root = Entity()
    private(set) var layout: LaserWorldLayout
    private(set) var mapping: GameWorldMapping
    private(set) var players: [GameWorldMapping.Lane: PlayerCutoutEntity] = [:]
    private(set) var environmentSource: EnvironmentSource?
    private let laser = Entity()
    private let feedback = LaserFeedback()
    private var laserEmitters: [Entity] = []
    private var fallbackBeam: [Entity] = []
    private var laserGate: LaserGate?
    /// Wall mount x positions, from the authored `LaserMount_*` anchors when available.
    private var laserSpan: ClosedRange<Float>
    /// Judged band in game units above the floor; preview values until Jevon's targets exist.
    private var laserBand: ClosedRange<Float>

    var laserWorldZ: Float { laser.position.z }

    convenience init() {
        self.init(layout: LaserWorldLayout(), mapping: GameWorldMapping())
    }

    init(layout: LaserWorldLayout, mapping: GameWorldMapping) {
        self.layout = layout
        self.mapping = mapping
        let mountX = layout.corridorWidth / 2 - 0.04
        laserSpan = -mountX...mountX
        laserBand = (layout.laserHeightAboveFloor - layout.laserCoreThickness / 2)...(layout.laserHeightAboveFloor + layout.laserCoreThickness / 2)
        root.name = "laserWorld"
        root.addChild(makeCamera())
        addPlayers()
        buildLaser()
        setLaserDepth(layout.laserSpawnZ)
        feedback.setCuePosition(layout.moveCuePosition)
        root.addChild(feedback.root)
    }

    /// Loads the corridor authored in Reality Composer Pro, or `nil` when the
    /// `RealityKitContent` package is not linked or the scene fails to load.
    static func loadAuthoredEnvironment() async -> Entity? {
        await loadContent(named: authoredSceneName, fallback: "the code corridor")
    }

    /// Loads the Option 1 laser gate artwork, or `nil` to keep the code-built laser.
    static func loadLaserGateArtwork() async -> Entity? {
        await loadContent(named: laserGateSceneName, fallback: "the code-built laser")
    }

    private static func loadContent(named name: String, fallback: String) async -> Entity? {
        #if canImport(RealityKitContent)
        do {
            return try await Entity(named: name, in: realityKitContentBundle)
        } catch {
            print("LaserScene: \(name) failed to load, using \(fallback): \(error)")
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Adds the environment once: the authored corridor when available,
    /// otherwise the code-built corridor. Only one of them is ever in the scene.
    /// Editor previews are removed unless `keepEditorPreviews` is set (debug
    /// comparison only), so the runtime never shows duplicate players or lasers.
    func installEnvironment(authored: Entity?, keepEditorPreviews: Bool = false) {
        guard environmentSource == nil else { return }
        let environment: Entity
        if let authored {
            if !keepEditorPreviews {
                authored.findEntity(named: Self.editorPreviewsName)?.removeFromParent()
            }
            applyAnchors(from: authored)
            environment = authored
            environmentSource = .realityComposerPro
        } else {
            environment = makeCorridor()
            environmentSource = .codeFallback
        }
        environment.name = "environment"
        root.addChild(environment)
    }

    /// Replaces the code-built laser with the Option 1 gate artwork. Only one of
    /// them is ever in the scene; missing artwork keeps the code-built laser.
    func installLaserArtwork(_ artwork: Entity?) {
        guard laserGate == nil, let artwork, let gate = LaserGate(artwork: artwork) else { return }
        for part in laser.children.map({ $0 }) {
            part.removeFromParent()
        }
        laserEmitters = []
        fallbackBeam = []
        laserGate = gate
        laser.addChild(gate.root)
        gate.setState(.active)
        feedback.setImpactArt(gate.makeImpactSpark)
        applyLaserGeometry()
    }

    /// Moves the laser along the corridor. A future encounter state maps its
    /// timing to this depth; rendering never decides when a laser arrives.
    func setLaserDepth(_ worldZ: Float) {
        let center = (laserBand.lowerBound + laserBand.upperBound) / 2
        laser.position = mapping.laserPosition(heightAboveFloor: center, worldZ: worldZ)
    }

    /// Sets the judged band (game units above the floor). The visible solid core
    /// spans exactly this band; the glow is decorative.
    func setLaserBand(lowerEdge: Float, upperEdge: Float) {
        laserBand = lowerEdge...upperEdge
        setLaserDepth(laser.position.z)
        applyLaserGeometry()
    }

    /// Presents a state decided elsewhere; the code-built fallback has no states.
    func setLaserVisualState(_ state: LaserGate.VisualState) {
        laserGate?.setState(state)
    }

    /// Warning build-up from 0 (warning shown) to 1 (beam goes solid), derived
    /// by the caller from the encounter's warning and cue times.
    func setLaserWarningProgress(_ progress: Float) {
        laserGate?.setWarningProgress(progress)
    }

    /// Shows the shared move cue: a muted preview during the warning
    /// (`actionRemaining == nil`), then the action cue with the share of the cue
    /// lead left before the crossing (1 at the cue, 0 at the crossing). `nil` hides it.
    func setMoveCue(_ move: LaserFeedback.Move?, actionRemaining: Float?) {
        feedback.setMoveCue(move, actionRemaining: actionRemaining)
    }

    /// Shows a finalized verdict for one player: a badge above their head and,
    /// for a HIT, a spark where their lane meets the beam on the interaction plane.
    func presentOutcome(_ outcome: LaserFeedback.Outcome, for lane: GameWorldMapping.Lane) {
        guard let player = players[lane] else { return }
        let height = (lane == .parent ? layout.parentSize.y : layout.childSize.y) * player.scale.y
        let bandCenter = (laserBand.lowerBound + laserBand.upperBound) / 2
        var impact = mapping.laserPosition(heightAboveFloor: bandCenter, worldZ: mapping.interactionPlaneZ + 0.06)
        impact.x = player.position.x
        feedback.showOutcome(outcome, for: lane, badgeAt: player.position + [0, height + 0.25, 0.08], impactAt: impact)
    }

    /// Clears the move cue and outcome feedback, e.g. when the next encounter starts.
    func clearLaserFeedback() {
        feedback.clear()
    }

    func setPlayerScale(_ lane: GameWorldMapping.Lane, _ scale: Float) {
        players[lane]?.scale = SIMD3(repeating: scale)
    }

    /// Reads the named placement points authored under `Root/Anchors`.
    /// Missing anchors keep their `LaserWorldLayout` defaults.
    private func applyAnchors(from authored: Entity) {
        func anchor(_ name: String) -> SIMD3<Float>? {
            authored.findEntity(named: name)?.position(relativeTo: authored)
        }
        let playerAnchors: [(GameWorldMapping.Lane, String)] = [(.parent, "PlayerAnchor_Parent"), (.child, "PlayerAnchor_Child")]
        for (lane, name) in playerAnchors {
            guard let position = anchor(name) else { continue }
            mapping.laneCenterX[lane] = position.x
            players[lane]?.position = position
        }
        if let parent = anchor("PlayerAnchor_Parent") {
            mapping.interactionPlaneZ = parent.z
        }
        if let spawn = anchor("LaserSpawnPoint") {
            layout.laserSpawnZ = spawn.z
            setLaserDepth(spawn.z)
        }
        if let left = anchor("LaserMount_Left"), let right = anchor("LaserMount_Right") {
            laserSpan = left.x...right.x
            applyLaserGeometry()
        }
    }

    /// Keeps the gate (or the code-built fallback) on the wall mounts and sized to the band.
    private func applyLaserGeometry() {
        let bandHeight = (laserBand.upperBound - laserBand.lowerBound) * mapping.metersPerGameUnit
        if let laserGate {
            laserGate.setSpan(leftX: laserSpan.lowerBound, rightX: laserSpan.upperBound)
            laserGate.setBandHeight(bandHeight)
            return
        }
        for (emitter, x) in zip(laserEmitters, [laserSpan.lowerBound, laserSpan.upperBound]) {
            emitter.position.x = x
        }
        for part in fallbackBeam {
            part.scale.y = bandHeight / layout.laserCoreThickness
        }
    }

    // MARK: - Building

    private func makeCamera() -> Entity {
        let camera = PerspectiveCamera()
        camera.name = "camera"
        camera.camera.fieldOfViewInDegrees = layout.cameraVerticalFieldOfView
        camera.look(at: layout.cameraTarget, from: layout.cameraPosition, relativeTo: nil)
        return camera
    }

    private func makeCorridor() -> Entity {
        let corridor = Entity()
        corridor.name = "corridor"
        let width = layout.corridorWidth
        let height = layout.corridorHeight
        let length = layout.corridorNearZ - layout.corridorFarZ
        let centerZ = (layout.corridorNearZ + layout.corridorFarZ) / 2

        let floor = ModelEntity(mesh: .generatePlane(width: width, depth: length), materials: [unlit(0x2C2236)])
        floor.position = [0, 0, centerZ]

        let ceiling = ModelEntity(mesh: .generatePlane(width: width, depth: length), materials: [unlit(0x1C1944)])
        ceiling.position = [0, height, centerZ]
        ceiling.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])

        let leftWall = ModelEntity(mesh: .generatePlane(width: length, height: height), materials: [unlit(0x221F55)])
        leftWall.position = [-width / 2, height / 2, centerZ]
        leftWall.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])

        let rightWall = ModelEntity(mesh: .generatePlane(width: length, height: height), materials: [unlit(0x221F55)])
        rightWall.position = [width / 2, height / 2, centerZ]
        rightWall.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])

        let endWall = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [unlit(0x17142F)])
        endWall.position = [0, height / 2, layout.corridorFarZ]

        for surface in [floor, ceiling, leftWall, rightWall, endWall] {
            corridor.addChild(surface)
        }
        for z in stride(from: layout.corridorNearZ, through: layout.corridorFarZ, by: -layout.fixtureSpacing) {
            corridor.addChild(makeFixtureRing(atZ: z))
        }
        return corridor
    }

    /// One repeating fixture: wall ribs, a floor seam and a ceiling light.
    /// Their even spacing is what makes depth readable.
    private func makeFixtureRing(atZ z: Float) -> Entity {
        let ring = Entity()
        ring.position.z = z
        let width = layout.corridorWidth
        let height = layout.corridorHeight
        let rib = MeshResource.generateBox(size: [0.06, height, 0.14])

        let leftRib = ModelEntity(mesh: rib, materials: [unlit(0x3A3580)])
        leftRib.position = [-width / 2 + 0.03, height / 2, 0]
        let rightRib = ModelEntity(mesh: rib, materials: [unlit(0x3A3580)])
        rightRib.position = [width / 2 - 0.03, height / 2, 0]

        let seam = ModelEntity(mesh: .generateBox(size: [width, 0.004, 0.05]), materials: [unlit(0x6C4152)])
        seam.position.y = 0.002

        let light = ModelEntity(
            mesh: .generateBox(size: [width * 0.4, 0.02, 0.35]),
            materials: [unlit(0x3A3580)]
        )
        light.position.y = height - 0.01

        for part in [leftRib, rightRib, seam, light] {
            ring.addChild(part)
        }
        return ring
    }

    private func addPlayers() {
        let placeholders: [(GameWorldMapping.Lane, SIMD2<Float>, Float, UIColor)] = [
            (.parent, layout.parentSize, layout.parentScale, .white),
            (.child, layout.childSize, layout.childScale, .white),
        ]
        for (lane, size, scale, color) in placeholders {
            let player = PlayerCutoutEntity(lane: lane, size: size, color: color)
            player.position = mapping.playerPosition(lane)
            player.scale = SIMD3(repeating: scale)
            players[lane] = player
            root.addChild(player)
        }
    }

    /// One horizontal beam: an opaque core (the part that matches the judged
    /// band), a transparent glow, and an emitter on each wall.
    private func buildLaser() {
        laser.name = "laser"
        let width = layout.corridorWidth
        let thickness = layout.laserCoreThickness
        let red = Self.color(0xE5484D)

        let core = ModelEntity(mesh: .generateBox(size: [width, thickness, thickness]), materials: [Self.flat(red)])
        core.name = "laser.core"

        var glowMaterial = Self.flat(red)
        glowMaterial.blending = .transparent(opacity: 0.18)
        let glow = ModelEntity(mesh: .generateBox(size: [width, thickness * 4, thickness * 2]), materials: [glowMaterial])
        glow.name = "laser.glow"

        laser.addChild(core)
        laser.addChild(glow)
        fallbackBeam = [core, glow]
        for _ in 0..<2 {
            let emitter = ModelEntity(mesh: .generateBox(size: [0.08, 0.08, 0.08]), materials: [unlit(0x2B2766)])
            laser.addChild(emitter)
            laserEmitters.append(emitter)
        }
        applyLaserGeometry()
        root.addChild(laser)
    }

    /// Flat colour from the Hi-Fi palette, e.g. `0x221F55`.
    private func unlit(_ hex: UInt32) -> UnlitMaterial {
        Self.flat(Self.color(hex))
    }

    /// Unlit and not tone-mapped, so palette colours render exactly as designed.
    private static func flat(_ color: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: color)
        return material
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
