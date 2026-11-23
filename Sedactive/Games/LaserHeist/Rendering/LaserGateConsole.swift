//
//  LaserGateConsole.swift
//  Sedactive
//

import Foundation
import simd

/// Each player's gate button, mounted on the gate's own frame (Kevin, owner, 20 November 2026: one
/// large button per side of the existing door frame; no console, stand, box, jamb or extra wall), and
/// the stop where the mascot docks while it leans toward its side.
///
/// Measured against the real mascot mesh, arm and camera (`LaserGateConsoleTests`):
/// - The mascot's head reaches 0.31 m forward of its root, so the door stops `doorDepth` behind the
///   players' plane, clear of it.
/// - From there a cap flat on the door would be 0.27 m in front of the shoulder: the 0.37 m arm could
///   reach only 0.22 m sideways, and the body would hide most of the cap. So the button stands on a
///   compact collar (`standoff`) off the frame's jamb, which brings its face to where an arm opened
///   sideways ends.
/// - The button is at the jamb's inner part (`frameX`). Its collar is wholly on the jamb (the frame band
///   between the door panels and the surround), so the panels slide open behind it.
/// - The mascot stays at the players' depth (its normal size). During the gate it glides `station`'s
///   short way sideways from its dock (`RobotAvatarLayer.gateTravel`), and back when the gate opens.
///   Presentation only: the judge keeps the player's tracked wrist and its approved zone
///   (`LaserLiveRoundGeometryV1`), shifted by how far the steered board is from `dockX`.
///
/// The approved Blender button (`GateButton.usdz`: a 0.30 m red cap in a recessed socket and collar on
/// a 0.44 m octagonal plate) faces the camera.
struct LaserGateConsole: Equatable {
    /// The mascot's arm in its own metres: the shoulder joint (outward from the root, height) and
    /// the shoulder→fist length.
    struct Arm: Equatable {
        var shoulder: SIMD2<Float>
        var length: Float
    }

    struct Button: Equatable {
        /// World centre of the button's mounting plate's front face (on its axis), and the cap's radius.
        var center: SIMD3<Float>
        var radius: Float
        /// The way the button faces (unit, world): toward the camera, off the door's frame. The cap
        /// presses along −normal.
        var normal: SIMD3<Float>
        /// The button's up (unit, world).
        var up: SIMD3<Float>
        /// Where the fist touches it: the cap's front centre.
        var contact: SIMD3<Float>
    }

    /// How much of the reach plane shows inside the camera's view at the players' plane (metres), the
    /// reach plane's distance from the shoulder as a share of the reach, and the dock's stand-off from
    /// it: they set where the mascot stops when it leans to its wall (`dockX`), as since 12 November 2026.
    static let visibleDepth: Float = 0.4
    static let faceShare: Float = 0.70
    static let pressSurface: Float = 0.024

    /// The Blender asset's dimensions (metres, along its axis from the plate's front face; see
    /// `Art/LaserHeist/GateButton/gatebutton_build.py`): cap radius, the cap's front at its centre and
    /// at its rounded edge, the collar's front, the plate's half-width and thickness, and the body's
    /// depth behind it.
    static let radius: Float = 0.15
    static let capFront: Float = 0.079
    static let capEdgeFront: Float = 0.059
    static let collarFront: Float = 0.034
    static let plateHalf: Float = 0.22
    static let plateDepth: Float = 0.05
    static let bodyDepth: Float = 0.25

    /// Where the gate's door stops behind the players' plane (`VaultPresentation.doorStopZ`): the
    /// mascot's head (0.31 m forward of its root) stays 3.7 cm clear of it.
    static let doorDepth: Float = 0.35
    /// The collar from the door's frame to the plate's back.
    static let standoff: Float = 0.15
    /// The button's centre from the corridor's centre and its height: on the jamb's inner part, so
    /// the mascot's body hides as little of the cap as it can and the docked board stays on a 4:3
    /// screen; at the shoulder's height less a little.
    static let frameX: Float = 2.45
    static let buttonHeight: Float = 0.62
    /// The door frame's jamb (the authored `VaultDoor` frame band, between the panels and the
    /// surround), and the mount's shift outward of the button's axis, which keeps it wholly on the jamb.
    static let jamb: ClosedRange<Float> = 2.405...2.785
    static let collarShift: Float = 0.09
    /// The access module the button is built into (Kevin, 20 November 2026, integration with the
    /// frame's art): a shallow chamfered access panel flush on the jamb's lavender band (2.41–2.67 m),
    /// outlined like the frame art, and a stepped chamfered neck from it to the plate's back (the
    /// collar). Width × height (metres), the panel's depth off the door and its corner chamfer.
    static let panelSize = SIMD2<Float>(0.25, 0.80)
    static let panelDepth: Float = 0.025
    static let panelChamfer: Float = 0.06
    static let neckSize = SIMD2<Float>(0.20, 0.30)
    /// The mascot's arm at the press: `armReach` of the shoulder→fist length out to the cap's front;
    /// it sets the mascot's `station`.
    static let armReach: Float = 0.97

