//
//  LaserGateConsole.swift
//  Sedactive
//

import simd

/// Each player's vault-button console, mounted on that player's corridor wall at the players'
/// plane, and the stop where the mascot docks beside it (owner Option A: stop before the wall and
/// reach the button with the mascot's own hand).
///
/// Why a console and not buttons on the bare wall (measured, `LaserGateConsoleTests`):
/// - The corridor wall at the players' plane (±3.15 m) is outside the camera's view there on a 4:3
///   iPad (±2.58 m): a button on it could be neither seen nor reached on screen.
/// - The hoverboard (half-width 0.58 m) is wider than the mascot's whole reach (shoulder 0.15 m +
///   arm and fist 0.37 m): against a flat wall the board touches it before any hand can.
///
/// The unified column (iPad, 12 November 2026): three equal buttons on one inward-facing face, set
/// where the mascot's own fist can touch all three from its dock (`Arm`): the caps' fronts are
/// `faceShare` of the reach out from the shoulder, LOW sits just inside the reach at the bottom of
/// that plane, HIGH two spacings above. The column leans toward the camera by `lean` at HIGH: the
/// chibi head's front would otherwise cover HIGH from the game camera, and the fist reaches a little
/// forward there (inside its reach). The mascot's fist goes onto the button whose judged zone holds
/// the tracked wrist (`RobotAvatarLayer`); the judge keeps the tracked wrist and its approved zones
/// (`LaserLiveRoundGeometryV1`), shifted by how far the mascot is from this dock.
struct LaserGateConsole: Equatable {
    /// The mascot's arm in its own metres: the shoulder joint (outward from the root, height) and
    /// the shoulder→fist length.
    struct Arm: Equatable {
        var shoulder: SIMD2<Float>
        var length: Float
    }

    struct Button: Equatable {
        /// World centre of the button's mount (on the plate) and the pressable cap's radius.
        var center: SIMD3<Float>
        var radius: Float
        /// The way the button faces (unit, world): into the corridor.
        var normal: SIMD3<Float>
        /// Where a fist touches it: the cap's front centre.
        var contact: SIMD3<Float>
    }

    /// How much of the console shows inside the camera's view at the players' plane (metres).
    static let visibleDepth: Float = 0.4
    /// The caps' distance from the shoulder as a share of the reach, the centre-to-centre spacing,
    /// how far HIGH leans toward the camera, and the bezel and margins.
    static let faceShare: Float = 0.70
    static let spacing: Float = 0.20
    static let lean: Float = 0.20
    static let bezel: Float = 0.008
    static let margin: Float = 0.04
    /// How far an unpressed cap's front stands proud of the plate: where the fist touches it.
    static let pressSurface: Float = 0.024
    /// The cap radius that fits the spacing with a clear gap between bezels.
    static var radius: Float { (spacing - 2 * bezel - 0.012) / 2 }

    let player: PlayerID
    /// −1: the console is on the left wall (P1), +1: the right wall (P2).
    let side: Float
    /// The mascot root's world X at its stop (where the fist reaches all three buttons).
    let dockX: Float
    /// The plate's world X (the caps stand `pressSurface` proud of it, toward the mascot) and the wall.
    let faceX: Float
    let wallX: Float
    let buttons: [LaserVaultButton: Button]
    /// The housing: centre, size (wall-to-face × column length × width) and its lean about the
    /// corridor's X axis (radians; top toward the camera).
    let housing: (center: SIMD3<Float>, size: SIMD3<Float>, tilt: Float)

    /// The housing's axis-aligned bounds (clearance checks).
    var blocks: [(center: SIMD3<Float>, size: SIMD3<Float>)] {
        let c = cos(housing.tilt), s = abs(sin(housing.tilt))
        return [(center: housing.center, size: [housing.size.x, housing.size.y * c + housing.size.z * s,
                                                 housing.size.z * c + housing.size.y * s])]
    }

    static func == (a: Self, b: Self) -> Bool {
        a.player == b.player && a.dockX == b.dockX && a.faceX == b.faceX && a.buttons == b.buttons
            && a.housing.center == b.housing.center && a.housing.size == b.housing.size && a.housing.tilt == b.housing.tilt
    }

    init(player: PlayerID, arm: Arm, visibleHalfWidth: Float, wallHalfWidth: Float, planeZ: Float) {
        self.player = player
        side = player == .player1 ? -1 : 1
        let inward = SIMD3<Float>(-side, 0, 0)
        let front = arm.shoulder.x + Self.faceShare * arm.length
        let band = (arm.length * arm.length - (front - arm.shoulder.x) * (front - arm.shoulder.x)).squareRoot()
        let low = arm.shoulder.y - band + 0.012
        let heights: [LaserVaultButton: Float] = [.bottom: low, .middle: low + Self.spacing, .top: low + 2 * Self.spacing]
        let faceWorld = min(visibleHalfWidth, wallHalfWidth) - Self.visibleDepth
        let plate = front + Self.pressSurface
        dockX = side * (faceWorld - plate)
        faceX = side * faceWorld
        wallX = side * wallHalfWidth
        var buttons: [LaserVaultButton: Button] = [:]
        for (button, y) in heights {
            let z = planeZ + Self.lean * (y - low) / (2 * Self.spacing)
            let center = SIMD3<Float>(faceX, y, z)
            buttons[button] = Button(center: center, radius: Self.radius, normal: inward, contact: center + inward * Self.pressSurface)
        }
        self.buttons = buttons
        let tilt = atan2(Self.lean, 2 * Self.spacing)
        let ring = Self.radius + Self.bezel
        let length = (2 * Self.spacing) / cos(tilt) + 2 * (ring + Self.margin)
        housing = (center: [(faceX + wallX) / 2, low + Self.spacing, planeZ + Self.lean / 2],
                   size: [abs(wallX - faceX), length, 2 * (ring + Self.margin)], tilt: tilt)
    }
}
