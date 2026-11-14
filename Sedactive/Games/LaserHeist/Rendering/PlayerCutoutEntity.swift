//
//  PlayerCutoutEntity.swift
//  Sedactive
//
//  Created by Edward Geraldo Kristian on 25/10/26.
//

import RealityKit
import UIKit

/// A player's flat surface in the corridor.
///
/// The entity's origin sits at the player's feet, so changing `scale` keeps the
/// feet on the floor. It shows the player's live cutout (LH-14, Edo's CP2
/// frames) when one is current, and otherwise a flat pictogram with
/// transparent surroundings, like the Hi-Fi.
///
/// The entity's own transform is the player's lane on the canonical player
/// plane and is never changed by body data. The surfaces hang under `ride`,
/// a stable presentation container with an identity transform: a live cutout
/// moves only with its own frame's placement (JUMP, DUCK, sway), and the
/// pictogram is fitted to body data on its own surface
/// (`setPlaceholderBody`), so fitting one never moves the other.
final class PlayerCutoutEntity: Entity {
    /// Live-cutout texels at or below this alpha are dropped, so fully
    /// transparent padding writes no depth and never hides a laser or the
    /// hoverboard behind it, whatever order RealityKit sorts them in. Soft
    /// edges above it still blend. Not the 0.5 cut-out used for the pictogram.
    static let liveOpacityThreshold: Float = 0.02

    private(set) var player: PlayerID = .player1
    /// Stable container for the pictogram and live surfaces; never animated.
    let ride = Entity()
    private var placeholder: Entity?
    /// The pictogram's authored height in meters, before any body fit.
    private var placeholderHeight: Float = 0
    /// Top of the shown live cutout's content, in meters above this entity.
    private var liveContentTop: Float = 0
    /// Front/back live cutout quads (see `CutoutTextureStore`); at most one shows.
    private(set) var liveSurfaces: [ModelEntity] = []
    private var debugMarkers: [ModelEntity] = []

