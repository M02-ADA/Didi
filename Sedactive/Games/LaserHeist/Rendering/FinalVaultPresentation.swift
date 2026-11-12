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
    /// The room's backdrop behind the wall while the doorway shows it.
    static let backdropGap: Float = 0.9
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
    private let wallWidth: Float
    private let wallHeight: Float
    /// The wall's centre height: the corridor's centre.
    private let wallY: Float
    /// Mascots this presentation moves; their moves are cleared when it hides.
    private var moved: Set<PlayerID> = []

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
        scene.root.addChild(wall)
        scene.root.addChild(backdrop)
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
            let p = Float((t - push.lowerBound) / (push.upperBound - push.lowerBound))
            let e = p * p
            z += (scene.layout.cameraPosition.z - Self.pushEndDistance - Self.stopZ) * e
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
        if backdrop.isEnabled { placeBackdrop(atDistance: scene.layout.cameraPosition.z - (z - Self.backdropGap)) }
    }

    /// One mascot's scripted move at `t` (the mascots already face the vault, as in
    /// Home Copy 31): a crouch, an arc
    /// through the doorway (smaller with distance), gone behind the wall; the board
    /// stays in the corridor and fades; then a landing in its place inside the room.
    private func move(_ player: PlayerID, timeline: LaserFinalVaultTimeline, at t: Double) -> RobotAvatarLayer.ScriptedMove {
        guard let jump = timeline.jump(of: player) else { return .none }
        var move = RobotAvatarLayer.ScriptedMove()
        let tau = Float(t - jump.lowerBound)
        guard tau >= 0 else { return move }
        move.boardOpacity = 1 - min(1, max(0, (tau - 0.35) / 0.4))
        let crouch = Float(LaserFinalVaultTimeline.anticipation)
        if tau < crouch {
            let a = Self.smooth(tau / crouch)
            move.squash = 1 - 0.2 * a
            return move
        }
        if t < timeline.land.lowerBound {
            let flight = Float(LaserFinalVaultTimeline.jumpDuration) - crouch
            let f = min(1, (tau - crouch) / flight)
            guard f < 1 else { move.opacity = 0; return move }
            move.offset = jumpOffset(player, at: f)
            move.scale = 1 - 0.3 * Self.smooth(f)
            move.squash = 1 + 0.12 * (1 - Self.smooth(min(1, f / 0.3)))
            move.opacity = f < 0.82 ? 1 : 1 - (f - 0.82) / 0.18
            return move
        }
        // Landing in the room, one after the other.
        let index = Double(timeline.jumpers.firstIndex(of: player) ?? 0)
        let stagger = 0.1
        let start = timeline.land.lowerBound + stagger * index
        let duration = Float(LaserFinalVaultTimeline.landDuration - stagger * Double(timeline.jumpers.count - 1))
        let f = Float(min(1, max(0, t - start))) / duration
        move.boardOpacity = 0
        guard f > 0 else { move.opacity = 0; return move }
        let g = min(1, f)
        move.offset.y = 1.3 * (1 - g * g)
        move.opacity = min(1, g / 0.2)
        if g > 0.75 { move.squash = 1 - 0.15 * sin(.pi * (g - 0.75) / 0.25) }
        return move
    }

    /// The arc from the mascot's place to the doorway and just through it (lane-local
    /// metres): up first, then down into the opening, crossing the wall late in the flight.
    /// It starts where the mascot rides (lean steering may have moved it off its lane).
    func jumpOffset(_ player: PlayerID, at f: Float) -> SIMD3<Float> {
        let laneX = scene.mapping.laneCenterX[player, default: 0] + (scene.robotAvatars?.trackedRootX(player) ?? 0)
        let throughZ = Self.stopZ - 0.6 - scene.mapping.interactionPlaneZ
        let x = Self.bezier(0, 0.15, 0.85, 1, f) * -laneX
        let y = Self.bezier(0, 1.9, 0.8, 0.35, f)
        let z = Self.bezier(0, -0.1, -0.6, throughZ, f)
        return [x, y, z]
    }

    // MARK: - Inside

    private func showInside() {
        wall.isEnabled = false
        scene.setCorridorShown(false)
        guard let backdrop else { return }
        backdrop.isEnabled = true
        placeBackdrop(atDistance: Self.insideDistance)
    }

    private func hide() {
        wall.isEnabled = false
        backdrop?.isEnabled = false
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
