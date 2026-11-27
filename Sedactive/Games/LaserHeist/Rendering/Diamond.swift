import RealityKit
import UIKit

/// Loaded once by LaserScene. Each gem uses its authored mesh, with a shared sparkle template.
/// Clones share meshes and materials, and never load assets on collection.
@MainActor
final class DiamondArt {
    private let gem: Entity
    private let passageGem: Entity
    private let sparkle: Entity
    init?(artwork: Entity) {
        guard let diamond = artwork.findEntity(named: "Diamond"),
              let gem = diamond.findEntity(named: "Gem"),
              let passageGem = diamond.findEntity(named: "PassageGem"),
              let sparkle = diamond.findEntity(named: "Sparkle")
        else { return nil }
        self.gem = gem; self.passageGem = passageGem; self.sparkle = sparkle
    }
    func makeDiamond(passage: Bool = false) -> Diamond {
        Diamond(gem: (passage ? passageGem : gem).clone(recursive: true), passage: passage, sparkles: (0..<4).map { _ in sparkle.clone(recursive: true) })
    }
}

/// Presentation only. Collection is requested by the existing committed domain outcome.
/// No tasks, clocks, event subscriptions, contacts or score authority live here.
@MainActor
final class Diamond {
    enum Phase { case ready, idle, collected, removed }
    private(set) var phase: Phase = .ready
    static let floatHeight: Float = 0.015
    static let collectDuration: TimeInterval = 0.24
    static let sparkleDuration: TimeInterval = 0.36
    static let effectLifetime: TimeInterval = 0.39
    static let sparkleDistance: Float = 0.22
    let root = Entity()
    private let body = Entity()
    private let gem: Entity
    private let flash: Entity
    private let sparkles: [Entity]
    private let passage: Bool
    private let contactRadius: Float
    private var burst: Entity?
    private let passageRim: Entity?
    private let passageAura: ModelEntity?
    private var passageGlow: (phase: PassageGlow, glintFrame: Int)?
    enum PassageGlow { case approaching, collectible, passed }

    fileprivate init(gem: Entity, passage: Bool, sparkles: [Entity]) {
        self.gem = gem; self.sparkles = sparkles
        self.passage = passage
        gem.transform = .identity
        let size = gem.visualBounds(relativeTo: gem).extents
        contactRadius = max(size.x, size.y, size.z) / 2
        flash = gem.clone(recursive: true)
        flash.name = "diamond.flash"
        Self.flashMaterial(flash)
        flash.isEnabled = false
        passageRim = passage ? Self.makePassageRim(from: gem) : nil
        passageAura = passage ? Self.auraTemplate?.clone(recursive: false) : nil
        root.name = "diamond"
        root.addChild(body); body.addChild(gem); body.addChild(flash)
        if let passageRim { body.addChild(passageRim) }
        if let passageAura { body.addChild(passageAura) }
        for sparkle in sparkles {
            sparkle.transform = .identity; sparkle.isEnabled = false; root.addChild(sparkle)
        }
    }

    /// Back faces of slightly expanded copies form a silhouette rim. Every
    /// layer shares the gem's pivot, so flank views cannot separate the light.
    private static func makePassageRim(from gem: Entity) -> Entity? {
        guard let mesh = gem.findEntity(named: "FacetedGem") as? ModelEntity,
              let model = mesh.model else { return nil }
        let rim = Entity()
        rim.name = "diamond.passageRim"
        rim.isEnabled = false
        let layers: [(name: String, scale: Float, color: UIColor, opacity: Float)] = [
            ("diamond.rimCore", 1.065, UIColor(red: 0.77, green: 0.96, blue: 1, alpha: 1), 0.94),
            ("diamond.rimSpill", 1.16, UIColor(red: 0.33, green: 0.77, blue: 1, alpha: 1), 0.27)
        ]
        for layer in layers {
            var light = UnlitMaterial(applyPostProcessToneMap: false)
            light.color = .init(tint: layer.color)
            light.blending = .transparent(opacity: .init(floatLiteral: layer.opacity))
            light.faceCulling = .front
            let glow = ModelEntity(mesh: model.mesh,
                                   materials: Array(repeating: light, count: model.materials.count))
            glow.name = layer.name
            glow.scale = .init(repeating: layer.scale)
            rim.addChild(glow)
        }
        return rim
    }

