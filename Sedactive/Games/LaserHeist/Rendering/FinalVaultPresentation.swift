//
//  FinalVaultPresentation.swift
//  Sedactive
//

import Metal
import RealityKit
import UIKit

/// Theo's Ending Vault art (`03 Game/02 Ending Vault`), imported at 2048 px wide
/// into `Assets.xcassets/LaserHeistVault`: Asset 42 (the closed vault wall),
/// Asset 43 (the same wall with its round door swung open; the doorway is
/// transparent) and Inside Vault (the room). 42 and 43 share one pixel scale and
/// are both centred on the frame, so placed at the same scale they line up.
/// The door's moving parts are cut out of them (`FinalVaultDoorArt`).
struct FinalVaultArt {
    let closed: TextureResource
    let inside: TextureResource
    let door: FinalVaultDoorArt

    /// Asset 42, width over height (6636 × 3476 source).
    static let closedAspect: Float = 6636.0 / 3476.0
    /// Asset 43 is wider than 42 at the same scale (6787 source pixels against 6636).
    static let openWidthShare: Float = 6787.0 / 6636.0
    /// The doorway in Asset 43, measured on its alpha: centred across, its centre
    /// 50.98 % down from the top, radius 829 px, as a share of 42's width.
    static let doorwayCenterFromTop: Float = 1772.0 / 3476.0
    static let doorwayRadiusShare: Float = 829.0 / 6636.0
    /// Inside Vault, width over height (5045 × 3483 source).
    static let insideAspect: Float = 5045.0 / 3483.0

    private static var loading: Task<FinalVaultArt?, Never>?

    /// Loads the textures once per app run; `nil` if any is missing (the round then
    /// enters Diamond Time in the corridor, as before).
    static func load() async -> FinalVaultArt? {
        let task = loading ?? Task { @MainActor in
            guard let closedImage = image("final-vault-closed"), let openImage = image("final-vault-open"),
                  let insideImage = image("final-vault-inside") else {
                print("FinalVaultArt: Ending Vault art missing, the final vault is not shown")
                return nil
            }
            async let closed = texture(closedImage, "final-vault-closed")
            async let inside = texture(insideImage, "final-vault-inside")
            async let door = FinalVaultDoorArt.load(closed: closedImage, open: openImage)
            guard let closed = await closed, let inside = await inside, let door = await door else {
                print("FinalVaultArt: Ending Vault textures could not be made, the final vault is not shown")
                return nil
            }
            return FinalVaultArt(closed: closed, inside: inside, door: door)
        }
        loading = task
        let art = await task.value
        if art == nil { loading = nil }
        return art
    }

    private static func image(_ name: String) -> CGImage? {
        UIImage(named: "LaserHeistVault/\(name)")?.cgImage
    }

    private static func texture(_ image: CGImage, _ name: String) async -> TextureResource? {
        try? await TextureResource(image: image, withName: "finalVault.\(name)", options: .init(semantic: .color))
    }
}

/// The final vault (Kevin): the destination at the end of the corridor after the
/// fifth Dual Key Vault, the scripted entry into it and the room inside, where
/// Diamond Time is played (Sketch Hi-Fi Revisi 6 NOV, Home Copy 31 → 34 → 33 → 32).
///
/// It presents `LaserFinalVaultTimeline` at the elapsed time it is given (the live
/// session's `finalVaultEntry`, which only advances while the round runs and while
/// `GameClock` is held), and keeps no clock. Gameplay never reads any of it: the
/// mascots' jumps are scripted, not detected, and Diamond Time's diamonds stay where
/// the world mapping puts them, in the players' lanes, in the room as in the corridor.
@MainActor
final class FinalVaultPresentation {
    enum Stage: Equatable {
        /// Before Diamond Time: nothing shown, the corridor as usual.
        case hidden
        /// The scripted entry at `elapsed` seconds of its timeline.
        case entry(LaserFinalVaultTimeline, elapsed: Double)
        /// Inside the vault room (Diamond Time and after). Without a timeline (replay),
        /// every mascot is shown inside.
        case inside(LaserFinalVaultTimeline?)
    }