    let player: PlayerID
    /// −1: the button is on the frame's left side (P1), +1: its right side (P2).
    let side: Float
    /// The mascot root's world X at its stop while a gate's docks are active (`RobotAvatarLayer.docksActive`).
    let dockX: Float
    /// The steering's limit the rest of the round.
    let wallStopX: Float
    /// The reach plane's world X (the dock's reference) and the door's plane (world z) at its stop.
    let faceX: Float
    let doorZ: Float
    /// The one activation button (keyed by the game's `LaserVaultButton`).
    let buttons: [LaserVaultButton: Button]
    var button: Button { buttons[.activate]! }
    /// The button's frame (world): origin at its mount (the plate's front face centre), +Z along
    /// `normal`, +Y up.
    let head: (center: SIMD3<Float>, orientation: simd_quatf)
    /// Where the drawn mascot's root stands to press it (world; on the players' plane): its arm opened
    /// sideways ends on the cap's front.
    let station: SIMD3<Float>

    /// How far a point (world) is in front of the door's plane (negative: behind it).
    func doorClearance(_ p: SIMD3<Float>) -> Float { p.z - doorZ }

    /// A point (world) moved out of the button and the door onto their surface, so a hand never goes
    /// inside: in the button's frame, anything behind the cap's face (within the cap) or the collar
    /// (within the plate) is brought forward onto it; anything behind the access panel, onto the
    /// panel; anything behind the door's plane, onto the door.
    func outsideConsole(_ point: SIMD3<Float>) -> SIMD3<Float> {
        var l = head.orientation.inverse.act(point - head.center)
        let r = hypot(l.x, l.y), edge = Self.radius - 0.017
        let surface: Float
        if r < Self.radius {
            surface = Self.capEdgeFront + (Self.capFront - Self.capEdgeFront) * max(0, 1 - (r * r) / (edge * edge))
        } else if r < Self.plateHalf {
            surface = Self.collarFront
        } else if abs(l.x - side * Self.collarShift) <= Self.panelSize.x / 2, abs(l.y) <= Self.panelSize.y / 2 {
            surface = -Self.plateDepth - Self.standoff + Self.panelDepth // the access panel's face
        } else {
            surface = -Self.plateDepth - Self.standoff // the door's surface
        }
        guard l.z < surface, l.z > -Self.plateDepth - Self.standoff - Self.bodyDepth else { return point }
        l.z = surface
        return head.center + head.orientation.act(l)
    }

    /// The button's plate, its collar (the neck) and the access panel as world axis-aligned boxes
    /// (clearance checks).
    var blocks: [(center: SIMD3<Float>, size: SIMD3<Float>)] {
        let plate = button.center - button.normal * Self.plateDepth / 2
        let neckDepth = Self.standoff - Self.panelDepth
        let shift = SIMD3<Float>(side * Self.collarShift, 0, 0)
        let collar = button.center - button.normal * (Self.plateDepth + neckDepth / 2) + shift
        let panel = button.center - button.normal * (Self.plateDepth + Self.standoff - Self.panelDepth / 2) + shift
        return [(center: plate, size: [2 * Self.plateHalf, 2 * Self.plateHalf, Self.plateDepth]),
                (center: collar, size: [Self.neckSize.x, Self.neckSize.y, neckDepth]),
                (center: panel, size: [Self.panelSize.x, Self.panelSize.y, Self.panelDepth])]
    }

    static func == (a: Self, b: Self) -> Bool {
        a.player == b.player && a.dockX == b.dockX && a.wallStopX == b.wallStopX && a.faceX == b.faceX && a.doorZ == b.doorZ
            && a.buttons == b.buttons && a.station == b.station
    }

    /// - Parameters:
    ///   - wallHalfWidth: the side walls' distance from the corridor's centre (the drawn walls).
    ///   - floorY, ceilingY, camera: kept for callers (the button needs only the door's frame).
    init(player: PlayerID, arm: Arm, visibleHalfWidth: Float, wallHalfWidth: Float, planeZ: Float,
         floorY: Float = LaserWorldLayout().corridorFloorY, ceilingY: Float = LaserWorldLayout().corridorHeight,
         camera: SIMD3<Float> = LaserWorldLayout().cameraPosition) {
        self.player = player
        side = player == .player1 ? -1 : 1
        let front = arm.shoulder.x + Self.faceShare * arm.length
        let faceWorld = min(visibleHalfWidth, wallHalfWidth) - Self.visibleDepth
        let plate = front + Self.pressSurface
        wallStopX = side * (faceWorld - plate)
        dockX = wallStopX // the mascot docks where the steering stops it anyway
        faceX = side * faceWorld
        doorZ = planeZ - Self.doorDepth
        // The button: on its collar off the frame's jamb, facing the camera.
        let normal = SIMD3<Float>(0, 0, 1), up = SIMD3<Float>(0, 1, 0)
        let center = SIMD3<Float>(side * Self.frameX, Self.buttonHeight, doorZ + Self.standoff + Self.plateDepth)
        let contact = center + normal * Self.capFront
        buttons = [.activate: Button(center: center, radius: Self.radius, normal: normal, up: up, contact: contact)]
        head = (center: center, orientation: simd_quatf(simd_float3x3(columns: (simd_cross(up, normal), up, normal))))
        // The mascot's station: on the players' plane, its shoulder `armReach` of the arm from the cap's
        // front, inward of it.
        let reach = Self.armReach * arm.length
        let dy = arm.shoulder.y - contact.y, dz = planeZ - contact.z
        let across = max(0, reach * reach - dy * dy - dz * dz).squareRoot()
        station = SIMD3(contact.x - side * (across + arm.shoulder.x), 0, planeZ)
        _ = (floorY, ceilingY, camera)
    }
}
