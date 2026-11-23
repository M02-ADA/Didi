//
//  GateAccessModule.swift
//  Sedactive
//

import Foundation
import RealityKit
import UIKit

/// The access module each gate button is built into (Kevin, 20 November 2026): it makes the approved
/// button read as part of the gate's own architecture instead of an object fixed to its side.
///
/// The gate's door is flat painted art (`VaultDoor.usda`: unlit, no tone mapping): lavender bands,
/// 45° chamfers, thin dark outlines, and a chamfered header plate holding a red indicator bar. The
/// module repeats that language on the jamb, in the same flat unlit tones:
/// - `trim`: the dark outline round the panel, where it meets the frame (the art's contact stroke);
/// - `panel`: a shallow chamfered access panel flush on the jamb's lavender band, its bevels lit from
///   above like the header plate, with an inset seam line;
/// - `collar`: a stepped chamfered neck from the panel to the button plate's back, with a seam groove;
/// - `indicator`: a slim bar above the button in a dark slot, like the header's bar; it follows the
///   button's accent colour (dark, red, green), so the module itself shows access granted;
/// - two vent grooves below the button.
///
/// Geometry from `LaserGateConsole` (panel, neck, depths); nothing here moves the button or its cap.
/// Presentation only.
enum GateAccessModule {
    /// Flat tones of one part, by face direction (lit from above, as the frame art is).
    struct Tones {
        var face: UInt32
        var bevelUp: UInt32, bevelSide: UInt32, bevelDown: UInt32
        var wallUp: UInt32, wallSide: UInt32, wallDown: UInt32
        static func flat(_ hex: UInt32) -> Tones { .init(face: hex, bevelUp: hex, bevelSide: hex, bevelDown: hex, wallUp: hex, wallSide: hex, wallDown: hex) }
    }

    /// Read from the frame art (`vault_frame.png`): its band 6B6596, header plate 676293 and its
    /// lighter top chamfer 736B9E, outlines 332F63 and 484B80.
    enum Palette {
        static let panel = Tones(face: 0x676293, bevelUp: 0x7A72A6, bevelSide: 0x6E6899, bevelDown: 0x524D80,
                                 wallUp: 0x6F699B, wallSide: 0x4C4878, wallDown: 0x3E3A68)
        /// A step darker than the panel: the neck reads as recessed structure under the button.
        static let neck = Tones(face: 0x4F4A80, bevelUp: 0x625C91, bevelSide: 0x524D84, bevelDown: 0x3B3765,
                                wallUp: 0x4E4980, wallSide: 0x3E3A6B, wallDown: 0x2F2C58)
        static let outline: UInt32 = 0x2F2C5E
        static let seamLine: UInt32 = 0x504B80
        static let groove: UInt32 = 0x2A2850
        static let slot: UInt32 = 0x2B2440
    }

    /// The module's parts, each a child of `root` (mount frame: origin on the button's axis at the
    /// plate's front face, +Z toward the camera); `indicator` is recoloured with the button's state.
    struct Parts {
        let root: Entity
        let indicator: ModelEntity
    }