    /// Temporary tuning values (Kevin, 12 November 2026), not approved constants.
    /// Where the vault wall stops: 4.3 m from the camera, about 80 % of the screen
    /// width (Home Copy 31), with room for the mascots' jump in front of it.
    static let stopZ: Float = -1.2
    /// How far the vault comes up the corridor (it starts in the corridor's haze).
    static let approachDistance: Float = 11
    /// How far beyond the wall the camera's push through the doorway ends, inside the room.
    static let pushEndBeyondWall: Float = 0.35
    /// The room's backdrop distance from the camera once inside, behind the mascots.
    static let insideDistance: Float = 8
    /// The height (world y) of the room's floor as the sleeve carries it: just under the game
    /// floor the mascots stand on, so the painted floor keeps its place under their feet while
    /// the camera moves.
    static let roomFloorY: Float = -0.05
    /// The backdrop is a little larger than the screen, so no edge shows.
    static let backdropOverscan: Float = 1.04
    /// The sleeve samples the room art no nearer its edge than this (texture coordinates).
    static let artEdge: Float = 0.012

    private(set) var stage: Stage = .hidden
    private let scene: LaserScene
    private let wall = Entity()
    /// Asset 42 whole, while the vault comes up the corridor (in its haze).
    private var closed: ModelEntity?
    /// From the unlock: the door as a mechanism (frame, hinged door, wheel, bolt) …
    private var mechanism: FinalVaultDoorRig?
    /// … over the jamb: Asset 43's empty doorway and the bolt's seat.
    private var jamb: ModelEntity?
    private var backdrop: ModelEntity?
    /// The room's sleeve, between its camera and the backdrop (see `placeSleeve`).
    private var sleeve: ModelEntity?
    private var sleeveBuilt = false
    private let wallWidth: Float
    private let wallHeight: Float
    /// The wall's centre height: the corridor's centre.
    private let wallY: Float
    /// Mascots this presentation moves; their moves are cleared when it hides.
    private var moved: Set<PlayerID> = []
    /// Each jumper's root (lane-local) at take-off: the cinematic is held there against live
    /// tracking, then blended back to the live root while they settle inside.
    private var anchors: [PlayerID: SIMD3<Float>] = [:]

    // MARK: Continuous entry (13 November 2026: the mascots used to vanish in the doorway and
    // drop in from 1.3 m above in the room). The mascots land `pushDistance` BEYOND their places,
    // inside the vault; the push is the camera itself moving that far forward, through the doorway
    // (14 November 2026). At its end the camera stands to them exactly as in gameplay, and the room
    // (camera, mascots, backdrop) is moved back by the same distance in one frame: nothing on
    // screen changes. One jump, one landing, one camera move.
    //
    // 14 November 2026: the push used to move the WALL toward a still camera while the room behind
    // the doorway was a backdrop locked to the screen and the corridor stood still. The doorway grew
    // tenfold around a room that never grew (a dolly zoom: the inside seemed to fall away), and the
    // still corridor said the wall was moving, not the viewer. Now the wall, the corridor and the
    // room stand still in the world and the camera moves; everything grows by its own distance.

    /// From the doorway to touchdown on the vault floor, continuing the jump's own velocity.
    static let continueDuration = 0.55
    /// The touchdown squash and its recovery.
    static let touchdownSquash: Float = 0.16
    static let touchdownRecovery = 0.22
    /// The jump's sideways aim at the doorway, as a share of the way from the lane to the centre:
    /// through the doorway a little to its own side, arriving with no sideways speed.
    static let doorwayAim: Float = 0.75
    /// Vertical speed at touchdown (m/s): still falling, as a jump ends.
    static let touchdownSpeed: Float = 1.2

    /// How far the camera moves forward in the push: from its gameplay pose, through the doorway,
    /// to `pushEndBeyondWall` inside the room.
    var pushDistance: Float { scene.layout.cameraPosition.z - Self.stopZ + Self.pushEndBeyondWall }

    /// The camera's push at `t`: 0 before it, 1 at the end of the entry. It leaves with the last
    /// jumper (`push`) and comes to rest as the mascots settle (`land`), when Diamond Time starts:
    /// an ease in and out over both, so it leaves and lands without a jolt. The doorway fills the
    /// screen about two thirds of the way in, and the camera passes the wall plane soon after.
    static func pushProgress(at t: Double, timeline: LaserFinalVaultTimeline) -> Float {
        let start = timeline.push.lowerBound, end = timeline.total
        return smooth(Float((t - start) / (end - start)))
    }