    init(player: PlayerID, size: SIMD2<Float>, color: UIColor) {
        super.init()
        self.player = player
        name = "player.\(player.rawValue)"
        ride.name = "player.\(player.rawValue).ride"
        addChild(ride)

        // No tone mapping, so placeholder colours match the Hi-Fi exactly.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: color)
        if let texture = Self.pictogramTexture(aspect: size.x / size.y) {
            material.color = .init(tint: color, texture: .init(texture))
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = 0.5
        }
        let surface = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y), materials: [material])
        surface.name = "player.\(player.rawValue).surface"
        surface.position.y = size.y / 2
        ride.addChild(surface)
        placeholder = surface
        placeholderHeight = size.y
    }

    required init() {
        super.init()
    }

    /// Whether a live cutout is on screen rather than the pictogram.
    var isShowingLive: Bool { liveSurfaces.contains(where: \.isEnabled) }

    /// While a mascot stands here it is this player's only body: the pictogram
    /// and any live cutout stay hidden, whatever their fallbacks ask for, so
    /// one player is never drawn twice.
    var hasMascot = false {
        didSet {
            if hasMascot { liveSurfaces.forEach { $0.isEnabled = false } }
            placeholder?.isEnabled = !hasMascot && !isShowingLive
        }
    }

    /// Top of whatever body is visible, in meters above this entity's origin:
    /// the live cutout's content or the (fitted) pictogram. Feedback such as
    /// verdict badges sits above it.
    var visibleTop: Float {
        if isShowingLive { return liveContentTop }
        guard let placeholder else { return 0 }
        return (placeholder.position.y + placeholderHeight * placeholder.scale.y / 2) * scale.y
    }

    /// Fits the pictogram between `floorY` and `crownY`, in meters above this
    /// entity's origin, e.g. from replay body data. Only the pictogram's own
    /// surface changes: this entity, `ride` and any live cutout stay where
    /// they are. Ignored unless `crownY` is above `floorY`.
    func setPlaceholderBody(floorY: Float, crownY: Float) {
        guard let placeholder, placeholderHeight > 0, crownY.isFinite, floorY.isFinite, crownY > floorY else { return }
        let own = max(scale.y, .ulpOfOne)
        let height = (crownY - floorY) / own
        placeholder.scale.y = height / placeholderHeight
        placeholder.position.y = floorY / own + height / 2
    }

    /// Returns the pictogram to its authored size, standing on this entity's origin.
    func resetPlaceholderBody() {
        placeholder?.scale.y = 1
        placeholder?.position.y = placeholderHeight / 2
    }

    /// Binds the two live textures (front/back), creating the quads once and
    /// only swapping materials when the textures are recreated. Both start hidden.
    func bindLiveTextures(_ resources: [TextureResource]) {
        if liveSurfaces.isEmpty {
            liveSurfaces = resources.indices.map { index in
                let quad = ModelEntity(mesh: Self.mirroredUnitQuad, materials: [])
                quad.name = "player.\(player.rawValue).live.\(index)"
                quad.isEnabled = false
                ride.addChild(quad)
                return quad
            }
        }
        for (quad, resource) in zip(liveSurfaces, resources) {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: .white, texture: .init(resource))
            // Straight alpha, as the CP2 contract and Edo's alpha review require.
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = Self.liveOpacityThreshold
            quad.model?.materials = [material]
            quad.isEnabled = false
        }
    }

    /// Shows live surface `index` at a canvas centre and size relative to this
    /// entity (from `GameWorldMapping.cutoutQuad`), and hides the other one and
    /// the pictogram, all in one synchronous change. The cutout keeps its
    /// game-data size whatever this entity's `scale` is. `contentTop` is the
    /// top of the frame's body content (its `playerPlaneRect`), in meters.
    func showLive(index: Int, center: SIMD2<Float>, size: SIMD2<Float>, contentTop: Float) {
        guard liveSurfaces.indices.contains(index) else { return }
        liveContentTop = contentTop
        let quad = liveSurfaces[index]
        let own = SIMD2(scale.x, scale.y)
        quad.position = [center.x / own.x, center.y / own.y, 0]
        quad.scale = [size.x / own.x, size.y / own.y, 1]
        for (other, surface) in liveSurfaces.enumerated() {
            surface.isEnabled = other == index && !hasMascot
        }
        placeholder?.isEnabled = false
    }

    /// The pictogram fallback: no live image is shown for this player.
    func showPlaceholder() {
        for surface in liveSurfaces {
            surface.isEnabled = false
        }
        placeholder?.isEnabled = !hasMascot
        setDebugMarkers([])
    }

    /// Debug-only crown and sole lines from the displayed frame's own
    /// snapshot, positioned like the cutout. Not part of Release presentation.
    func setDebugMarkers(_ points: [SIMD2<Float>]) {
        #if DEBUG
        while debugMarkers.count < points.count {
            let marker = ModelEntity(mesh: .generatePlane(width: 0.36, height: 0.012),
                                     materials: [UnlitMaterial(color: .systemGreen)])
            marker.name = "player.\(player.rawValue).marker"
            addChild(marker)
            debugMarkers.append(marker)
        }
        for (index, marker) in debugMarkers.enumerated() {
            marker.isEnabled = index < points.count
            if index < points.count {
                marker.position = [points[index].x, points[index].y, 0.03]
            }
        }
        #endif
    }

    /// A 1 × 1 quad centred on its origin whose texture runs right to left:
    /// CP2 images are unmirrored, and the presentation mirrors them once.
    private static let mirroredUnitQuad: MeshResource = {
        var descriptor = MeshDescriptor(name: "mirroredCutoutQuad")
        descriptor.positions = MeshBuffer([[-0.5, -0.5, 0], [0.5, -0.5, 0], [0.5, 0.5, 0], [-0.5, 0.5, 0]])
        descriptor.normals = MeshBuffer([SIMD3<Float>](repeating: [0, 0, 1], count: 4))
        descriptor.textureCoordinates = MeshBuffer([[1, 0], [0, 0], [0, 1], [1, 1]])
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3])
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: 1, height: 1)
    }()

    /// Placeholder figure: head, shoulders with arms, and two legs, drawn in
    /// white so the material's tint sets its colour.
    private static func pictogramTexture(aspect: Float) -> TextureResource? {
        let width: CGFloat = 256
        let height = width / CGFloat(aspect)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            let head = width * 0.46
            UIBezierPath(ovalIn: CGRect(x: (width - head) / 2, y: 0, width: head, height: head)).fill()
            let shouldersTop = head + height * 0.03
            UIBezierPath(roundedRect: CGRect(x: 0, y: shouldersTop, width: width, height: height * 0.36), cornerRadius: width * 0.2).fill()
            let legsTop = shouldersTop + height * 0.3
            UIBezierPath(roundedRect: CGRect(x: width * 0.24, y: legsTop, width: width * 0.24, height: height - legsTop), cornerRadius: width * 0.1).fill()
            UIBezierPath(roundedRect: CGRect(x: width * 0.52, y: legsTop, width: width * 0.24, height: height - legsTop), cornerRadius: width * 0.1).fill()
            // Thin gaps separate the arms from the body, as in the Hi-Fi.
            context.cgContext.setBlendMode(.clear)
            for x in [width * 0.2, width * 0.765] {
                context.cgContext.fill(CGRect(x: x, y: shouldersTop + height * 0.11, width: width * 0.035, height: height))
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource(image: cgImage, options: .init(semantic: .color))
    }
}