    /// Builds the module for one console (its root goes into the button's frame).
    static func make(side: Float) -> Parts {
        let root = Entity()
        root.name = "vault.console.mount"
        let door = -LaserGateConsole.plateDepth - LaserGateConsole.standoff
        let panelFront = door + LaserGateConsole.panelDepth
        // Centred outward of the button's axis, wholly on the jamb.
        root.position = [side * LaserGateConsole.collarShift, 0, 0]
        let p = LaserGateConsole.panelSize, c = LaserGateConsole.panelChamfer, n = LaserGateConsole.neckSize

        func add(_ name: String, _ mesh: MeshResource?, _ materials: [any RealityKit.Material]) -> ModelEntity {
            let e = ModelEntity()
            e.name = name
            if let mesh { e.model = ModelComponent(mesh: mesh, materials: materials) }
            root.addChild(e)
            return e
        }
        // The contact outline: a little larger than the panel, just off the door.
        let trim = prism(size: p + 0.016, chamfer: c + 0.007, from: door, to: door + 0.006, bevel: 0, tones: .flat(Palette.outline))
        _ = add("vault.console.mount.trim", trim.mesh, trim.materials)
        let panel = prism(size: p, chamfer: c, from: door, to: panelFront, bevel: 0.01, tones: Palette.panel)
        _ = add("vault.console.mount.panel", panel.mesh, panel.materials)
        // The header plate's inset line, on the panel's face.
        let line = ring(size: p - 0.064, chamfer: c - 0.03, width: 0.006, at: panelFront + 0.0008, color: Palette.seamLine)
        _ = add("vault.console.mount.seam", line.mesh, line.materials)
        // The neck: a base stage, its seam groove, and the front stage up to the plate's back.
        let collar = Entity()
        collar.name = "vault.console.collar"
        root.addChild(collar)
        let base = prism(size: n, chamfer: 0.05, from: panelFront, to: panelFront + 0.035, bevel: 0.008, tones: Palette.neck)
        let groove = prism(size: n - 0.03, chamfer: 0.042, from: panelFront + 0.035, to: panelFront + 0.041, bevel: 0, tones: .flat(Palette.groove))
        let front = prism(size: n - 0.02, chamfer: 0.045, from: panelFront + 0.041, to: -LaserGateConsole.plateDepth, bevel: 0, tones: Palette.neck)
        for (name, part) in [("vault.console.collar.base", base), ("vault.console.collar.groove", groove), ("vault.console.collar.front", front)] {
            let e = ModelEntity()
            e.name = name
            if let mesh = part.mesh { e.model = ModelComponent(mesh: mesh, materials: part.materials) }
            collar.addChild(e)
        }
        // The indicator above the button, in its dark slot (like the header's bar), and the vents below.
        let y = p.y / 2 - 0.09
        let slot = prism(size: [0.15, 0.05], chamfer: 0.016, from: panelFront, to: panelFront + 0.003, bevel: 0, tones: .flat(Palette.slot))
        add("vault.console.mount.slot", slot.mesh, slot.materials).position.y = y
        let bar = prism(size: [0.13, 0.03], chamfer: 0.01, from: panelFront + 0.003, to: panelFront + 0.007, bevel: 0.002, tones: .flat(0xFFFFFF))
        let indicator = add("vault.console.mount.indicator", bar.mesh, [glow(0x3A1018)])
        indicator.position.y = y
        for (i, vy) in [-p.y / 2 + 0.10, -p.y / 2 + 0.13].enumerated() {
            let vent = prism(size: [0.13, 0.009], chamfer: 0.0045, from: panelFront, to: panelFront + 0.0015, bevel: 0, tones: .flat(Palette.groove))
            add("vault.console.mount.vent\(i + 1)", vent.mesh, vent.materials).position.y = vy
        }
        return Parts(root: root, indicator: indicator)
    }

    /// Sets the indicator's colour (the button's accent colour now).
    static func setIndicator(_ indicator: ModelEntity, _ hex: UInt32) {
        guard var model = indicator.model else { return }
        model.materials = Array(repeating: glow(hex), count: max(1, model.materials.count))
        indicator.model = model
    }

    // MARK: - Geometry

    /// An octagon (a rectangle with 45° corners `chamfer`), counter-clockwise from the right edge's top.
    static func octagon(_ size: SIMD2<Float>, chamfer: Float) -> [SIMD2<Float>] {
        let w = size.x / 2, h = size.y / 2, c = max(0, min(chamfer, min(w, h)))
        return [[w, h - c], [w - c, h], [-w + c, h], [-w, h - c], [-w, -h + c], [-w + c, -h], [w - c, -h], [w, -h + c]]
    }