    /// The camera's offset from its gameplay pose at `t` (straight ahead, keeping its aim).
    func cameraDolly(at t: Double, timeline: LaserFinalVaultTimeline) -> SIMD3<Float> {
        [0, 0, -pushDistance * Self.pushProgress(at: t, timeline: timeline)]
    }

    /// The camera the room is laid out for during the entry: where the push ends. Inside, the room
    /// is laid out for the gameplay camera (the same room, `pushDistance` nearer).
    private var roomEye: SIMD3<Float> {
        guard case .entry(let timeline, let elapsed) = stage, elapsed < timeline.total else { return scene.layout.cameraPosition }
        return scene.layout.cameraPosition + [0, 0, -pushDistance]
    }

    init(scene: LaserScene) {
        self.scene = scene
        let layout = scene.layout
        wallWidth = layout.corridorWidth
        wallHeight = layout.corridorWidth / FinalVaultArt.closedAspect
        wallY = layout.corridorFloorY + layout.corridorHeight / 2
        wall.name = "finalVault.wall"
        wall.isEnabled = false
        guard let art = scene.finalVaultArt else { return }
        let closed = Self.plane(art.closed, width: wallWidth, height: wallHeight, blended: true)
        closed.name = "finalVault.closed"
        closed.position.z = 0.005
        let jamb = Self.plane(art.door.jamb, width: wallWidth * FinalVaultArt.openWidthShare, height: wallHeight, blended: true)
        jamb.name = "finalVault.open"
        jamb.position.z = FinalVaultDoorRig.jambZ
        jamb.isEnabled = false
        let mechanism = FinalVaultDoorRig(art: art.door, closed: art.closed, width: wallWidth, height: wallHeight)
        mechanism.root.isEnabled = false
        wall.addChild(jamb)
        wall.addChild(mechanism.root)
        wall.addChild(closed)
        let backdrop = Self.plane(art.inside, width: FinalVaultArt.insideAspect, height: 1, blended: false)
        backdrop.name = "finalVault.inside"
        backdrop.isEnabled = false
        var sleeveMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        // Clamped: parts of the sleeve the room's camera does not see (only seen on the way in)
        // carry on the art's own edge (its floor, ceiling and walls) instead of repeating it.
        let sampler = MTLSamplerDescriptor()
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.maxAnisotropy = 8
        sleeveMaterial.color = .init(tint: .white, texture: .init(art.inside, sampler: .init(sampler)))
        sleeveMaterial.faceCulling = .none
        let sleeve = ModelEntity(mesh: .generatePlane(width: 0.01, height: 0.01), materials: [sleeveMaterial])
        sleeve.name = "finalVault.sleeve"
        sleeve.isEnabled = false
        scene.root.addChild(wall)
        scene.root.addChild(backdrop)
        scene.root.addChild(sleeve)
        self.sleeve = sleeve
        self.closed = closed
        self.jamb = jamb
        self.mechanism = mechanism
        self.backdrop = backdrop
    }

    /// Whether the Ending Vault art is loaded (without it only the mascots' moves and the
    /// diamonds' hold apply).
    var hasArt: Bool { backdrop != nil }

    /// The doorway's centre height for the wall at its usual height.
    var doorwayY: Float { wallY + (0.5 - FinalVaultArt.doorwayCenterFromTop) * wallHeight }
    var doorwayRadius: Float { FinalVaultArt.doorwayRadiusShare * wallWidth }

    /// Shows `stage`. Returns the cosmetic corridor travel of the approach (metres),
    /// which the caller adds to the corridor and checkpoint door so they move with the vault.
    @discardableResult
    func update(_ stage: Stage) -> Float {
        self.stage = stage
        // Floor walking from when they settle inside (the landing's blend back to live), so the
        // feet are planted on the floor before Diamond Time starts, not re-planted at its start.
        let inside: Bool = switch stage {
        case .inside: true
        case .entry(let timeline, let elapsed): elapsed >= timeline.land.lowerBound
        case .hidden: false
        }
        scene.robotAvatars?.setVaultWalking(inside)
        switch stage {
        case .hidden:
            hide()
            return 0
        case .entry(let timeline, let elapsed):
            return present(timeline, at: max(0, elapsed))
        case .inside(let timeline):
            showInside()
            var moves: [PlayerID: RobotAvatarLayer.ScriptedMove] = [:]
            for player in timeline?.jumpers ?? PlayerID.allCases { moves[player] = .init(boardOpacity: 0) }
            setMoves(moves)
            return Self.approachDistance
        }
    }

