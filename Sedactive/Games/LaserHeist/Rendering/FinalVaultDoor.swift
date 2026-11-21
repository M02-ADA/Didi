//
//  FinalVaultDoor.swift
//  Sedactive
//

import CoreGraphics
import RealityKit
import UIKit

/// The final vault's round door as a mechanism (Kevin, 14 November 2026).
///
/// Until now the door "opened" by fading Asset 42 (closed) out over Asset 43 (open) while it
/// grew 4 %: nothing turned or moved, so it read as a transparent doorway appearing. Theo's
/// Asset 42 already draws the mechanism (a wheel with eight spokes, a latch bolt across the
/// seam on the right, hinges on the left), so the parts are cut out of it at load time and
/// moved for real:
///
///     wheel: counter-turn → half turn → click back into its detent
///     bolt:  its tongue across the seam slides back into the door
///     door:  clunks, sinks into its frame, swings inward on its hinges, out of sight
///
/// The frame (`wallFront`: Asset 42 with the door and the bolt cut out) never moves. Behind the
/// cut, `jamb` (Asset 43 limited to the doorway and the bolt's seat) shows the empty frame and
/// the room. The door swings in, away from the camera, so it never sweeps the mascots' plane
/// and is hidden by the wall before the camera's push, and by the camera's own field of view
/// at its end.
///
/// Pixel values are measured in the imported art (Asset 42 at 2048 × 1073; Asset 43 at the
/// same scale, 23.5 px wider on each side).
nonisolated enum FinalVaultDoorArtwork {
    /// The imported Asset 42.
    static let size = SIMD2<Float>(2048, 1073)
    /// Asset 43's extra width on each side, at the same scale.
    static let openInset: Float = 23.5
    /// The doorway: Asset 43's opaque hole edge, which is also where Asset 42's door meets its
    /// frame ring (the colours match from here outward).
    static let center = SIMD2<Float>(1024, 535.75)
    static let radius: Float = 268
    /// The door's mesh reaches this far under the frame, so the frame's antialiased cut edge
    /// always lies over door pixels.
    static let overlap: Float = 1.5
    /// The wheel: the spokes' bounding box centre and the spokes' reach (tips at 91–92 px).
    static let wheelCenter = SIMD2<Float>(1024, 535)
    static let wheelRadius: Float = 92.5
    /// The latch bolt with its drop shadow, across the seam on the right (convex).
    static let bolt: [SIMD2<Float>] = [[1229, 477], [1402, 477], [1402, 600], [1230, 600], [1187, 557], [1187, 517]]
    /// How far the bolt slides into the door: its right end then lies inside the doorway on
    /// every row (the doorway's edge is at x ≥ 1284 over the bolt's rows), behind the door's face,
    /// whose painted bolt housing stays.
    static let boltTravel: Float = 120
    /// The hinge axis: the centre of the two hinge posts on the left (x 632–696). The door hangs
    /// from it, 0.28 m out from its edge, so it swings clear of the doorway.
    static let hingeX: Float = 664
    /// The hinge leaves on the left, kept on the frame. They reach a few pixels over the door's
    /// edge; there the door shows its own rim (mirrored from the right) instead.
    static let leaves: [[SIMD2<Float>]] = [
        [[674, 279], [804, 279], [849, 317], [849, 334], [839, 353], [674, 353]],
        [[674, 670], [780, 670], [780, 722], [848, 722], [848, 756], [808, 787], [674, 787]],
    ]
    /// Asset 43 is shown only here (Asset 42 coordinates): the doorway and the bolt's seat.
    /// Its edge-on door (x 645–725) and its side shadows stay out.
    static let jambRect = CGRect(x: 748, y: 255, width: 672, height: 566)
    /// The door's own texture: a square of Asset 42 around the doorway, on 4 px boundaries so
    /// its mip levels sample like Asset 42's.
    static let faceOrigin = SIMD2<Int>(748, 260)
    static let faceSize = 552
}

/// The door's textures, cut from Asset 42 and Asset 43 once per app run.
struct FinalVaultDoorArt {
    /// Asset 42 with the door and the bolt cut out (transparent there), hinge leaves kept.
    let wallFront: TextureResource
    /// Asset 43 limited to `jambRect` (transparent elsewhere).
    let jamb: TextureResource
    /// Asset 42 around the doorway, with Asset 42's own door art (mirrored) under the leaves' tips,
    /// so they are not left painted on the door when it swings away from them.
    let face: TextureResource

