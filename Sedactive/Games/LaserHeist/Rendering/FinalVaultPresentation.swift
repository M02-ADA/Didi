//
//  FinalVaultPresentation.swift
//  Sedactive
//

import RealityKit
import UIKit

/// Theo's Ending Vault art (`03 Game/02 Ending Vault`), imported at 2048 px wide
/// into `Assets.xcassets/LaserHeistVault`: Asset 42 (the closed vault wall),
/// Asset 43 (the same wall with its round door swung open; the doorway is
/// transparent) and Inside Vault (the room). 42 and 43 share one pixel scale and
/// are both centred on the frame, so placed at the same scale they line up.
struct FinalVaultArt {
    let closed: TextureResource
    let open: TextureResource
    let inside: TextureResource

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

    /// Loads the three textures once per app run; `nil` if any is missing (the round then
    /// enters Diamond Time in the corridor, as before).
    static func load() async -> FinalVaultArt? {
        let task = loading ?? Task { @MainActor in
            async let closed = texture("final-vault-closed")
            async let open = texture("final-vault-open")
            async let inside = texture("final-vault-inside")
            guard let closed = await closed, let open = await open, let inside = await inside else {
                print("FinalVaultArt: Ending Vault art missing, the final vault is not shown")
                return nil
            }
            return FinalVaultArt(closed: closed, open: open, inside: inside)
        }
        loading = task
        let art = await task.value
        if art == nil { loading = nil }
        return art
    }