    /// Hides the vault and returns the corridor and the mascots to normal.
    func stop() { update(.hidden) }

    /// `stop`, then takes the vault's entities out of the scene (the presenter is done).
    func remove() {
        stop()
        wall.removeFromParent()
        backdrop?.removeFromParent()
        sleeve?.removeFromParent()
    }

    // MARK: - The entry

    private func present(_ timeline: LaserFinalVaultTimeline, at t: Double) -> Float {
        let travelled = Self.approachTravel(at: t, speed: scene.layout.travelSpeed)
        if t >= timeline.total {
            // The push has ended: the same picture as inside (camera and room moved back together).
            showInside()
        } else {
            scene.setCorridorShown(true)
            wall.isEnabled = hasArt
            scene.setCameraDolly(cameraDolly(at: t, timeline: timeline))
            placeWall(at: t, timeline: timeline, travelled: travelled)
        }
        setMoves(Dictionary(uniqueKeysWithValues: timeline.jumpers.map { ($0, move($0, timeline: timeline, at: t)) }))
        return travelled
    }

    /// Distance the vault has come up the corridor: from the team's travel speed (the pace
    /// the corridor resumes at after a vault) to a stop, over the approach.
    static func approachTravel(at t: Double, speed: Float) -> Float {
        let range = LaserFinalVaultTimeline.approach
        let duration = Float(range.upperBound - range.lowerBound)
        let u = Float(min(1, max(0, (t - range.lowerBound) / (range.upperBound - range.lowerBound))))
        // Cubic Hermite: starts at `speed`, ends at rest, covers `approachDistance`.
        let h01 = u * u * (3 - 2 * u), h10 = u * u * u - 2 * u * u + u
        return approachDistance * h01 + duration * speed * h10
    }

    /// The wall comes up the corridor with it (the approach) and then stands still at its stop: the
    /// push moves the camera, never the wall.
    private func placeWall(at t: Double, timeline: LaserFinalVaultTimeline, travelled: Float) {
        guard let closed, let jamb, let backdrop else { return }
        let z = Self.stopZ - Self.approachDistance + travelled
        wall.position = [0, wallY, z]
        // The same haze as the checkpoint door while the vault is far down the corridor.
        let haze = CorridorDepth.haze(atDistance: scene.cameraWorldPosition.z - z) * LaserScene.vaultHazeShare
        if haze < 0.001 { wall.components.remove(OpacityComponent.self) }
        else { wall.components.set(OpacityComponent(opacity: 1 - haze)) }

        // From the unlock (the vault at rest, out of the haze) the door is its mechanism: it looks
        // exactly like Asset 42 until its parts move. The wheel turns, the bolt slides home, the
        // door sinks and swings in on its hinges; the frame around it never moves.
        let mechanized = t >= FinalVaultDoorMotion.start
        closed.isEnabled = !mechanized
        jamb.isEnabled = mechanized
        mechanism?.root.isEnabled = mechanized
        if mechanized { mechanism?.pose(FinalVaultDoorMotion.at(t)) }
        // The room is there behind the door from the unlock's end (the door still covers it),
        // standing still in the world where the push ends.
        backdrop.isEnabled = t >= LaserFinalVaultTimeline.open.lowerBound
        if backdrop.isEnabled { placeRoom() } else { sleeve?.isEnabled = false }
    }