    static func load(closed: CGImage, open: CGImage) async -> FinalVaultDoorArt? {
        guard let images = cutouts(closed: closed, open: open),
              let wallFront = try? await TextureResource(image: images.wallFront, withName: "finalVault.wallFront", options: .init(semantic: .color)),
              let jamb = try? await TextureResource(image: images.jamb, withName: "finalVault.jamb", options: .init(semantic: .color)),
              let face = try? await TextureResource(image: images.face, withName: "finalVault.doorFace", options: .init(semantic: .color))
        else { return nil }
        return FinalVaultDoorArt(wallFront: wallFront, jamb: jamb, face: face)
    }

    /// The three cutouts, drawn with Core Graphics (antialiased edges, no resampling).
    static func cutouts(closed: CGImage, open: CGImage) -> (wallFront: CGImage, jamb: CGImage, face: CGImage)? {
        typealias Art = FinalVaultDoorArtwork
        let k = CGFloat(closed.width) / CGFloat(Art.size.x)
        let width = closed.width, height = closed.height
        let h = CGFloat(height)
        // Asset 42 pixel (top-left origin) → Core Graphics (bottom-left origin) in its full frame.
        func point(_ p: SIMD2<Float>, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPoint {
            CGPoint(x: CGFloat(p.x) * k + dx, y: h - CGFloat(p.y) * k + dy)
        }
        func polygon(_ points: [SIMD2<Float>], dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points.map { point($0, dx: dx, dy: dy) })
            path.closeSubpath()
            return path
        }
        func circle(_ radius: Float, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
            let c = point(Art.center, dx: dx, dy: dy), r = CGFloat(radius) * k
            return CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        // In the art's own colour space, so the cutouts keep Asset 42's and 43's exact colours.
        func context(_ w: Int, _ h: Int, like image: CGImage) -> CGContext? {
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let leaves = Art.leaves.map { polygon($0) }
        // The frame keeps the leaves with 2 px to spare, so its cut edge never shows door pixels
        // that the door itself has replaced.
        let keptLeaves = leaves.map { $0.union($0.copy(strokingWithWidth: 4 * k, lineCap: .round, lineJoin: .round, miterLimit: 1)) }

        // The frame: Asset 42 without the door (outside the kept leaves) and without the bolt.
        guard let frame = context(width, height, like: closed) else { return nil }
        frame.draw(closed, in: full)
        frame.saveGState()
        let outsideLeaves = CGMutablePath()
        outsideLeaves.addRect(full)
        keptLeaves.forEach { outsideLeaves.addPath($0) }
        frame.addPath(outsideLeaves)
        frame.clip(using: .evenOdd)
        frame.setBlendMode(.clear)
        frame.addPath(circle(Art.radius))
        frame.fillPath()
        frame.restoreGState()
        frame.setBlendMode(.clear)
        frame.addPath(polygon(Art.bolt))
        frame.fillPath()

        // The jamb: Asset 43, shifted onto Asset 42's frame, only inside `jambRect`.
        let inset = CGFloat(Art.openInset) * k
        guard let jamb = context(open.width, open.height, like: open) else { return nil }
        let r = Art.jambRect
        jamb.clip(to: CGRect(x: r.minX * k + inset, y: h - r.maxY * k, width: r.width * k, height: r.height * k))
        jamb.draw(open, in: CGRect(x: 0, y: 0, width: open.width, height: open.height))

        // The door's face: a square of Asset 42 around the doorway…
        let size = Int((CGFloat(Art.faceSize) * k).rounded())
        let ox = CGFloat(Art.faceOrigin.x) * k, oy = CGFloat(Art.faceOrigin.y) * k
        // Full-frame Core Graphics coordinates → the square's own (its bottom-left at the origin).
        let dx = -ox, dy = -(h - oy - CGFloat(size))
        guard let face = context(size, size, like: closed) else { return nil }
        face.draw(closed, in: full.offsetBy(dx: dx, dy: dy))
        // …and under the leaves' tips, the door's other side mirrored across its vertical centre
        // line (the door art is near-symmetric there: rim and seam).
        let under = CGMutablePath()
        Art.leaves.forEach { under.addPath(polygon($0, dx: dx, dy: dy)) }
        face.saveGState()
        face.addPath(circle(Art.radius + Art.overlap + 1, dx: dx, dy: dy))
        face.clip()
        face.addPath(under)
        face.clip()
        // x → 2 · centre − x: Asset 42's columns map onto whole columns (no resampling).
        face.translateBy(x: 2 * CGFloat(Art.center.x) * k + dx, y: 0)
        face.scaleBy(x: -1, y: 1)
        face.draw(closed, in: full.offsetBy(dx: 0, dy: dy))
        face.restoreGState()

        guard let wallFront = frame.makeImage(), let jambImage = jamb.makeImage(), let faceImage = face.makeImage() else { return nil }
        return (wallFront, jambImage, faceImage)
    }
}

/// The mechanism's pose at one moment of the entry. A pure function of the entry's elapsed time
/// (held game time), so a replay or a repeat shows exactly the same opening, and nothing here
/// is read by gameplay.
nonisolated struct FinalVaultDoorMotion: Equatable, Sendable {
    /// The wheel's turn (radians, counter-clockwise on screen, as the door's front sees it).
    var wheel: Float = 0
    /// The bolt's slide into the door: 0 out (across the seam), 1 home (inside the door).
    var bolt: Float = 0
    /// How far the door has sunk back into its frame (metres): the seal giving way.
    var recess: Float = 0
    /// The clunk as the bolt lands: a small drop of the door (metres).
    var drop: Float = 0
    /// The door's swing about its hinges (radians), inward, away from the camera.
    var swing: Float = 0

    static let rest = FinalVaultDoorMotion()

    // Temporary tuning values (Kevin, 14 November 2026), from Simulator frames; offsets from the
    // entry's unlock (`LaserFinalVaultTimeline.unlock`, 1.5 s), when the vault comes to rest.
    // The whole opening ends by the first mascot's crouch (`firstJump`, 2.5 s).
    /// The wheel counter-turns a little as the vault comes to rest (anticipation)…
    static let windUp: ClosedRange<Double> = 0...0.1
    static let windUpAngle: Float = -10 * .pi / 180
    /// …then turns half a turn, a little past it…
    static let spin: ClosedRange<Double> = 0.1...0.42
    static let overturn: Float = 6 * .pi / 180
    /// …and clicks back into its detent.
    static let detent: ClosedRange<Double> = 0.42...0.5
    static let turn: Float = .pi
    /// The bolt is driven home as the wheel finishes.
    static let boltSlide: ClosedRange<Double> = 0.34...0.5
    /// The clunk as it lands.
    static let clunk: ClosedRange<Double> = 0.5...0.62
    static let clunkDrop: Float = 0.015
    /// The door sinks back into its frame (the seal gives)…
    static let unseal: ClosedRange<Double> = 0.48...0.6
    static let recessDepth: Float = 0.05
    /// …and swings in, heavy at the start, to where neither the corridor camera (the wall hides
    /// it) nor the camera at the end of the push (its field of view) sees it.
    static let swingTime: ClosedRange<Double> = 0.54...1.0
    static let openAngle: Float = 115 * .pi / 180

    /// The first moment anything moves (entry time).
    static var start: Double { LaserFinalVaultTimeline.unlock.lowerBound + windUp.lowerBound }
    /// When the door has finished swinging (entry time).
    static var end: Double { LaserFinalVaultTimeline.unlock.lowerBound + swingTime.upperBound }

    static func at(_ t: Double) -> FinalVaultDoorMotion {
        let u = t - LaserFinalVaultTimeline.unlock.lowerBound
        func progress(_ range: ClosedRange<Double>) -> Float {
            let x = Float(min(1, max(0, (u - range.lowerBound) / (range.upperBound - range.lowerBound))))
            return x * x * (3 - 2 * x)
        }
        var m = FinalVaultDoorMotion()
        // Each stage starts and ends at rest: a heavy part, moved in deliberate steps.
        m.wheel = windUpAngle * progress(windUp)
            + (turn + overturn - windUpAngle) * progress(spin)
            - overturn * progress(detent)
        m.bolt = progress(boltSlide)
        if clunk.contains(u) {
            m.drop = clunkDrop * sin(.pi * Float((u - clunk.lowerBound) / (clunk.upperBound - clunk.lowerBound)))
        }
        m.recess = recessDepth * progress(unseal)
        m.swing = openAngle * progress(swingTime)
        return m
    }
}

/// The door's entities: a frame that never moves, and a hinged door carrying the wheel and the bolt.
@MainActor
struct FinalVaultDoorRig {
    typealias Art = FinalVaultDoorArtwork
    /// The door's thickness (metres): seen as its rim while it swings.
    static let thickness: Float = 0.14
    /// Layer depths in front of the wall entity's plane (metres): the frame, the door's face at
    /// rest, the jamb behind both.
    static let frameZ: Float = 0.005
    static let faceZ: Float = -0.01
    static let jambZ: Float = -0.02

    let root = Entity()
    let frame: ModelEntity
    let hinge = Entity()
    let door = Entity()
    let face: ModelEntity
    let wheel: ModelEntity
    let bolt: ModelEntity
    private let hingeRest: SIMD3<Float>
    private let boltTravel: Float
    private let faceTexture: TextureResource
    private let closedTexture: TextureResource
    private var shade: Float = 1

    /// `width` × `height`: the wall plane Asset 42 is drawn on.
    init(art: FinalVaultDoorArt, closed: TextureResource, width: Float, height: Float) {
        root.name = "finalVault.mechanism"
        faceTexture = art.face
        closedTexture = closed
        // Asset 42 pixel → wall-plane metres; relative to the door's centre unless given.
        func metres(_ p: SIMD2<Float>, from origin: SIMD2<Float> = Art.center) -> SIMD2<Float> {
            [(p.x - origin.x) / Art.size.x * width, -(p.y - origin.y) / Art.size.y * height]
        }
        func fullUV(_ p: SIMD2<Float>) -> SIMD2<Float> { [p.x / Art.size.x, 1 - p.y / Art.size.y] }
        func faceUV(_ p: SIMD2<Float>) -> SIMD2<Float> {
            [(p.x - Float(Art.faceOrigin.x)) / Float(Art.faceSize), 1 - (p.y - Float(Art.faceOrigin.y)) / Float(Art.faceSize)]
        }
        func ring(_ center: SIMD2<Float>, _ radius: Float, _ segments: Int) -> [SIMD2<Float>] {
            (0..<segments).map { i in
                let a = Float(i) / Float(segments) * 2 * .pi
                return center + radius * SIMD2(cos(a), -sin(a))
            }
        }

        frame = Self.plane(art.wallFront, width: width, height: height)
        frame.name = "finalVault.wallFront"
        frame.position.z = Self.frameZ

        // The door: its face (a disc of Asset 42), its back and its rim. Its origin is the centre of
        // its face. The hinge is on the hinge posts' axis at the door's back, so no part of it comes in
        // front of the frame, and open it hangs behind the frame, clear of the doorway.
        let doorRadius = Art.radius + Art.overlap
        let rim = ring(Art.center, doorRadius, 160)
        face = ModelEntity(mesh: Self.fan(center: .zero, rim.map { metres($0) }, uv: faceUV(Art.center), rimUV: rim.map(faceUV)),
                           materials: [Self.material(art.face)])
        face.name = "finalVault.doorFace"
        let backMaterial = Self.material(UIColor(red: 0.17, green: 0.15, blue: 0.33, alpha: 1))
        let back = ModelEntity(mesh: Self.fan(center: .zero, rim.map { metres($0) }, uv: .zero, rimUV: rim.map { _ in .zero }),
                               materials: [backMaterial])
        back.name = "finalVault.doorBack"
        back.position.z = -Self.thickness
        let rimMaterial = Self.material(UIColor(red: 0.23, green: 0.2, blue: 0.42, alpha: 1))
        let edge = ModelEntity(mesh: Self.tube(rim.map { metres($0) }, depth: Self.thickness), materials: [rimMaterial])
        edge.name = "finalVault.doorRim"

        // The wheel: a disc of Asset 42 around the spokes, turning about its own centre.
        let wheelRim = ring(Art.wheelCenter, Art.wheelRadius, 96)
        wheel = ModelEntity(mesh: Self.fan(center: .zero, wheelRim.map { metres($0, from: Art.wheelCenter) },
                                           uv: fullUV(Art.wheelCenter), rimUV: wheelRim.map(fullUV)),
                            materials: [Self.material(closed)])
        wheel.name = "finalVault.wheel"
        let wheelOffset = metres(Art.wheelCenter)
        wheel.position = [wheelOffset.x, wheelOffset.y, 0.004]

        // The bolt: Asset 42's bolt, 2 px larger than the frame's cut (the cut's edge lies over it),
        // just behind the door's face: what shows of it is its tongue across the seam, and it
        // slides back into the door.
        let boltCenter = Art.bolt.reduce(SIMD2<Float>.zero, +) / Float(Art.bolt.count)
        let boltOutline = Art.bolt.map { p -> SIMD2<Float> in
            let d = p - boltCenter
            return p + 2 * simd_normalize(d)
        }
        bolt = ModelEntity(mesh: Self.fan(center: metres(boltCenter), boltOutline.map { metres($0) },
                                          uv: fullUV(boltCenter), rimUV: boltOutline.map(fullUV)),
                           materials: [Self.material(closed)])
        bolt.name = "finalVault.bolt"
        bolt.position.z = -0.005
        boltTravel = Art.boltTravel / Art.size.x * width

        door.name = "finalVault.door"
        door.addChild(face)
        door.addChild(back)
        door.addChild(edge)
        door.addChild(wheel)
        door.addChild(bolt)
        let axis = metres([Art.hingeX, Art.center.y], from: [Art.size.x / 2, Art.size.y / 2])
        let center = metres(Art.center, from: [Art.size.x / 2, Art.size.y / 2])
        hingeRest = [axis.x, center.y, Self.faceZ - Self.thickness]
        door.position = [center.x - axis.x, 0, Self.thickness]
        hinge.name = "finalVault.hinge"
        hinge.position = hingeRest
        hinge.addChild(door)
        root.addChild(frame)
        root.addChild(hinge)
    }

    /// Poses the mechanism.
    mutating func pose(_ m: FinalVaultDoorMotion) {
        hinge.position = hingeRest + [0, -m.drop, -m.recess]
        hinge.orientation = simd_quatf(angle: m.swing, axis: [0, 1, 0])
        wheel.orientation = simd_quatf(angle: m.wheel, axis: [0, 0, 1])
        bolt.position.x = -boltTravel * m.bolt
        // The face turns away from the corridor's light as it swings into the vault.
        let shade = ((0.55 + 0.45 * max(0, cos(m.swing))) * 50).rounded() / 50
        guard shade != self.shade else { return }
        self.shade = shade
        face.model?.materials = [Self.material(faceTexture, shade: shade)]
        wheel.model?.materials = [Self.material(closedTexture, shade: shade)]
        bolt.model?.materials = [Self.material(closedTexture, shade: shade)]
    }

    // MARK: - Meshes and materials

    /// Asset 42's colours exactly (no tone mapping, like the wall's planes); opaque, so the door
    /// is depth-tested against the frame and the jamb in front of it.
    private static func material(_ texture: TextureResource, shade: Float = 1) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: UIColor(white: CGFloat(shade), alpha: 1), texture: .init(texture))
        material.faceCulling = .none
        return material
    }

