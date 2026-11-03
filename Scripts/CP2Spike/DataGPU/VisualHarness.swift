import Foundation
import Observation
import RealityKit
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

@MainActor @Observable final class Demo {
  var store: UploadStore?
  var message = "Preparing isolated synthetic host…"
  var frame: UInt64 = 0
  var running = false
  private var producing = false
  #if CP2_ALPHA_REVIEW
    let producer = ReviewProducer()
    #if CP2_ALPHA_BASELINE
      let reviewEncoding = ReviewEncoding.baselineEncodedPremultiplied
      let reviewSorted = false
    #else
      let reviewEncoding = ReviewEncoding.straightDilated
      let reviewSorted = true
    #endif
  #else
    let producer = SyntheticProducer()
  #endif
  private var debugRoot = Entity()
  func install() throws -> Entity {
    let store = try UploadStore(readback: false)
    self.store = store
    let camera = PerspectiveCamera()
    camera.camera.fieldOfViewInDegrees = 50
    camera.position = [0, 0.8, 3.4]
    camera.look(at: [0, 0.8, 0], from: camera.position, relativeTo: nil)
    store.root.addChild(camera)
    // Light/dark backgrounds make transparent padding, alpha edges, and color discrepancies visible.
    for (x, color) in [
      (Float(-0.8), NSColor(white: 0.8, alpha: 1)), (Float(0.8), NSColor(white: 0.08, alpha: 1)),
    ] {
      var m = UnlitMaterial(applyPostProcessToneMap: false)
      m.color = .init(tint: color)
      let wall = ModelEntity(
        mesh: .generateBox(width: 1.6, height: 2.2, depth: 0.01), materials: [m])
      wall.position = [x, 0.8, -0.10]
      store.root.addChild(wall)
    }
    #if CP2_ALPHA_REVIEW
      let reviewSortGroup = ModelSortGroup()
      if reviewSorted {
        setReviewDepthWrites(store, enabled: false)
        for pair in store.surfaces.values {
          for surface in pair {
            surface.model.components.set(ModelSortGroupComponent(group: reviewSortGroup, order: 1))
          }
        }
      }
    #endif
    // Normal transparent sorting first: behind at y .9, front at y .55.
    for (y, z, color) in [
      (Float(0.9), Float(-0.03), NSColor.green), (Float(0.55), Float(0.04), NSColor.orange),
    ] {
      var core = UnlitMaterial(applyPostProcessToneMap: false)
      core.color = .init(tint: color)
      let beam = ModelEntity(
        mesh: .generateBox(width: 3.05, height: 0.012, depth: 0.003), materials: [core])
      beam.position = [0, y, z]
      store.root.addChild(beam)
      var glow = core
      glow.blending = .transparent(opacity: 0.25)
      let halo = ModelEntity(
        mesh: .generateBox(width: 3.05, height: 0.07, depth: 0.002), materials: [glow])
      halo.position = [0, y, z - 0.001]
      store.root.addChild(halo)
      #if CP2_ALPHA_REVIEW
        if reviewSorted {
          let order: Int32 = z < 0 ? 0 : 2
          for model in [beam, halo] {
            model.components.set(ModelSortGroupComponent(group: reviewSortGroup, order: order))
          }
        }
      #endif
    }
    store.root.addChild(debugRoot)
    store.onActivation = { [weak self] in self?.updateDebug() }
    return store.root
  }
  func updateDebug() {
    guard let store else { return }
    debugRoot.children.removeAll()
    for id in PlayerID.allCases {
      guard let snapshot = store.displayed[id], let g = snapshot.players[id]?.geometry,
        let cx = g.centerX.value, let crown = g.crownY.value, let sole = g.leftSoleY.value
      else { continue }
      let x = Float(2 * spikeLayout.centerX(for: id) - cx)
      var m = UnlitMaterial(applyPostProcessToneMap: false)
      m.color = .init(tint: id == .player1 ? NSColor.yellow : NSColor.cyan)
      for y in [crown, sole] {
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.017), materials: [m])
        dot.position = [x, Float(y), 0.06]
        debugRoot.addChild(dot)
      }
    }
  }
  func advance() async {
    guard let store, !store.busy, !producing else { return }
    producing = true
    defer { producing = false }
    do {
      frame += 1
      #if CP2_ALPHA_REVIEW
        let f = try await producer.produce(frame: frame, encoding: reviewEncoding)
      #else
        let f = try await producer.produce(frame: frame)
      #endif
      try store.offer(f)
      guard let token = try store.encodeAndSubmit() else { return }
      let r = try await store.result(token)
      message =
        "Frame \(frame) · \(r.activated.joined(separator:" + ")) · Data→staging \(String(format:"%.3f",r.stagingCopyMilliseconds)) ms · GPU \(String(format:"%.3f",r.gpuMilliseconds)) ms"
      #if CP2_ALPHA_REVIEW
        message += " · \(reviewEncoding.rawValue) · sorted=\(reviewSorted)"
      #endif
      let state: [String: Any] = [
        "frameID": frame,
        "displayed": store.displayed.mapValues { $0.frameID }.reduce(into: [String: UInt64]()) {
          $0[$1.key.rawValue] = $1.value
        }, "commits": store.commits, "completions": store.completions, "device": store.device.name,
      ]
      #if CP2_ALPHA_REVIEW
        let statePath =
          reviewSorted
          ? "/private/tmp/cp2-alpha/visual-after.json" : "/private/tmp/cp2-alpha/visual-before.json"
      #else
        let statePath = "/private/tmp/cp2-gpu/visual-state.json"
      #endif
      try JSONSerialization.data(withJSONObject: state, options: .prettyPrinted).write(
        to: URL(fileURLWithPath: statePath))
    } catch { message = "FAILED: \(error)" }
  }
  func burst() async {
    guard !running else { return }
    running = true
    defer { running = false }
    for _ in 0..<90 {
      if Task.isCancelled { return }
      await advance()
      // Cosmetic sampling cadence only, never a correctness assertion/timeout.
      try? await Task.sleep(for: .milliseconds(33))
    }
  }
}
struct SpikeView: View {
  @State private var demo = Demo()
  var body: some View {
    VStack(spacing: 8) {
      #if CP2_ALPHA_REVIEW
        Text(
          verbatim:
            "CP2 ALPHA REVIEW · \(demo.reviewEncoding.rawValue) · sorted=\(demo.reviewSorted)"
        )
        .font(.headline)
      #else
        Text("CP2 SYNTHETIC · P1 left / P2 right · mirrored full canvases").font(.headline)
      #endif
      Text(
        "Top source: yellow → green (displays green → yellow). Bottom: magenta → white (displays white → magenta)."
      )
      .font(.caption)
      RealityView { content in
        content.camera = .virtual
        do {
          content.add(try demo.install())
          await demo.advance()
        } catch { demo.message = "FAILED: \(error)" }
      }
      .frame(minWidth: 960, minHeight: 600)
      HStack {
        Button("Next frame") { Task { await demo.advance() } }.disabled(demo.running)
        Button("90-frame switching sample") { Task { await demo.burst() } }.disabled(demo.running)
        Text("Green behind at .90 · Orange in front at .55 · Dots = same-frame crown/sole").font(
          .caption)
      }
      Text(demo.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }.padding().background(Color.black).foregroundStyle(.white)
  }
}
@main struct CP2VisualApp: App {
  var body: some SwiftUI.Scene {
    WindowGroup("CP2 Synthetic Cutout Spike") { SpikeView() }.defaultSize(width: 1100, height: 760)
  }
}