    /// A chamfered octagonal prism from `z0` (its back, against what it stands on) to `z1` (its front),
    /// its front edge bevelled by `bevel` at 45°; flat tones by face direction. No back face.
    static func prism(size: SIMD2<Float>, chamfer: Float, from z0: Float, to z1: Float, bevel: Float,
                      tones: Tones) -> (mesh: MeshResource?, materials: [any RealityKit.Material]) {
        let outer = octagon(size, chamfer: chamfer)
        let b = max(0, min(bevel, (z1 - z0) * 0.9, min(size.x, size.y) * 0.25))
        // The 45° bevel's inner outline: each edge moved `b` inward (a 45° corner then shortens by b(2 − √2)).
        let inner = octagon(size - 2 * b, chamfer: chamfer - b * (2 - Float(2).squareRoot()))
        var faces: [(points: [SIMD3<Float>], normal: SIMD3<Float>, tone: UInt32)] = []
        func tone(_ normal: SIMD3<Float>) -> UInt32 {
            if normal.z > 0.9 { return tones.face }
            let bevelled = normal.z > 0.3
            if normal.y > 0.35 { return bevelled ? tones.bevelUp : tones.wallUp }
            if normal.y < -0.35 { return bevelled ? tones.bevelDown : tones.wallDown }
            return bevelled ? tones.bevelSide : tones.wallSide
        }
        for i in outer.indices {
            let a = outer[i], d = outer[(i + 1) % outer.count]
            let edge = simd_normalize(d - a), out = SIMD2(edge.y, -edge.x)
            // The wall, back to the bevel's start.
            let wallNormal = SIMD3(out.x, out.y, 0)
            faces.append(([SIMD3(a, z0), SIMD3(d, z0), SIMD3(d, z1 - b), SIMD3(a, z1 - b)], wallNormal, tone(wallNormal)))
            if b > 0 {
                let ia = inner[i], id = inner[(i + 1) % inner.count]
                let bevelNormal = simd_normalize(SIMD3(out.x, out.y, 1))
                faces.append(([SIMD3(a, z1 - b), SIMD3(d, z1 - b), SIMD3(id, z1), SIMD3(ia, z1)], bevelNormal, tone(bevelNormal)))
            }
        }
        faces.append((inner.map { SIMD3($0, z1) }, [0, 0, 1], tones.face))
        return mesh(faces)
    }

    /// A flat octagonal ring (an outline `width` wide just inside `size`) facing +Z at `z`.
    static func ring(size: SIMD2<Float>, chamfer: Float, width: Float, at z: Float,
                     color: UInt32) -> (mesh: MeshResource?, materials: [any RealityKit.Material]) {
        let outer = octagon(size, chamfer: chamfer)
        let inner = octagon(size - 2 * width, chamfer: chamfer - width * (2 - Float(2).squareRoot()))
        var faces: [(points: [SIMD3<Float>], normal: SIMD3<Float>, tone: UInt32)] = []
        for i in outer.indices {
            let j = (i + 1) % outer.count
            faces.append(([SIMD3(outer[i], z), SIMD3(outer[j], z), SIMD3(inner[j], z), SIMD3(inner[i], z)], [0, 0, 1], color))
        }
        return mesh(faces)
    }

    /// One mesh from convex polygons (fanned), each wound to face its normal; one flat unlit material
    /// per distinct tone.
    private static func mesh(_ faces: [(points: [SIMD3<Float>], normal: SIMD3<Float>, tone: UInt32)])
        -> (mesh: MeshResource?, materials: [any RealityKit.Material]) {
        var tones: [UInt32] = []
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], faceMaterials: [UInt32] = []
        for face in faces {
            let material: UInt32
            if let i = tones.firstIndex(of: face.tone) { material = UInt32(i) } else { tones.append(face.tone); material = UInt32(tones.count - 1) }
            let start = UInt32(positions.count)
            positions += face.points
            normals += Array(repeating: face.normal, count: face.points.count)
            for k in 1..<(face.points.count - 1) {
                var tri: [UInt32] = [start, start + UInt32(k), start + UInt32(k + 1)]
                let p = tri.map { positions[Int($0)] }
                if simd_dot(simd_cross(p[1] - p[0], p[2] - p[0]), face.normal) < 0 { tri.swapAt(1, 2) }
                indices += tri
                faceMaterials.append(material)
            }
        }
        var descriptor = MeshDescriptor(name: "gate.access.module")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .perFace(faceMaterials)
        return (try? MeshResource.generate(from: [descriptor]), tones.map { glow($0) })
    }

    /// The door's own surface: unlit, no tone mapping (`VaultDoor.usda`), so the tones match the art.
    static func glow(_ hex: UInt32) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                             blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
        return material
    }
}