    /// One mascot's scripted move at `t` (the mascots already face the vault, as in Home Copy 31),
    /// one continuous movement: a crouch; the arc through the doorway (smaller with distance; the
    /// board stays in the corridor and fades); the same jump carried on beyond the doorway to a
    /// landing on the vault floor `pushDistance` past their places; carried forward with the push
    /// onto their places; then a blend back to the live root.
    private func move(_ player: PlayerID, timeline: LaserFinalVaultTimeline, at t: Double) -> RobotAvatarLayer.ScriptedMove {
        guard let jump = timeline.jump(of: player) else { return .none }
        var move = RobotAvatarLayer.ScriptedMove()
        let tau = t - jump.lowerBound
        guard tau >= 0 else { anchors[player] = nil; return move }
        let anchor = anchors[player] ?? {
            let live = scene.robotAvatars?.trackedRootPosition(player) ?? .zero
            let held = SIMD3<Float>(live.x, 0, live.z)
            anchors[player] = held
            return held
        }()
        move.anchor = anchor
        // Back to the live root while they settle inside, before Diamond Time.
        let land = timeline.land
        move.anchorWeight = 1 - Self.smooth(Float((t - land.lowerBound) / (land.upperBound - land.lowerBound)))
        move.boardOpacity = 1 - min(1, max(0, Float(tau - 0.35) / 0.4))
        let crouch = LaserFinalVaultTimeline.anticipation
        if tau < crouch {
            move.squash = 1 - 0.2 * Self.smooth(Float(tau / crouch))
            return move
        }
        let flight = LaserFinalVaultTimeline.jumpDuration - crouch
        // The mascots stay where they land; the camera comes to them. From the end of the entry
        // the room is moved back by the push (`showInside`), with the camera.
        let push = Self.pushProgress(at: t, timeline: timeline)
        let carried = SIMD3<Float>(0, 0, t >= timeline.total ? pushDistance : 0)
        let touchdown = jump.upperBound + Self.continueDuration
        if tau < LaserFinalVaultTimeline.jumpDuration {
            let f = Float((tau - crouch) / flight)
            move.offset = jumpOffset(player, at: f) + carried
            move.scale = 1 - 0.3 * Self.smooth(f)
            move.squash = 1 + 0.12 * (1 - Self.smooth(min(1, f / 0.3)))
            return move
        }
        // The depth cheat of the flight (70 %) gives way with the push itself, never ahead of it.
        move.scale = 0.7 + 0.3 * push
        if t < touchdown {
            move.offset = continuation(player, at: Float((t - jump.upperBound) / Self.continueDuration)) + carried
            return move
        }
        move.offset = landing + carried
        let u = Float((t - touchdown) / Self.touchdownRecovery)
        if u < 1 { move.squash = 1 - Self.touchdownSquash * sin(.pi * u) }
        return move
    }

    /// Where the jump comes down (lane-local): on the mascot's own place, `pushDistance` inside
    /// the vault, where the camera's push ends at the gameplay distance from it.
    private var landing: SIMD3<Float> { [0, 0, -pushDistance] }

    /// The arc from the mascot's place to the doorway and just through it (lane-local
    /// metres): up first, then down into the opening, crossing the wall late in the flight.
    /// It starts where the mascot was at take-off (lean steering may have moved it off its lane)
    /// and aims a little inside its own side of the doorway, arriving with no sideways speed.
    func jumpOffset(_ player: PlayerID, at f: Float) -> SIMD3<Float> {
        let (x, y, z) = Self.jumpControls(laneX: laneX(player), throughZ: throughZ)
        return [Self.bezier(x.0, x.1, x.2, x.3, f), Self.bezier(y.0, y.1, y.2, y.3, f), Self.bezier(z.0, z.1, z.2, z.3, f)]
    }

    /// The jump carried on beyond the doorway (`c` 0…1 over `continueDuration`): leaves the arc
    /// with its position and velocity, lands on `landing` still falling (`touchdownSpeed`) with
    /// no sideways or forward speed, so the feet do not skate.
    func continuation(_ player: PlayerID, at c: Float) -> SIMD3<Float> {
        let (x, y, z) = Self.jumpControls(laneX: laneX(player), throughZ: throughZ)
        let start = SIMD3<Float>(x.3, y.3, z.3)
        // The arc's velocity at its end (per unit of flight), per second, over the continuation.
        let flight = Float(LaserFinalVaultTimeline.jumpDuration - LaserFinalVaultTimeline.anticipation)
        let span = Float(Self.continueDuration)
        let v0 = SIMD3<Float>(3 * (x.3 - x.2), 3 * (y.3 - y.2), 3 * (z.3 - z.2)) / flight * span
        let v1 = SIMD3<Float>(0, -Self.touchdownSpeed * span, 0)
        let k = min(1, max(0, c)), k2 = k * k, k3 = k2 * k
        return start * (2 * k3 - 3 * k2 + 1) + v0 * (k3 - 2 * k2 + k) + landing * (-2 * k3 + 3 * k2) + v1 * (k3 - k2)
    }

