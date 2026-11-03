import Foundation
import Metal
import RealityKit

@main struct DeviceProbe {
  static func main() throws {
    print("defaultDevice=\(MTLCreateSystemDefaultDevice()?.name ?? "nil")")
    let descriptor = LowLevelTexture.Descriptor(
      pixelFormat: .bgra8Unorm_srgb, width: 512, height: 768,
      textureUsage: [.shaderRead, .renderTarget])
    let surface = try LowLevelTexture(descriptor: descriptor)
    let backing = surface.read()
    print(
      "RealityKit backing device=\(backing.device.name) registryID=\(backing.device.registryID) format=\(backing.pixelFormat.rawValue)"
    )
  }
}