    private static let auraTemplate: ModelEntity? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 128, height: 128)
        let colors = [
            UIColor(red: 0.92, green: 0.99, blue: 1, alpha: 0.63).cgColor,
            UIColor(red: 0.54, green: 0.89, blue: 1, alpha: 0.35).cgColor,
            UIColor(red: 0.29, green: 0.70, blue: 1, alpha: 0.095).cgColor,
            UIColor(red: 0.29, green: 0.70, blue: 1, alpha: 0).cgColor
        ]
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: [0, 0.37, 0.70, 1]) else { return nil }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            renderer.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                 endCenter: center, endRadius: size.width / 2, options: [])
        }
        guard let pixels = image.cgImage,
              let texture = try? TextureResource(image: pixels, withName: "diamond.passageAura",
                                                 options: .init(semantic: .color)) else { return nil }
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: 1.0)
        material.faceCulling = .none
        let aura = ModelEntity(mesh: .generatePlane(width: 0.78, height: 0.78), materials: [material])
        aura.name = "diamond.passageAura"
        aura.isEnabled = false
        return aura
    }()

    /// The corridor aura is light, so even its transparent corners must not occlude a mascot.
    func disablePassageAuraDepthWrites() {
        guard let passageAura, var model = passageAura.model,
              var material = model.materials.first as? UnlitMaterial else { return }
        material.writesDepth = false
        model.materials = [material]
        passageAura.model = model
    }

    private static func flashMaterial(_ entity: Entity) {
        if let model = entity as? ModelEntity {
            model.model?.materials = model.model?.materials.map { _ in
                UnlitMaterial(color: UIColor(red: 0.7, green: 0.95, blue: 1, alpha: 1))
            } ?? []
        }
        for child in entity.children { flashMaterial(child) }
    }

    func showIdle(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard phase == .ready else { return }
        phase = .idle
        guard !reduceMotion, !passage else { return }
        var raised = Transform.identity; raised.translation.y = Self.floatHeight
        loop(body, to: raised, duration: 0.85)
        var rocked = Transform.identity
        rocked.rotation = simd_quatf(angle: .pi / 60, axis: [0, 1, 0])
        loop(gem, to: rocked, duration: 1.2)
    }

    /// Expose the crown and side facets without presenting an edge-on silhouette.
    /// Driven by game time so a paused diamond holds its orientation.
    func updatePassagePose(age: Double, glow: PassageGlow = .approaching,
                           cameraPosition: SIMD3<Float>? = nil, reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard passage, phase == .idle else { return }
        updateFacetGlint(age: age, glow: glow, reduceMotion: reduceMotion)
        if reduceMotion {
            gem.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        } else {
            let angle = Float(age) * 2 * .pi / 2.4
            let turn = simd_quatf(angle: 0.76 * cos(angle), axis: [0, 1, 0])
            let tilt = simd_quatf(angle: 0.24 + 0.14 * sin(angle), axis: [1, 0, 0])
            // Turn around the centred culet before tilting toward the camera.
            gem.orientation = tilt * turn
        }
        if let passageRim {
            passageRim.transform = gem.transform
            passageRim.isEnabled = glow != .passed
            let strength: Float = glow == .collectible ? 1 : 0.83
            if passageRim.components[OpacityComponent.self]?.opacity != strength {
                passageRim.components.set(OpacityComponent(opacity: strength))
            }
        }
        updatePassageAura(glow: glow, cameraPosition: cameraPosition)
    }

    private func updatePassageAura(glow: PassageGlow, cameraPosition: SIMD3<Float>?) {
        guard let passageAura else { return }
        guard glow != .passed, let cameraPosition else {
            passageAura.isEnabled = false
            return
        }
        let center = gem.position
        let towardCamera = body.convert(position: cameraPosition, from: nil) - center
        guard simd_length_squared(towardCamera) > 0.0001 else {
            passageAura.isEnabled = false
            return
        }
        let ray = simd_normalize(towardCamera)
        // Move back along the camera ray through the gem, not the corridor's
        // Z axis. The aura and gem then project to the same screen centre.
        passageAura.position = center - ray * 0.29
        passageAura.orientation = simd_quatf(from: [0, 0, 1], to: ray)
        passageAura.isEnabled = true
        let strength: Float = glow == .collectible ? 1 : 0.78
        if passageAura.components[OpacityComponent.self]?.opacity != strength {
            passageAura.components.set(OpacityComponent(opacity: strength))
        }
    }

    private func updateFacetGlint(age: Double, glow: PassageGlow, reduceMotion: Bool) {
        // Briefly accent two material groups on the mesh itself. Limit
        // material writes while keeping the visible turn at render rate.
        let cycle = 1.0
        let frame = !reduceMotion && glow != .passed
            ? Int(age.truncatingRemainder(dividingBy: cycle) * 24) : -1
        guard passageGlow?.phase != glow || passageGlow?.glintFrame != frame,
              let mesh = gem.findEntity(named: "FacetedGem") as? ModelEntity, var model = mesh.model else { return }
        let base: Float = switch glow {
        case .approaching: 1.38
        case .collectible: 1.76
        case .passed: 1.08
        }
        let count = model.materials.count
        let leadingFacet = frame < 0 || count < 2 ? -1 : (frame / 8 * 3) % count
        let trailingFacet = leadingFacet < 0 ? -1 : (leadingFacet + count / 2) % count
        let progress = Float(max(0, frame) % 8) / 8
        let glint = sin(.pi * progress)
        model.materials = model.materials.enumerated().map { index, material in
            guard var facet = material as? PhysicallyBasedMaterial else { return material }
            let highlight: Float = switch index {
            case leadingFacet: 1.08 * glint
            case trailingFacet: 0.54 * glint
            default: 0
            }
            facet.emissiveIntensity = base + highlight
            return facet
        }
        mesh.model = model
        passageGlow = (glow, frame)
    }

    func placeOnScreen(at position: SIMD3<Float>, rotation: simd_quatf, radius: Float) {
        root.setPosition(position, relativeTo: nil)
        root.setOrientation(rotation, relativeTo: nil)
        root.scale = .init(repeating: radius / contactRadius)
    }

    var collectionWorldPosition: SIMD3<Float> { gem.visualBounds(relativeTo: nil).center }

    /// Use the visible gem, excluding sparkles and the HUD flight.
    var bodyContactSphere: (center: SIMD3<Float>, radius: Float) {
        if passage {
            let center = gem.position(relativeTo: nil)
            let scale = simd_distance(body.convert(position: [1, 0, 0], to: nil), body.position(relativeTo: nil))
            return (center, contactRadius * scale)
        }
        let bounds = gem.visualBounds(relativeTo: nil)
        return (bounds.center, max(bounds.extents.x, bounds.extents.y, bounds.extents.z) / 2)
    }

    func collect(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled, fullBurst: Bool = true) {
        guard phase == .ready || phase == .idle else { return }
        phase = .collected
        passageRim?.isEnabled = false
        passageAura?.isEnabled = false
        // Preserve the visible float offset when idle stops; the target root never moves.
        body.stopAllAnimations(); gem.stopAllAnimations()
        if !passage { gem.transform = .identity }
        let contactPose = gem.transform
        fade(gem, from: 1, to: 0, duration: Self.collectDuration)
        guard !reduceMotion else { return }
        var popped = contactPose; popped.scale = .init(repeating: passage ? 1.55 : 1.3)
        var gone = contactPose; gone.scale = .init(repeating: 0.05)
        sequence(gem, transforms: [(contactPose, popped, 0.08), (popped, gone, 0.16)])
        flash.isEnabled = true
        var halo = contactPose; halo.scale = .init(repeating: passage ? 1.35 : 1.08)
        flash.transform = halo
        fade(flash, from: 0.65, to: 0, duration: 0.10)
        guard fullBurst else { return }
        for (sparkle, direction) in zip(sparkles, [SIMD2<Float>(1, 1), [-1, 1], [1, -1], [-1, -1]]) {
            var start = Transform.identity; start.scale = .init(repeating: passage ? 0.48 : 0.25)
            var end = Transform.identity; end.scale = .init(repeating: 0.08)
            end.translation = SIMD3(normalize(direction) * Self.sparkleDistance * (passage ? 2.3 : 1), 0.01)
            sparkle.isEnabled = true
            sequence(sparkle, transforms: [(start, end, Self.sparkleDuration)])
            fade(sparkle, from: 1, to: 0, duration: Self.sparkleDuration)
        }
        if passage { showPassageBurst() }
    }

    private static let ringMesh: MeshResource? = {
        let segments = 40
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in 0..<segments {
            let angle = 2 * Float.pi * Float(index) / Float(segments)
            let direction = SIMD3<Float>(cos(angle), sin(angle), 0)
            vertices += [direction * 0.91, direction]
            let a = UInt32(index * 2), b = UInt32((index + 1) % segments * 2)
            indices += [a, a + 1, b + 1, a, b + 1, b]
        }
        var ring = MeshDescriptor(name: "diamond.pickupRing")
        ring.positions = MeshBuffers.Positions(vertices)
        ring.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [ring])
    }()

    /// One shared, single-material mesh instead of cloning the nine-facet gem per shard.
    private static let shardMesh: MeshResource? = {
        var shard = MeshDescriptor(name: "diamond.pickupShard")
        shard.positions = MeshBuffers.Positions([
            [0, 0.15, 0], [0.11, 0.025, 0], [0, 0.025, 0.09],
            [-0.11, 0.025, 0], [0, 0.025, -0.09], [0, -0.14, 0]
        ])
        shard.primitives = .triangles([
            0, 2, 1, 0, 3, 2, 0, 4, 3, 0, 1, 4,
            5, 1, 2, 5, 2, 3, 5, 3, 4, 5, 4, 1
        ])
        return try? MeshResource.generate(from: [shard])
    }()

    private func showPassageBurst() {
        let effect = Entity()
        effect.name = "diamond.passageBurst"
        root.addChild(effect)
        burst = effect
        if let mesh = Self.ringMesh {
            let ring = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .systemCyan)])
            ring.name = "diamond.pickupRing"
            effect.addChild(ring)
            let start = Transform(scale: .init(repeating: 0.16), translation: [0, 0, 0.10])
            let end = Transform(scale: .init(repeating: 0.62), translation: [0, 0, 0.10])
            sequence(ring, transforms: [(start, end, 0.26)])
            fade(ring, from: 0.95, to: 0, duration: 0.26)
        }

        guard let mesh = Self.shardMesh else { return }
        let colors: [UIColor] = [.systemCyan, .white, .systemYellow, .systemPink]
        for index in 0..<8 {
            let shard = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: colors[index % colors.count])])
            shard.name = "diamond.pickupShard"
            effect.addChild(shard)
            let angle = Float(index) * .pi / 4 + .pi / 8
            let direction = SIMD3<Float>(cos(angle), sin(angle), 0.18 + 0.09 * Float(index % 3))
            let start = Transform(scale: [0.30, 0.39, 0.40], translation: direction * 0.12)
            let end = Transform(scale: .init(repeating: 0.035),
                                rotation: simd_quatf(angle: 1.6, axis: simd_normalize([1, 1, 0.6])),
                                translation: direction * (index.isMultiple(of: 2) ? 0.72 : 0.53))
            sequence(shard, transforms: [(start, end, Self.sparkleDuration)])
            fade(shard, from: 1, to: 0, duration: Self.sparkleDuration)
        }
    }

    func remove() {
        guard phase == .ready || phase == .idle else { return }
        phase = .removed
        passageRim?.isEnabled = false
        passageAura?.isEnabled = false
        body.stopAllAnimations(); gem.stopAllAnimations()
        fade(gem, from: 1, to: 0, duration: 0.2)
    }

    /// Explicit reset for a reusable, still-owned visual. A retired target is terminal.
    func reset() {
        guard phase != .removed else { return }
        root.stopAllAnimations(recursive: true)
        burst?.removeFromParent()
        burst = nil
        passageGlow = nil
        passageRim?.isEnabled = false
        passageAura?.isEnabled = false
        body.transform = .identity
        gem.transform = .identity
        gem.components.remove(OpacityComponent.self)
        flash.isEnabled = false
        for sparkle in sparkles {
            sparkle.components.remove(OpacityComponent.self)
            sparkle.isEnabled = false
        }
        phase = .ready
    }

    /// Stops all native animation controllers on teardown; no completion callback can revive it.
    func retire() {
        phase = .removed
        root.stopAllAnimations(recursive: true)
        root.removeFromParent()
    }

    private func loop(_ part: Entity, to: Transform, duration: TimeInterval) {
        let definition = FromToByAnimation(from: Transform.identity, to: to, duration: duration,
            timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)
        if let animation = try? AnimationResource.generate(with: definition).repeat() {
            part.playAnimation(animation, handoffType: .compose)
        }
    }
    private func sequence(_ part: Entity, transforms: [(Transform, Transform, TimeInterval)]) {
        let resources = transforms.compactMap { from, to, duration in
            try? AnimationResource.generate(with: FromToByAnimation(from: from, to: to,
                duration: duration, timing: .easeOut, bindTarget: .transform))
        }
        if let resource = try? AnimationResource.sequence(with: resources) {
            part.transform = transforms[0].0
            part.playAnimation(resource, handoffType: .compose)
        }
    }
    private func fade(_ part: Entity, from: Float, to: Float, duration: TimeInterval) {
        part.components.set(OpacityComponent(opacity: to))
        if let resource = try? AnimationResource.generate(with: FromToByAnimation(from: from, to: to,
            duration: duration, timing: .easeIn, bindTarget: .opacity)) {
            part.playAnimation(resource, handoffType: .compose)
        }
    }
}