    /// The door's back and rim: Asset 42's door shadow colours, flat.
    private static func material(_ color: UIColor) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: color)
        material.faceCulling = .none
        return material
    }

    private static func plane(_ texture: TextureResource, width: Float, height: Float) -> ModelEntity {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        return ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
    }

    /// A flat fan: `center` joined to each consecutive pair of `rim` points (a convex outline), at z 0.
    private static func fan(center: SIMD2<Float>, _ rim: [SIMD2<Float>], uv: SIMD2<Float>, rimUV: [SIMD2<Float>]) -> MeshResource {
        var descriptor = MeshDescriptor(name: "finalVault.fan")
        descriptor.positions = MeshBuffers.Positions([SIMD3(center.x, center.y, 0)] + rim.map { SIMD3($0.x, $0.y, 0) })
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([uv] + rimUV)
        let n = UInt32(rim.count)
        descriptor.primitives = .triangles((0..<n).flatMap { i in [0, 1 + i, 1 + (i + 1) % n] })
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 0.001, height: 0.001)
    }

    /// The door's rim: the outline extruded back by `depth`.
    private static func tube(_ rim: [SIMD2<Float>], depth: Float) -> MeshResource {
        var descriptor = MeshDescriptor(name: "finalVault.rim")
        descriptor.positions = MeshBuffers.Positions(rim.flatMap { [SIMD3($0.x, $0.y, 0), SIMD3($0.x, $0.y, -depth)] })
        let n = UInt32(rim.count)
        descriptor.primitives = .triangles((0..<n).flatMap { i -> [UInt32] in
            let a = 2 * i, b = 2 * ((i + 1) % n)
            return [a, a + 1, b, b, a + 1, b + 1]
        })
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 0.001, height: 0.001)
    }
}