    private var throughZ: Float { Self.stopZ - 0.6 - scene.mapping.interactionPlaneZ }

    /// The lane's centre plus the held take-off root (lane-local origin → world X).
    private func laneX(_ player: PlayerID) -> Float {
        scene.mapping.laneCenterX[player, default: 0]
            + (anchors[player]?.x ?? scene.robotAvatars?.trackedRootX(player) ?? 0)
    }

    /// The jump's Bezier control values per axis (lane-local metres).
    private static func jumpControls(laneX: Float, throughZ: Float)
        -> (x: (Float, Float, Float, Float), y: (Float, Float, Float, Float), z: (Float, Float, Float, Float)) {
        let aim = -laneX * doorwayAim
        return ((0, -laneX * 0.15, aim, aim), (0, 1.9, 0.8, 0.35), (0, -0.1, -0.6, throughZ))
    }

    // MARK: - Inside

    /// The gameplay camera in the room: the end of the push, with the camera and the room moved
    /// back by `pushDistance` together (the same picture). The sleeve stays, so not even a texture
    /// sample changes on screen.
    private func showInside() {
        wall.isEnabled = false
        scene.setCameraDolly(.zero)
        scene.setCorridorShown(false)
        guard let backdrop else { return }
        backdrop.isEnabled = true
        placeRoom()
    }

    private func hide() {
        anchors = [:]
        scene.setCameraDolly(.zero)
        wall.isEnabled = false
        backdrop?.isEnabled = false
        sleeve?.isEnabled = false
        scene.setCorridorShown(true)
        setMoves([:])
    }

    private func setMoves(_ moves: [PlayerID: RobotAvatarLayer.ScriptedMove]) {
        guard let robots = scene.robotAvatars else { return }
        var all = robots.scriptedMoves
        for player in moved where moves[player] == nil { all[player] = nil }
        for (player, move) in moves { all[player] = move }
        if all != robots.scriptedMoves { robots.scriptedMoves = all }
        moved = Set(moves.keys)
    }

    /// The room: the backdrop filling the screen of a camera at `roomEye`, `insideDistance` along
    /// its line of sight, lined by the sleeve. Both are placed as one rigid piece relative to that
    /// camera, so moving the room back at the end of the push changes nothing on screen.
    private func placeRoom() {
        guard let backdrop else { return }
        let layout = scene.layout, eye = roomEye
        let forward = simd_normalize(layout.cameraTarget - layout.cameraPosition)
        let height = 2 * tan(layout.cameraVerticalFieldOfView / 2 * .pi / 180) * Self.insideDistance * Self.backdropOverscan
        backdrop.position = eye + forward * Self.insideDistance
        backdrop.orientation = simd_quatf(angle: asin(forward.y), axis: [1, 0, 0])
        backdrop.scale = [height, height, 1]
        placeSleeve(at: eye)
    }

    /// The room's sleeve (14 November 2026). The corridor runs on behind the wall, so through the
    /// doorway its floor, ceiling and walls would show between the wall and the room (a dark band
    /// under the room, a cut lamp). The sleeve lines that space, from the camera the room is laid out
    /// for to just behind the backdrop, textured with the room art exactly as the backdrop projects
    /// onto it from that camera: from there it IS the backdrop; from behind it, as the camera
    /// comes in, its floor, ceiling and walls open out in true perspective (a projected set).
    /// Its ceiling stays under the wall's top edge: the corridor above the wall must still read as
    /// the corridor. Built once, relative to its camera, and only moved.
    private func placeSleeve(at eye: SIMD3<Float>) {
        guard let sleeve, var model = sleeve.model else { return }
        sleeve.isEnabled = true
        sleeve.position = eye
        guard !sleeveBuilt else { return }
        sleeveBuilt = true
        guard let mesh = try? MeshResource.generate(from: [sleeveMesh()]) else { return }
        model.mesh = mesh
        sleeve.model = model
    }