    private static func texture(_ name: String) async -> TextureResource? {
        guard let image = UIImage(named: "LaserHeistVault/\(name)")?.cgImage else { return nil }
        return try? await TextureResource(image: image, withName: "finalVault.\(name)", options: .init(semantic: .color))
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
    /// How far beyond the mascots' landing the room's backdrop stands while the doorway shows it.
    static let backdropMargin: Float = 0.6
    /// The wall's last place in the push through the doorway, just before the camera:
    /// the doorway then covers the whole screen.
    static let pushEndDistance: Float = 0.35
    /// The room's backdrop distance from the camera once inside, behind the mascots.
    static let insideDistance: Float = 8
    /// The backdrop is a little larger than the screen, so no edge shows.
    static let backdropOverscan: Float = 1.04

    private(set) var stage: Stage = .hidden
    private let scene: LaserScene
    private let wall = Entity()
    private var closed: ModelEntity?
    private var open: ModelEntity?
    private var backdrop: ModelEntity?
    /// The room's sleeve, between the wall and the backdrop (see `placeSleeve`).
    private var sleeve: ModelEntity?
    private var sleeveShape: SIMD3<Float>?
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
    // drop in from 1.3 m above in the room). The push moves the wall `pushDistance` toward the
    // still camera; the mascots land that far BEYOND their places, inside the vault, and move with
    // the push: at its end they stand exactly on their places. One jump, one landing.

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

    /// How far the push carries the wall (and everything inside) toward the camera.
    var pushDistance: Float { scene.layout.cameraPosition.z - Self.pushEndDistance - Self.stopZ }
    /// The push's progress at `t` (0 before it, 1 after), with the wall's own easing: it
    /// accelerates, so the wall rushes past the camera.
    static func pushProgress(at t: Double, timeline: LaserFinalVaultTimeline) -> Float {
        let p = linearPush(at: t, timeline: timeline)
        return p * p
    }

    private static func linearPush(at t: Double, timeline: LaserFinalVaultTimeline) -> Float {
        let push = timeline.push
        return Float(min(1, max(0, (t - push.lowerBound) / (push.upperBound - push.lowerBound))))
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
        let open = Self.plane(art.open, width: wallWidth * FinalVaultArt.openWidthShare, height: wallHeight, blended: true)
        open.name = "finalVault.open"
        wall.addChild(open)
        wall.addChild(closed)
        let backdrop = Self.plane(art.inside, width: FinalVaultArt.insideAspect, height: 1, blended: false)
        backdrop.name = "finalVault.inside"
        backdrop.isEnabled = false
        var sleeveMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        sleeveMaterial.color = .init(tint: .white, texture: .init(art.inside))
        sleeveMaterial.faceCulling = .none
        let sleeve = ModelEntity(mesh: .generatePlane(width: 0.01, height: 0.01), materials: [sleeveMaterial])
        sleeve.name = "finalVault.sleeve"
        sleeve.isEnabled = false
        scene.root.addChild(wall)
        scene.root.addChild(backdrop)
        scene.root.addChild(sleeve)
        self.sleeve = sleeve
        self.closed = closed
        self.open = open
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
        if t >= timeline.push.upperBound {
            showInside()
        } else {
            scene.setCorridorShown(true)
            wall.isEnabled = hasArt
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

    private func placeWall(at t: Double, timeline: LaserFinalVaultTimeline, travelled: Float) {
        guard let closed, let open, let backdrop else { return }
        var z = Self.stopZ - Self.approachDistance + travelled
        var y = wallY
        let push = timeline.push
        if t > push.lowerBound {
            let e = Self.pushProgress(at: t, timeline: timeline)
            z += pushDistance * e
            // The doorway's centre moves onto the camera's line of sight.
            y += (cameraAxisY(atZ: z) - doorwayY) * e
        }
        wall.position = [0, y, z]
        // The same haze as the checkpoint door while the vault is far down the corridor.
        let haze = CorridorDepth.haze(atDistance: scene.layout.cameraPosition.z - z) * LaserScene.vaultHazeShare
        if haze < 0.001 { wall.components.remove(OpacityComponent.self) }
        else { wall.components.set(OpacityComponent(opacity: 1 - haze)) }

        // Unlock: the closed door shakes; then it gives way to the open art.
        let unlock = LaserFinalVaultTimeline.unlock, opening = LaserFinalVaultTimeline.open
        var shake: Float = 0
        if unlock.contains(t) {
            let a = Float((t - unlock.lowerBound) / (unlock.upperBound - unlock.lowerBound))
            shake = 0.025 * sin(a * 8 * .pi) * (1 - a)
        }
        let p = Float(min(1, max(0, (t - opening.lowerBound) / (opening.upperBound - opening.lowerBound))))
        let reveal = p * p * (3 - 2 * p)
        closed.position.x = shake
        closed.scale = SIMD3(repeating: 1 + 0.04 * reveal)
        closed.isEnabled = reveal < 1
        if reveal > 0, reveal < 1 { closed.components.set(OpacityComponent(opacity: 1 - reveal)) }
        else { closed.components.remove(OpacityComponent.self) }
        open.isEnabled = t >= opening.lowerBound
        // The room shows through the doorway: a screen-sized backdrop just behind the wall.
        backdrop.isEnabled = open.isEnabled
        // Beyond where the mascots land inside (they move with the push, as the wall does).
        let gap = pushDistance - (scene.mapping.interactionPlaneZ - Self.stopZ) + Self.backdropMargin
        if backdrop.isEnabled {
            placeBackdrop(atDistance: scene.layout.cameraPosition.z - (z - gap))
            placeSleeve(near: z - 0.01, far: z - gap - 0.1, top: y + wallHeight / 2)
        } else {
            sleeve?.isEnabled = false
        }
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
        // Carried EXACTLY like the wall (same distance, same easing): everything moves with the one
        // "camera", so whatever is beyond the doorway always grows more slowly than the doorway
        // itself, as through a real forward move (14 November 2026: an independently eased carry made
        // the mascots outgrow the doorway early in the push, which read as the gate moving away).
        let push = Self.pushProgress(at: t, timeline: timeline)
        let carried = SIMD3<Float>(0, 0, pushDistance * push)
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
    /// the vault, so the push carries it exactly onto that place.
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

    private func showInside() {
        wall.isEnabled = false
        sleeve?.isEnabled = false
        scene.setCorridorShown(false)
        guard let backdrop else { return }
        backdrop.isEnabled = true
        placeBackdrop(atDistance: Self.insideDistance)
    }

    private func hide() {
        anchors = [:]
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

    /// Fills the screen with the room at `distance` along the camera's line of sight.
    private func placeBackdrop(atDistance distance: Float) {
        guard let backdrop else { return }
        let layout = scene.layout
        let forward = simd_normalize(layout.cameraTarget - layout.cameraPosition)
        let height = 2 * tan(layout.cameraVerticalFieldOfView / 2 * .pi / 180) * distance * Self.backdropOverscan
        backdrop.position = layout.cameraPosition + forward * distance
        backdrop.orientation = simd_quatf(angle: asin(forward.y), axis: [1, 0, 0])
        backdrop.scale = [height, height, 1]
    }

    /// The room's sleeve (14 November 2026). The backdrop stands behind the mascots' landing,
    /// ~3.4 m beyond the wall, so the corridor's floor, ceiling and walls between the wall and the
    /// backdrop showed through the doorway (a dark band under the room, a cut lamp). The sleeve
    /// lines the corridor there, textured with the room art exactly as the backdrop projects onto
    /// it from the still camera: on screen it IS the backdrop, as if it stood right behind the
    /// wall (HEAD's look), while the mascots still land in front of the room.
    /// Its ceiling stays under the wall's top edge (`top`): the corridor above the wall must
    /// still read as the corridor, as it does in HEAD.
    private func placeSleeve(near: Float, far: Float, top: Float) {
        guard let sleeve, var model = sleeve.model, near > far else { return }
        sleeve.isEnabled = true
        let shape = SIMD3<Float>(near, far, top)
        guard shape != sleeveShape else { return }
        sleeveShape = shape
        guard let mesh = try? MeshResource.generate(from: [sleeveMesh(near: near, far: far, top: top)]) else { return }
        model.mesh = mesh
        sleeve.model = model
    }

    /// Floor, ceiling and both sides from `near` to `far` (world z), inset past the corridor's
    /// fixtures (runway lights, seams, ribs, beams), each vertex mapped to the room art where the
    /// camera sees the backdrop through it.
    private func sleeveMesh(near: Float, far: Float, top: Float) -> MeshDescriptor {
        let layout = scene.layout
        let floorY = layout.corridorFloorY + 0.015, ceilingY = min(layout.corridorHeight - 0.06, top - 0.02)
        let side = layout.corridorWidth / 2 - 0.08, edge = layout.corridorWidth / 2 - 0.005
        let surfaces: [(SIMD2<Float>, SIMD2<Float>, Bool)] = [   // (x, y) at both ends; sideways?
            ([-edge, floorY], [edge, floorY], false), ([-edge, ceilingY], [edge, ceilingY], false),
            ([-side, floorY], [-side, ceilingY], true), ([side, floorY], [side, ceilingY], true),
        ]
        let rows = 48, columns = 4
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for (a, b, _) in surfaces {
            let base = UInt32(positions.count)
            for r in 0...rows {
                let z = near + (far - near) * Float(r) / Float(rows)
                for c in 0...columns {
                    let xy = a + (b - a) * Float(c) / Float(columns)
                    let point = SIMD3<Float>(xy.x, xy.y, z)
                    positions.append(point)
                    uvs.append(roomArtCoordinate(of: point))
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

    /// Where the camera's line of sight through `point` meets the backdrop, in the room art's
    /// texture coordinates. It depends on the direction only, not on the backdrop's distance.
    func roomArtCoordinate(of point: SIMD3<Float>) -> SIMD2<Float> {
        let layout = scene.layout
        let forward = simd_normalize(layout.cameraTarget - layout.cameraPosition)
        let right = SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, forward)
        let d = point - layout.cameraPosition
        let depth = max(simd_dot(d, forward), 0.01)
        let half = tan(layout.cameraVerticalFieldOfView / 2 * .pi / 180) * Self.backdropOverscan
        return [0.5 + simd_dot(d, right) / depth / (2 * half * FinalVaultArt.insideAspect),
                0.5 + simd_dot(d, up) / depth / (2 * half)]
    }

    /// The height of the camera's line of sight at a depth.
    private func cameraAxisY(atZ z: Float) -> Float {
        let layout = scene.layout
        let forward = simd_normalize(layout.cameraTarget - layout.cameraPosition)
        return layout.cameraPosition.y + forward.y / -forward.z * (layout.cameraPosition.z - z)
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
