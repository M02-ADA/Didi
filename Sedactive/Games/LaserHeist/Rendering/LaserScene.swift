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
    // Corridor proportions follow Asset 16's vanishing lines for this camera.
    // The authored scene uses the same values; the code fallback below is only
    // for when that scene is unavailable. It runs from `corridorNearZ` (behind
    // the camera) down to `corridorFarZ`. The corridor floor sits below the
    // game floor (y = 0, the players' feet) so the hoverboard can hover.
    var corridorWidth: Float = 6.3
    var corridorHeight: Float = 3.14
    var corridorFloorY: Float = -0.45
    var corridorNearZ: Float = 6
    var corridorFarZ: Float = -70
    var fixtureSpacing: Float = 6

    // Fixed virtual camera at roughly chest height, framed like the Hi-Fi:
    // the vanishing point sits near the screen centre and players fill the lower half.
    var cameraPosition: SIMD3<Float> = [0, 1.05, 3.1]
    var cameraTarget: SIMD3<Float> = [0, 1.0, -10]
    var cameraVerticalFieldOfView: Float = 50

    // Placeholder players: size is width x height, scale is per player.
    var player1Size: SIMD2<Float> = [0.74, 1.75]
    var player2Size: SIMD2<Float> = [0.52, 1.2]
    var player1Scale: Float = 1
    var player2Scale: Float = 1

    // One horizontal laser. Height and thickness are preview values only; the
    // judged band comes from Jevon's target geometry through `setLaserBand`.
    var laserHeightAboveFloor: Float = 1.25
    var laserSpawnZ: Float = -22
    var laserCoreThickness: Float = 0.022

    // Forward travel, in meters per second of travelling game time. The
    // corridor streams at this speed and laser gates sit still in it, so both
    // pass the players together. Presentation tuning only: a gate always
    // reaches the players at its target's crossing time, whatever this is.
    var travelSpeed: Float = 5.2

    // Temporary DUCK/JUMP cue: above the players, in front of the corridor.
    var moveCuePosition: SIMD3<Float> = [0, 2.0, 0.6]

    // World depth of the hoverboard's upper half. A low beam first overlaps
    // the board on screen about 0.75 m before the crossing, so this stays behind that.
    var hoverboardBackZ: Float = -1.0

    // Where a vault door halts in front of the players. The authored
    // `VaultDoorStop` anchor overrides this fallback.
    var vaultDoorStopZ: Float = -7.5
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
    static let vaultDoorSceneName = "VaultDoor"
    static let diamondSceneName = "Diamond"

    let root = Entity()
    private(set) var layout: LaserWorldLayout
    private(set) var mapping: GameWorldMapping
    private(set) var players: [PlayerID: PlayerCutoutEntity] = [:]
    private(set) var environmentSource: EnvironmentSource?
    private(set) var hoverboard: Hoverboard?
    /// Full-width laser for previews; gameplay uses lane-local hazards.
    private let laser: LaserHazard
    private let feedback = LaserFeedback()
    /// Corridor details that stream past; see `advanceTravel(by:)`.
    private var travel: Entity?
    private var travelLoop: Float = 12
    /// Where the corridor's travel group sits within its loop (tests and debugging).
    private(set) var travelOffset: Float = 0
    private var vaultDoor: VaultDoor?
    private var diamondArt: DiamondArt?
    private let diamonds = Entity()
    /// Unmodified gate artwork; every laser is built from its own clone.
    private var laserArtwork: Entity?
    /// Lane-local gameplay hazards created so far (see `makeLaneHazard`).
    private var laneHazards: [(player: PlayerID, hazard: LaserHazard)] = []
    /// The last shared effect presented (`presentTeamEffect`), for tests and debugging.
    private(set) var lastTeamEffect: (healthDelta: Int, scoreDelta: Int)?
    /// Live player cutouts; `nil` until `attachLiveCutouts` (pictograms show).
    private(set) var liveCutouts: LiveCutoutPresenter?
    private(set) var cutoutStore: CutoutTextureStore?
    /// Wall mount x positions, from the authored `LaserMount_*` anchors when available.
    private var laserSpan: ClosedRange<Float>

    var laserWorldZ: Float { laser.worldZ }

    convenience init() {
        self.init(layout: LaserWorldLayout(), mapping: GameWorldMapping())
    }

    init(layout: LaserWorldLayout, mapping: GameWorldMapping) {
        self.layout = layout
        self.mapping = mapping
        let mountX = layout.corridorWidth / 2 - 0.04
        laserSpan = -mountX...mountX
        let band = (layout.laserHeightAboveFloor - layout.laserCoreThickness / 2)...(layout.laserHeightAboveFloor + layout.laserCoreThickness / 2)
        laser = LaserHazard(name: "laser", span: laserSpan, band: band, mapping: mapping,
                            fallbackThickness: layout.laserCoreThickness)
        root.name = "laserWorld"
        root.addChild(makeCamera())
        addPlayers()
        root.addChild(laser.root)
        setLaserDepth(layout.laserSpawnZ)
        feedback.setCuePosition(layout.moveCuePosition)
        root.addChild(feedback.root)
        diamonds.name = "diamonds"
        root.addChild(diamonds)
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

    /// Loads the vault door artwork, or `nil` to show no door.
    static func loadVaultDoorArtwork() async -> Entity? {
        await loadContent(named: vaultDoorSceneName, fallback: "no vault door")
    }

    /// Loads the diamond artwork, or `nil` to show no diamonds.
    static func loadDiamondArtwork() async -> Entity? {
        await loadContent(named: diamondSceneName, fallback: "no diamonds")
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
            liveCutouts?.setMapping(mapping)
            travel = authored.findEntity(named: "Travel")
            environment = authored
            environmentSource = .realityComposerPro
        } else {
            environment = makeCorridor()
            environmentSource = .codeFallback
        }
        environment.name = "environment"
        root.addChild(environment)
        if let board = environment.findEntity(named: "Corridor")?.findEntity(named: "Hoverboard"),
           let hoverboard = Hoverboard(entity: board, camera: layout.cameraPosition, backDepth: layout.hoverboardBackZ) {
            self.hoverboard = hoverboard
            for (id, player) in players {
                hoverboard.setFootShadow(id, atWorldX: player.position.x)
            }
        }
    }

    /// Streams the corridor's ribs, wall art and floor seams toward the players
    /// by `distance` meters, wrapping every `TravelLoop` meters, so the
    /// hoverboard appears to travel forward.
    ///
    /// Presentation only: players, lasers and the world mapping never move.
    /// The caller derives the distance from game state, so pausing the game
    /// pauses travel; rendering keeps no clock of its own (TEAM_ALIGNMENT §C).
    /// With Reduce Motion the corridor streams at half speed.
    func advanceTravel(by distance: Float) {
        let scaled = UIAccessibility.isReduceMotionEnabled ? distance * 0.5 : distance
        setTravelOffset(travelOffset + scaled)
    }

    /// Places the corridor `distance` meters along the journey, absolutely,
    /// so gameplay can keep it in step with world-anchored laser gates (see
    /// `GameplayScenePresenter`). With Reduce Motion the corridor holds still
    /// instead: the large streaming motion is decorative, and running it at a
    /// different speed from the gates would contradict them.
    func setTravelDistance(_ distance: Float) {
        setTravelOffset(UIAccessibility.isReduceMotionEnabled ? 0 : distance)
    }

    private func setTravelOffset(_ offset: Float) {
        guard let travel, travelLoop > 0 else { return }
        travelOffset = offset.truncatingRemainder(dividingBy: travelLoop)
        if travelOffset < 0 {
            travelOffset += travelLoop
        }
        travel.position.z = travelOffset
    }

    /// Shows or hides the laser, e.g. for previews without an encounter.
    var isLaserVisible: Bool {
        get { laser.root.isEnabled }
        set { laser.root.isEnabled = newValue }
    }

    // MARK: - Gameplay presentation

    /// A new, hidden laser covering one player's lane: from their wall mount
    /// to the boundary between the lanes, with only the outer emitter shown.
    /// Built from the gate artwork when it is installed. The caller (the
    /// gameplay presenter) pools and reuses these.
    func makeLaneHazard(for player: PlayerID) -> LaserHazard {
        let hazard = LaserHazard(name: "laser.\(player.rawValue).\(laneHazards.count)", span: laneSpan(for: player),
                                 band: laser.band, mapping: mapping, fallbackThickness: layout.laserCoreThickness)
        if let laserArtwork {
            hazard.install(artwork: laserArtwork.clone(recursive: true))
        }
        hazard.setEmitters(left: player == .player1, right: player == .player2)
        hazard.root.isEnabled = false
        laneHazards.append((player, hazard))
        root.addChild(hazard.root)
        return hazard
    }

    /// One player's half of the corridor between the wall mounts. P1 is the
    /// left lane; the boundary is midway between the two lane centres.
    func laneSpan(for player: PlayerID) -> ClosedRange<Float> {
        let boundary = ((mapping.laneCenterX[.player1] ?? 0) + (mapping.laneCenterX[.player2] ?? 0)) / 2
        return player == .player1 ? laserSpan.lowerBound...boundary : boundary...laserSpan.upperBound
    }

    /// Fits a player's pictogram between `floor` and `crown` (game units),
    /// e.g. to replay body data. The player's placement and any live cutout
    /// are unaffected.
    func setPlaceholderBody(for player: PlayerID, floor: Double, crown: Double) {
        players[player]?.setPlaceholderBody(
            floorY: Float(floor) * mapping.metersPerGameUnit, crownY: Float(crown) * mapping.metersPerGameUnit)
    }

    func resetPlaceholderBodies() {
        for player in players.values { player.resetPlaceholderBody() }
    }

    /// Shows one player's verdict: a badge above their visible body (live
    /// cutout or pictogram) and, for a HIT, a spark where their lane meets
    /// `band` (game units) on the interaction plane.
    func presentOutcome(_ outcome: LaserFeedback.Outcome, for player: PlayerID, band: ClosedRange<Float>) {
        presentOutcome(outcome, for: player, bandCenter: (band.lowerBound + band.upperBound) / 2)
    }

    /// The team's shared health and score change for one encounter
    /// (`teamEffectsCommitted`). The HUD shows the totals from game state; a
    /// world effect for it is pending its art (LH-05/LH-18), so this records it.
    func presentTeamEffect(healthDelta: Int, scoreDelta: Int) {
        lastTeamEffect = (healthDelta, scoreDelta)
    }

    /// The move cue on screen, if any, and whether it is the action cue.
    var shownMoveCue: (move: LaserFeedback.Move, acting: Bool)? { feedback.shownMoveCue }

    // MARK: - Live cutouts (CP2)

    /// Shows `provider`'s player cutouts on the player surfaces (P1 left, P2
    /// right), replacing the pictograms while each player's image is current.
    /// `layout` is the CP1 player-plane layout the cutouts' placements use.
    /// `maximumDisplayAge` (host-clock seconds since capture) is the CP2
    /// display-freshness limit after which a cutout that receives no newer
    /// frame falls back to the pictogram; `nil` (the default until it is
    /// agreed with Edo) keeps the last current image. It takes effect through
    /// `refreshLiveCutouts(now:)`, which the play view calls every frame.
    /// Throws if no GPU texture path is available; the pictograms stay.
    func attachLiveCutouts(
        _ provider: any PlayerCutoutProviding, layout: PlayerPlaneLayout,
        maximumImageBytes: Int = 8 * 1024 * 1024, maximumDisplayAge: Double? = nil
    ) throws {
        detachLiveCutouts()
        if cutoutStore == nil || cutoutStore?.maximumImageBytes != maximumImageBytes {
            cutoutStore = try CutoutTextureStore(maximumImageBytes: maximumImageBytes)
        }
        guard let cutoutStore else { return }
        let presenter = LiveCutoutPresenter(
            store: cutoutStore, mapping: mapping, layout: layout,
            players: Dictionary(uniqueKeysWithValues: PlayerID.allCases.compactMap { id in
                players[id].map { (id, $0) }
            }))
        presenter.maximumDisplayAge = maximumDisplayAge
        liveCutouts = presenter
        try presenter.attach(provider)
    }

    /// Expires live cutouts older than their display-freshness limit, without
    /// waiting for another frame. Call once per rendered frame with
    /// host-clock time (`CACurrentMediaTime()`, the CP1 capture clock).
    func refreshLiveCutouts(now: Double) {
        liveCutouts?.refresh(now: now)
    }

    /// Stops showing live cutouts; both players return to their pictograms.
    /// The GPU textures are kept for a later attach.
    func detachLiveCutouts() {
        liveCutouts?.detach()
        liveCutouts = nil
    }

    // MARK: - Vault door and diamonds

    func installVaultDoor(_ artwork: Entity?) {
        guard vaultDoor == nil, let artwork, let door = VaultDoor(artwork: artwork) else { return }
        vaultDoor = door
        door.root.name = "vaultDoor"
        door.root.isEnabled = false
        root.addChild(door.root)
    }

    func installDiamondArt(_ artwork: Entity?) {
        guard diamondArt == nil, let artwork else { return }
        diamondArt = DiamondArt(artwork: artwork)
    }

    /// Places the vault door across the corridor at a world depth, or hides it
    /// with `nil`. The depth comes from the vault's timing in game state.
    func setVaultDoorDepth(_ worldZ: Float?) {
        guard let door = vaultDoor?.root else { return }
        door.isEnabled = worldZ != nil
        if let worldZ {
            door.position = [0, 0, worldZ]
        }
    }

    var vaultDoorDepth: Float? {
        guard let door = vaultDoor?.root, door.isEnabled else { return nil }
        return door.position.z
    }

    /// Presents a vault state decided elsewhere (Jevon's vault events).
    func setVaultDoorState(_ state: VaultDoor.State, animated: Bool) {
        vaultDoor?.setState(state, animated: animated)
    }

    func resetVaultDoor() {
        vaultDoor?.reset()
    }

    /// A new diamond in the world, not yet placed; the caller positions its
    /// `root` from game data through the world mapping and removes it when done.
    func makeDiamond() -> Diamond? {
        guard let diamond = diamondArt?.makeDiamond() else { return nil }
        diamonds.addChild(diamond.root)
        return diamond
    }

    /// Replaces the code-built lasers with the Option 1 gate artwork. Only one
    /// of them is ever shown per laser; missing artwork keeps the code-built one.
    func installLaserArtwork(_ artwork: Entity?) {
        guard laserArtwork == nil, let artwork, let gate = laser.install(artwork: artwork.clone(recursive: true)) else { return }
        laserArtwork = artwork
        feedback.setImpactArt(gate.makeImpactSpark)
        for (_, hazard) in laneHazards {
            hazard.install(artwork: artwork.clone(recursive: true))
        }
    }

    /// Moves the shared (preview) laser along the corridor. Rendering never
    /// decides when a laser arrives.
    func setLaserDepth(_ worldZ: Float) {
        laser.setDepth(worldZ)
    }

    /// Sets the shared laser's judged band (game units above the floor). The
    /// visible solid core spans exactly this band; the glow is decorative.
    func setLaserBand(lowerEdge: Float, upperEdge: Float) {
        laser.setBand(lowerEdge: lowerEdge, upperEdge: upperEdge)
    }

    /// Presents a state decided elsewhere; the code-built fallback has no states.
    func setLaserVisualState(_ state: LaserGate.VisualState) {
        laser.setState(state)
    }

    /// Warning build-up from 0 (warning shown) to 1 (beam goes solid), derived
    /// by the caller from the encounter's warning and cue times.
    func setLaserWarningProgress(_ progress: Float) {
        laser.setWarningProgress(progress)
    }

    /// Shows the shared move cue: a muted preview during the warning
    /// (`actionRemaining == nil`), then the action cue with the share of the cue
    /// lead left before the crossing (1 at the cue, 0 at the crossing). `nil` hides it.
    func setMoveCue(_ move: LaserFeedback.Move?, actionRemaining: Float?) {
        feedback.setMoveCue(move, actionRemaining: actionRemaining)
    }

    /// Shows a finalized verdict for one player against the shared (preview)
    /// laser: a badge above their visible body and, for a HIT, a spark where
    /// their lane meets the beam on the interaction plane.
    func presentOutcome(_ outcome: LaserFeedback.Outcome, for player: PlayerID) {
        presentOutcome(outcome, for: player, bandCenter: (laser.band.lowerBound + laser.band.upperBound) / 2)
    }

    private func presentOutcome(_ outcome: LaserFeedback.Outcome, for id: PlayerID, bandCenter: Float) {
        guard let player = players[id] else { return }
        var impact = mapping.laserPosition(heightAboveFloor: bandCenter, worldZ: mapping.interactionPlaneZ + 0.06)
        impact.x = player.position.x
        feedback.showOutcome(outcome, for: id, badgeAt: player.position + [0, player.visibleTop + 0.25, 0.08], impactAt: impact)
    }

    /// Clears the move cue and outcome feedback, e.g. when the next encounter starts.
    func clearLaserFeedback() {
        feedback.clear()
    }

    /// Reads the named placement points authored under `Root/Anchors`.
    /// Missing anchors keep their `LaserWorldLayout` defaults.
    private func applyAnchors(from authored: Entity) {
        func anchor(_ name: String) -> SIMD3<Float>? {
            authored.findEntity(named: name)?.position(relativeTo: authored)
        }
        // Authored RCP anchor names, kept for asset compatibility: "Parent" is P1's lane, "Child" P2's.
        let playerAnchors: [(PlayerID, String)] = [(.player1, "PlayerAnchor_Parent"), (.player2, "PlayerAnchor_Child")]
        for (id, name) in playerAnchors {
            guard let position = anchor(name) else { continue }
            mapping.laneCenterX[id] = position.x
            players[id]?.position = position
        }
        if let parent = anchor("PlayerAnchor_Parent") {
            mapping.interactionPlaneZ = parent.z
        }
        if let left = anchor("LaserMount_Left"), let right = anchor("LaserMount_Right") {
            laserSpan = left.x...right.x
        }
        laser.mapping = mapping
        laser.setSpan(laserSpan)
        for (player, hazard) in laneHazards {
            hazard.mapping = mapping
            hazard.setSpan(laneSpan(for: player))
        }
        if let spawn = anchor("LaserSpawnPoint") {
            layout.laserSpawnZ = spawn.z
            setLaserDepth(spawn.z)
        }
        if let loop = anchor("TravelLoop") {
            travelLoop = -loop.z
        }
        if let stop = anchor("VaultDoorStop") {
            layout.vaultDoorStopZ = stop.z
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
        let floorY = layout.corridorFloorY
        let height = layout.corridorHeight - floorY
        let middleY = (layout.corridorHeight + floorY) / 2
        let length = layout.corridorNearZ - layout.corridorFarZ
        let centerZ = (layout.corridorNearZ + layout.corridorFarZ) / 2

        let floor = ModelEntity(mesh: .generatePlane(width: width, depth: length), materials: [unlit(0x342239)])
        floor.position = [0, floorY, centerZ]

        let ceiling = ModelEntity(mesh: .generatePlane(width: width, depth: length), materials: [unlit(0x17142B)])
        ceiling.position = [0, layout.corridorHeight, centerZ]
        ceiling.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])

        let leftWall = ModelEntity(mesh: .generatePlane(width: length, height: height), materials: [unlit(0x1C193F)])
        leftWall.position = [-width / 2, middleY, centerZ]
        leftWall.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])

        let rightWall = ModelEntity(mesh: .generatePlane(width: length, height: height), materials: [unlit(0x1C193F)])
        rightWall.position = [width / 2, middleY, centerZ]
        rightWall.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])

        let endWall = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [unlit(0x262141)])
        endWall.position = [0, middleY, layout.corridorFarZ]

        for surface in [floor, ceiling, leftWall, rightWall, endWall] {
            corridor.addChild(surface)
        }
        for z in stride(from: layout.corridorNearZ, through: layout.corridorFarZ, by: -layout.fixtureSpacing) {
            corridor.addChild(makeFixtureRing(atZ: z))
        }
        return corridor
    }

    /// One repeating fixture: wall ribs, a ceiling beam and a floor seam.
    /// Their even spacing is what makes depth readable.
    private func makeFixtureRing(atZ z: Float) -> Entity {
        let ring = Entity()
        ring.position.z = z
        let width = layout.corridorWidth
        let floorY = layout.corridorFloorY
        let height = layout.corridorHeight - floorY
        let rib = MeshResource.generateBox(size: [0.07, height, 0.07])

        let leftRib = ModelEntity(mesh: rib, materials: [unlit(0x312B5B)])
        leftRib.position = [-width / 2 + 0.035, floorY + height / 2, 0]
        let rightRib = ModelEntity(mesh: rib, materials: [unlit(0x312B5B)])
        rightRib.position = [width / 2 - 0.035, floorY + height / 2, 0]

        let seam = ModelEntity(mesh: .generateBox(size: [width * 0.55, 0.004, 0.05]), materials: [unlit(0x2D1E33)])
        seam.position.y = floorY + 0.002

        let beam = ModelEntity(mesh: .generateBox(size: [width, 0.05, 0.07]), materials: [unlit(0x312B5B)])
        beam.position.y = layout.corridorHeight - 0.025

        for part in [leftRib, rightRib, seam, beam] {
            ring.addChild(part)
        }
        return ring
    }

    private func addPlayers() {
        let placeholders: [(PlayerID, SIMD2<Float>, Float, UIColor)] = [
            (.player1, layout.player1Size, layout.player1Scale, .white),
            (.player2, layout.player2Size, layout.player2Scale, .white),
        ]
        for (id, size, scale, color) in placeholders {
            let player = PlayerCutoutEntity(player: id, size: size, color: color)
            player.position = mapping.playerPosition(id)
            player.scale = SIMD3(repeating: scale)
            players[id] = player
            root.addChild(player)
        }
    }

    /// One horizontal beam: an opaque core (the part that matches the judged
    /// band), a transparent glow, and an emitter on each wall.
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