    /// Floor, ceiling and both sides (relative to the camera they are laid out for), from just in
    /// front of it to beyond the backdrop, inset past the corridor's fixtures (runway lights,
    /// seams, ribs, beams), each vertex mapped to the room art where that camera sees the
    /// backdrop through it.
    private func sleeveMesh() -> MeshDescriptor {
        let layout = scene.layout
        let eyeY = layout.cameraPosition.y
        let near: Float = -0.02, far = -Self.insideDistance - 0.4
        let floorY = Self.roomFloorY - eyeY
        let ceilingY = min(layout.corridorHeight - 0.06, wallY + wallHeight / 2 - 0.02) - eyeY
        let side = layout.corridorWidth / 2 - 0.08, edge = layout.corridorWidth / 2 - 0.005
        let surfaces: [(SIMD2<Float>, SIMD2<Float>)] = [   // (x, y) at both ends
            ([-edge, floorY], [edge, floorY]), ([-edge, ceilingY], [edge, ceilingY]),
            ([-side, floorY], [-side, ceilingY]), ([side, floorY], [side, ceilingY]),
        ]
        // The texture is interpolated across each triangle in perspective, while the projection
        // it stands for divides by depth: the error grows with the depth change across a triangle
        // (it showed as stair-stepped seams on the floor). Rows grow geometrically, each 2.6 %
        // deeper than the last, so the error is the same small share everywhere, and the floor and
        // ceiling are cut into narrow columns.
        let rows = 128, columns = 24, first: Float = -0.3
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for (a, b) in surfaces {
            let base = UInt32(positions.count)
            for r in 0...rows {
                let z = r == 0 ? near : first * pow(far / first, Float(r - 1) / Float(rows - 1))
                for c in 0...columns {
                    let xy = a + (b - a) * Float(c) / Float(columns)
                    let point = SIMD3<Float>(xy.x, xy.y, z)
                    positions.append(point)
                    // Kept off the art's transparent border (1–6 px, wider at small mip levels):
                    // past its edge the sleeve carries the edge's floor, ceiling or wall colour.
                    // On screen from the room's camera the art spans 0.02…0.98, so nothing there moves.
                    let uv = Self.roomArtCoordinate(relative: point, layout: layout)
                    uvs.append(simd_clamp(uv, SIMD2(repeating: Self.artEdge), SIMD2(repeating: 1 - Self.artEdge)))
                }
            }
            let stride = UInt32(columns + 1)
            for r in 0..<UInt32(rows) {
                for c in 0..<UInt32(columns) {
                    let i = base + r * stride + c
                    indices += [i, i + stride, i + 1, i + 1, i + stride, i + stride + 1]
                }
            }
        }
        var descriptor = MeshDescriptor(name: "finalVault.sleeve")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return descriptor
    }

    /// Where the room's camera (`roomEye`) sees the backdrop through `point` (world), in the room
    /// art's texture coordinates. It depends on the direction only, not on the backdrop's distance.
    func roomArtCoordinate(of point: SIMD3<Float>) -> SIMD2<Float> {
        Self.roomArtCoordinate(relative: point - roomEye, layout: scene.layout)
    }

    private static func roomArtCoordinate(relative d: SIMD3<Float>, layout: LaserWorldLayout) -> SIMD2<Float> {
        let forward = simd_normalize(layout.cameraTarget - layout.cameraPosition)
        let right = SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, forward)
        let depth = max(simd_dot(d, forward), 0.01)
        let half = tan(layout.cameraVerticalFieldOfView / 2 * .pi / 180) * backdropOverscan
        return [0.5 + simd_dot(d, right) / depth / (2 * half * FinalVaultArt.insideAspect),
                0.5 + simd_dot(d, up) / depth / (2 * half)]
    }

    // MARK: - Helpers

    private static func plane(_ texture: TextureResource, width: Float, height: Float, blended: Bool) -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        if blended { material.blending = .transparent(opacity: 1.0) }
        return ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
    }

    private static func smooth(_ x: Float) -> Float {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    private static func bezier(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }
}
