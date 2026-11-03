import AppKit
import Foundation
import Metal
import RealityKit

@main struct RenderProbe {
  static func main() async throws {
    let store = try UploadStore(readback: false)
    let renderer = try RealityRenderer()
    let camera = PerspectiveCamera()
    camera.position = [0, 0.8, 3.4]
    camera.look(at: [0, 0.8, 0], from: camera.position, relativeTo: nil)
    renderer.entities.append(store.root)
    store.root.addChild(camera)
    renderer.activeCamera = camera
    renderer.cameraSettings.isToneMappingEnabled = false
    renderer.cameraSettings.colorBackground = .color(CGColor(gray: 1, alpha: 1))
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm_srgb, width: 1024, height: 768, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    let target = store.device.makeTexture(descriptor: desc)!
    let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
    let producer = SyntheticProducer()
    let f = try await producer.produce(frame: 1)
    try store.offer(f)
    _ = try await store.result(store.encodeAndSubmit()!)
    for _ in 0..<10 {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        do {
          try renderer.updateAndRender(
            deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in continuation.resume() })
        } catch { continuation.resume(throwing: error) }
      }
    }
    var bytes = [UInt8](repeating: 0, count: 1024 * 768 * 4)
    target.getBytes(
      &bytes, bytesPerRow: 4096,
      from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1024, height: 768, depth: 1)),
      mipmapLevel: 0)
    let image = CGImage(
      width: 1024, height: 768, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4096,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: [
        .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
      ], provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(
      to: URL(fileURLWithPath: "/private/tmp/cp2-alpha/probe.png"))
    print("Rendered", store.device.name)
  }
}
