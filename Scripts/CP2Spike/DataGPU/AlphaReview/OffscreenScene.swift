import AppKit
import Foundation
import Metal
import RealityKit

@MainActor func setReviewFiltering(_ store: UploadStore, nearest: Bool) {
  for pair in store.surfaces.values {
    for surface in pair {
      guard var material = surface.model.model?.materials.first as? UnlitMaterial,
        var texture = material.color.texture
      else { continue }
      texture.sampler.modify {
        $0.minFilter = nearest ? .nearest : .linear
        $0.magFilter = nearest ? .nearest : .linear
        $0.mipFilter = .notMipmapped
        $0.sAddressMode = .clampToEdge
        $0.tAddressMode = .clampToEdge
      }
      material.color.texture = texture
      surface.model.model?.materials = [material]
    }
  }
}
@MainActor func setReviewDepthWrites(_ store: UploadStore, enabled: Bool) {
  for pair in store.surfaces.values {
    for surface in pair {
      guard var material = surface.model.model?.materials.first as? UnlitMaterial else { continue }
      material.writesDepth = enabled
      surface.model.model?.materials = [material]
    }
  }
}
nonisolated struct RenderedImage: Sendable {
  let bytes: Data
  let width: Int, height: Int
  func rgb(x: Int, y: Int) -> [Double] {
    let p = (y * width + x) * 4
    return [Double(bytes[p + 2]) / 255, Double(bytes[p + 1]) / 255, Double(bytes[p]) / 255]
  }
  func writePNG(_ path: String) throws {
    let image = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: [
        .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
      ],
      provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(
      to: URL(fileURLWithPath: path))
  }
}
@MainActor final class OffscreenScene {
  let store: UploadStore
  let renderer: RealityRenderer
  let target: any MTLTexture
  let output: RealityRenderer.CameraOutput
  let debugRoot = Entity()
  let laserRoot = Entity()
  private let sortGroup = ModelSortGroup()
  var renders = 0
  private(set) var debugFrames: [PlayerID: UInt64] = [:]
  init(store: UploadStore) throws {
    self.store = store
    renderer = try RealityRenderer()
    renderer.entities.append(store.root)
    let camera = PerspectiveCamera()
    camera.camera.fieldOfViewInDegrees = 50
    camera.camera.fieldOfViewOrientation = .vertical
    camera.position = [0, 0.8, 3.4]
    camera.look(at: [0, 0.8, 0], from: camera.position, relativeTo: nil)
    store.root.addChild(camera)
    renderer.activeCamera = camera
    renderer.cameraSettings.isToneMappingEnabled = false
    renderer.cameraSettings.antialiasing = .none
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm_srgb, width: 1280, height: 960, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    guard let t = store.device.makeTexture(descriptor: d) else {
      throw SpikeError.invalid("render target")
    }
    target = t
    output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: t))
    store.root.addChild(debugRoot)
    store.root.addChild(laserRoot)
  }
  func background(_ value: Double) {
    renderer.cameraSettings.colorBackground = .color(
      CGColor(srgbRed: value, green: value, blue: value, alpha: 1))
  }
  func updateDots() {
    debugRoot.children.removeAll()
    debugFrames.removeAll()
    for id in PlayerID.allCases {
      guard let s = store.displayed[id], let g = s.players[id]?.geometry, let cx = g.centerX.value,
        let crown = g.crownY.value, let sole = g.leftSoleY.value
      else { continue }
      debugFrames[id] = s.frameID
      var material = UnlitMaterial(applyPostProcessToneMap: false)
      material.color = .init(tint: id == .player1 ? NSColor.yellow : NSColor.cyan)
      for y in [crown, sole] {
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [material])
        dot.position = [Float(2 * spikeLayout.centerX(for: id) - cx), Float(y), 0.03]
        debugRoot.addChild(dot)
      }
    }
  }
  func lasers() {
    for (y, z, color) in [
      (Float(0.9), Float(-0.03), NSColor.green), (Float(0.55), Float(0.04), NSColor.orange),
    ] {
      var m = UnlitMaterial(applyPostProcessToneMap: false)
      m.color = .init(tint: color)
      let core = ModelEntity(
        mesh: .generateBox(width: 3.05, height: 0.012, depth: 0.003), materials: [m])
      core.name = z < 0 ? "rear.core" : "front.core"
      core.position = [0, y, z]
      laserRoot.addChild(core)
      m.blending = .transparent(opacity: 0.25)
      let glow = ModelEntity(
        mesh: .generateBox(width: 3.05, height: 0.07, depth: 0.002), materials: [m])
      glow.name = z < 0 ? "rear.glow" : "front.glow"
      glow.position = [0, y, z - 0.001]
      laserRoot.addChild(glow)
    }
  }
  func explicitSort(_ enabled: Bool) {
    for pair in store.surfaces.values {
      for surface in pair {
        if enabled {
          surface.model.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        } else {
          surface.model.components.remove(ModelSortGroupComponent.self)
        }
      }
    }
    for child in laserRoot.children {
      if enabled {
        child.components.set(
          ModelSortGroupComponent(group: sortGroup, order: child.name.hasPrefix("rear") ? 0 : 2))
      } else {
        child.components.remove(ModelSortGroupComponent.self)
      }
    }
  }
  func render() async throws -> RenderedImage {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      do {
        try renderer.updateAndRender(
          deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume() })
      } catch { c.resume(throwing: error) }
    }
    renders += 1
    var bytes = [UInt8](repeating: 0, count: 1280 * 960 * 4)
    target.getBytes(
      &bytes, bytesPerRow: 1280 * 4,
      from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 960, depth: 1)),
      mipmapLevel: 0)
    return RenderedImage(bytes: Data(bytes), width: 1280, height: 960)
  }
  func screen(worldX: Double, worldY: Double, worldZ: Double = 0) -> (Int, Int) {
    let factor = 960 / (2 * tan(25 * Double.pi / 180) * (3.4 - worldZ))
    return (Int((640 + worldX * factor).rounded()), Int((480 - (worldY - 0.8) * factor).rounded()))
  }
  func screen(_ image: CopiedImage, id: PlayerID, tx: Double, ty: Double) throws -> (Int, Int) {
    let q = try image.placement.fullQuad(
      width: 512, height: 768, lane: spikeLayout.centerX(for: id))
    return screen(
      worldX: q.x + (512 - tx) / 512 * q.width, worldY: q.y + (768 - ty) / 768 * q.height)
  }
}
