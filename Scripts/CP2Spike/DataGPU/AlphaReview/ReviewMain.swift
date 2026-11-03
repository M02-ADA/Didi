import Foundation
import Metal
import RealityKit

nonisolated struct PatchObservation: Codable {
  let encoding: ReviewEncoding
  let background: Double
  let nearest: Bool
  let player: String
  let alpha: Double
  let sourceColor: [Double]
  let observed: [Double]
  let straightPrediction: [Double]
  let premultipliedPrediction: [Double]
}
@MainActor final class PresentationAudit {
  private(set) var ring: [[String: String]] = []
  private(set) var checked = 0
  func record(store: UploadStore, frame: SyntheticCutoutFrame, result: UploadResult) throws {
    try check(
      result.gpuSucceeded && !result.cancelled && result.activated.count == 2,
      "successful pair activation")
    for id in PlayerID.allCases {
      try check(store.displayed[id] == frame.bodySnapshot, "exact same-frame evidence")
      let pair = store.surfaces[id]!
      let front = store.front[id]!
      try check(
        pair[front].model.isEnabled && !pair[1 - front].model.isEnabled,
        "one initialized visible front")
      let q = try frame.players[id]!.placement.fullQuad(
        width: 512, height: 768, lane: spikeLayout.centerX(for: id))
      let position = pair[front].model.position
      let scale = pair[front].model.scale
      try check(
        abs(Double(position.x) - (q.x + q.width / 2)) < 1e-5
          && abs(Double(position.y) - (q.y + q.height / 2)) < 1e-5
          && abs(Double(scale.y) - q.height) < 1e-5, "same-frame placement")
    }
    checked += 1
    ring.append([
      "frameID": String(frame.bodySnapshot.frameID), "upload": result.token.uuidString,
      "p1Front": String(store.front[.player1]!), "p2Front": String(store.front[.player2]!),
    ])
    if ring.count > 16 { ring.removeFirst() }
  }
}
@MainActor final class WatchdogState { var fired = false }
@main struct ReviewMain {
  static func main() async {
    do {
      let folder = CommandLine.arguments.dropFirst().first ?? "/private/tmp/cp2-alpha/results"
      try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
      let store = try UploadStore(readback: false)
      let producer = ReviewProducer()
      let scene = try OffscreenScene(store: store)
      scene.renderer.cameraSettings.isToneMappingEnabled = CommandLine.arguments.contains(
        "--tone-map")
      store.onActivation = { [weak scene] in scene?.updateDots() }
      let initialMaterial = store.surfaces[.player1]![0].model.model!.materials[0] as! UnlitMaterial
      let defaultDepthWrites = initialMaterial.writesDepth
      var depthComparisons: [[String: Any]] = []
      var patches: [PatchObservation] = []
      var tests: [String] = []
      var sequence: UInt64 = 1
      // Independent input anchors: byte-domain premultiplication differs from linear-light premultiplication.
      try check(
        (encodeRGBA([1, 0, 0], alpha: 128.0 / 255, encoding: .baselineEncodedPremultiplied) >> 16)
          & 255 == 128, "legacy anchor")
      try check(
        (encodeRGBA([1, 0, 0], alpha: 128.0 / 255, encoding: .straight) >> 16) & 255 == 255,
        "straight anchor")
      try check(
        abs(
          Int(
            (encodeRGBA([1, 0, 0], alpha: 128.0 / 255, encoding: .linearPremultiplied) >> 16) & 255)
            - 188) <= 1, "linear premult anchor")
      tests.append(
        "independent correctly distinguished straight / encoded-premultiplied / linear-premultiplied byte anchors"
      )
      for encoding in ReviewEncoding.allCases {
        for background in [0.0, 1.0] {
          for nearest in [false, true] {
            let frame = try await producer.produce(frame: sequence, encoding: encoding, chart: true)
            try store.offer(frame)
            let token = try store.encodeAndSubmit()!
            let result = try await store.result(token)
            try check(result.gpuSucceeded, "chart GPU upload")
            setReviewFiltering(store, nearest: nearest)
            scene.background(background)
            var rendered = try await scene.render()
            // Bounded initialization settling, not a timing sleep/pass criterion.
            for _ in 0..<5 { rendered = try await scene.render() }
            let name =
              "chart-\(encoding.rawValue)-\(background == 0 ? "dark":"light")-\(nearest ? "nearest":"linear")"
            try rendered.writePNG(folder + "/" + name + ".png")
            for id in PlayerID.allCases {
              for y in [180, 290, 450] {
                for band in 0..<5 {
                  let x = 80 + (Double(band) + 0.5) * 70.4
                  let p = try scene.screen(frame.players[id]!, id: id, tx: x, ty: Double(y))
                  let observed = rendered.rgb(x: p.0, y: p.1)
                  let c = reviewColor(player: id, y: y)
                  let a = Double([0, 64, 128, 192, 255][band]) / 255
                  let packed = encodeRGBA(c, alpha: a, encoding: encoding)
                  let input = [
                    Double((packed >> 16) & 255) / 255, Double((packed >> 8) & 255) / 255,
                    Double(packed & 255) / 255,
                  ]
                  let straight = input.map {
                    toSRGB(toLinear($0) * a + toLinear(background) * (1 - a))
                  }
                  let premult = input.map {
                    min(1, toSRGB(toLinear($0) + toLinear(background) * (1 - a)))
                  }
                  patches.append(
                    PatchObservation(
                      encoding: encoding, background: background, nearest: nearest,
                      player: id.rawValue, alpha: a, sourceColor: [c.x, c.y, c.z],
                      observed: observed, straightPrediction: straight,
                      premultipliedPrediction: premult))
                }
              }
              // Outside the canvas's visible content must remain the actual background.
              let p = try scene.screen(frame.players[id]!, id: id, tx: 30, ty: 200)
              try check(
                rendered.rgb(x: p.0, y: p.1).allSatisfy { abs($0 - background) < 0.01 },
                "fully transparent padding")
            }
            sequence += 1
          }
        }
      }
      tests.append(
        "16 actual RealityKit chart renders: valid image uploads and transparent padding on light/dark backgrounds"
      )
      // Equivalent before/after body images: same source frame, placement, material, camera and lasers.
      scene.lasers()
      scene.laserRoot.isEnabled = true
      scene.debugRoot.isEnabled = true
      for encoding in [
        ReviewEncoding.baselineEncodedPremultiplied, .straight, .linearPremultiplied,
        .straightDilated,
      ] {
        let generation = UUID()
        store.setContext(spikeContext(generation: generation))
        let frame = try await producer.produce(frame: 1, generation: generation, encoding: encoding)
        try store.offer(frame)
        _ = try await store.result(store.encodeAndSubmit()!)
        scene.updateDots()
        setReviewFiltering(store, nearest: false)
        for background in [0.0, 1.0] {
          scene.background(background)
          for nearest in [false, true] {
            setReviewFiltering(store, nearest: nearest)
            _ = try await scene.render()
            let image = try await scene.render()
            let suffix = nearest ? "-nearest" : ""
            try image.writePNG(
              folder + "/body-\(encoding.rawValue)-\(background == 0 ? "dark":"light")\(suffix).png"
            )
            if encoding == .straightDilated && !nearest {
              setReviewDepthWrites(store, enabled: false)
              let noDepth = try await scene.render()
              try noDepth.writePNG(
                folder
                  + "/body-straightDilated-\(background == 0 ? "dark":"light")-no-depth-write.png")
              let q = try frame.players[.player1]!.placement.fullQuad(
                width: 512, height: 768, lane: -0.8)
              let p = scene.screen(worldX: q.x + 0.03, worldY: 0.925)
              depthComparisons.append([
                "background": background, "worldX": q.x + 0.03, "worldY": 0.925,
                "depthWrites": image.rgb(x: p.0, y: p.1),
                "noDepthWrites": noDepth.rgb(x: p.0, y: p.1),
              ])
              scene.explicitSort(true)
              let grouped = try await scene.render()
              try grouped.writePNG(
                folder + "/body-straightDilated-\(background == 0 ? "dark":"light")-grouped.png")
              scene.laserRoot.isEnabled = false
              let noLasers = try await scene.render()
              scene.laserRoot.isEnabled = true
              let opaque = scene.screen(worldX: -0.84, worldY: 0.925)
              let front = scene.screen(worldX: -0.84, worldY: 0.55, worldZ: 0.04)
              depthComparisons.append([
                "background": background, "groupedPadding": grouped.rgb(x: p.0, y: p.1),
                "opaqueNoLasers": noLasers.rgb(x: opaque.0, y: opaque.1),
                "opaqueUngrouped": noDepth.rgb(x: opaque.0, y: opaque.1),
                "opaqueGrouped": grouped.rgb(x: opaque.0, y: opaque.1),
                "frontGrouped": grouped.rgb(x: front.0, y: front.1),
                "frontNoLasers": noLasers.rgb(x: front.0, y: front.1),
              ])
              let opaqueGrouped = grouped.rgb(x: opaque.0, y: opaque.1)
              let opaqueControl = noLasers.rgb(x: opaque.0, y: opaque.1)
              try check(
                zip(opaqueGrouped, opaqueControl).allSatisfy { abs($0 - $1) < 0.008 },
                "rear glow must remain behind opaque player")
              try check(
                zip(grouped.rgb(x: p.0, y: p.1), noDepth.rgb(x: p.0, y: p.1)).allSatisfy {
                  abs($0 - $1) < 0.008
                }, "rear glow remains visible through padding")
              try check(
                grouped.rgb(x: front.0, y: front.1)[1] - noLasers.rgb(x: front.0, y: front.1)[1]
                  > 0.1, "front laser remains in front")
              scene.explicitSort(false)
              setReviewDepthWrites(store, enabled: defaultDepthWrites)
            }

          }
        }
      }
      tests.append(
        "sixteen equivalent source-frame-1 body/laser/dot renders preserve lane identity, dimensions and UVs"
      )
      tests.append(
        "compound depth-write-off plus explicit rear/player/front ModelSortGroup restores padding glow without rear bleed and preserves front beam"
      )
      try JSONSerialization.data(
        withJSONObject: [
          "depthComparisons": depthComparisons, "defaultMaterialWritesDepth": defaultDepthWrites,
        ], options: .prettyPrinted
      ).write(to: URL(fileURLWithPath: folder + "/depth.json"))
      scene.explicitSort(true)
      setReviewDepthWrites(store, enabled: false)
      scene.laserRoot.isEnabled = false
      scene.background(0.15)
      store.setContext(spikeContext())
      setReviewFiltering(store, nearest: false)
      let audit = PresentationAudit()
      var renderedChecks = 0
      var lastFrame: SyntheticCutoutFrame?
      for frameID in 1...64 {
        let frame = try await producer.produce(frame: UInt64(frameID), encoding: .straightDilated)
        try store.offer(frame)
        let result = try await store.result(store.encodeAndSubmit()!)
        try check(
          scene.debugFrames.values.allSatisfy { $0 == frame.bodySnapshot.frameID }
            && scene.debugFrames.count == 2,
          "overlay source IDs update inside synchronous activation callback")
        try audit.record(store: store, frame: frame, result: result)
        let rendered = try await scene.render()
        for id in PlayerID.allCases {
          var decoded: UInt64 = 0
          for bit in 0..<8 {
            let p = try scene.screen(
              frame.players[id]!, id: id, tx: 80 + (Double(bit) + 0.5) * 44, ty: 350)
            let rgb = rendered.rgb(x: p.0, y: p.1)
            if rgb.reduce(0, +) / 3 > 0.5 { decoded |= 1 << bit }
          }
          try check(
            decoded == frame.bodySnapshot.frameID,
            "rendered frame bars do not match placement/metadata")
          let p = try scene.screen(frame.players[id]!, id: id, tx: 200, ty: 200)
          let rgb = rendered.rgb(x: p.0, y: p.1)
          try check(
            id == .player1 ? rgb[0] > 0.9 && rgb[2] < 0.1 : rgb[2] > 0.9 && rgb[0] < 0.1,
            "rendered P1/P2 identity")
        }
        for id in PlayerID.allCases {
          let g = frame.bodySnapshot.players[id]!.geometry
          let x = 2 * spikeLayout.centerX(for: id) - g.centerX.value!
          for y in [g.crownY.value!, g.leftSoleY.value!] {
            let p = scene.screen(worldX: x, worldY: y, worldZ: 0.03)
            let rgb = rendered.rgb(x: p.0, y: p.1)
            try check(
              id == .player1 ? rgb[0] > 0.85 && rgb[1] > 0.85 : rgb[1] > 0.85 && rgb[2] > 0.85,
              "rendered dot: frame \(frameID) \(id) y \(y) sampled \(rgb)")
          }
        }
        renderedChecks += 1
        lastFrame = frame
      }
      tests.append(
        "64 stepped actual rendered frames: both source barcodes decoded; P1/P2 colors and same-frame full-quad state verified"
      )
      try check(audit.ring.count == 16 && audit.checked == 64, "bounded diagnostics")
      tests.append("presentation diagnostics bounded to last 16 entries")
      // Check real rendered old-front continuity while a hidden-back upload is GPU-gated.
      let heldFrame = try await producer.produce(frame: 65, encoding: .straightDilated)
      try store.offer(heldFrame)
      let gate = store.device.makeSharedEvent()!
      let heldToken = try store.encodeAndSubmit(gate: gate)!
      store.replayCompletionForTest(heldToken)
      try check(
        store.busy && store.displayed[.player1]?.frameID == 64, "test hook cannot forge a GPU fence"
      )
      let watchdogState = WatchdogState()
      let watchdog = Task { @MainActor in
        do {
          try await Task.sleep(for: .seconds(5))
          watchdogState.fired = true
          gate.signaledValue = 1
        } catch {}  // Cancellation is the normal successful path.
      }
      let heldImage = try await scene.render()
      watchdog.cancel()
      await watchdog.value
      gate.signaledValue = 1
      store.cancel(heldToken)
      let heldResult = try await store.result(heldToken)
      try check(
        !watchdogState.fired,
        "renderer stalled on hidden upload; watchdog released gate for safe failure cleanup")
      try check(
        heldResult.cancelled && heldResult.activated.isEmpty, "cancelled pair cannot activate")
      for id in PlayerID.allCases {
        for bit in 0..<8 {
          let p = try scene.screen(
            lastFrame!.players[id]!, id: id, tx: 80 + (Double(bit) + 0.5) * 44, ty: 350)
          let on = heldImage.rgb(x: p.0, y: p.1).reduce(0, +) / 3 > 0.5
          try check(on == (((64 >> bit) & 1) == 1), "held rendered surface is not frame 64")
        }
      }
      tests.append(
        "actual render while hidden upload is GPU-gated retains previous frame; cancellation and forged-live test callback never activate it"
      )
      let staleFrame = try await producer.produce(frame: 66, encoding: .straightDilated)
      try store.offer(staleFrame)
      let staleGate = store.device.makeSharedEvent()!
      let staleToken = try store.encodeAndSubmit(gate: staleGate)!
      let newGeneration = UUID(uuidString: "00000000-0000-0000-0000-0000000002A2")!
      store.setContext(spikeContext(generation: newGeneration))
      scene.updateDots()
      try check(
        store.displayed.isEmpty && scene.debugRoot.children.isEmpty && store.busy,
        "context invalidation is immediate; GPU stays pinned")
      staleGate.signaledValue = 1
      try check(
        try await store.result(staleToken).activated.isEmpty, "stale upload cannot activate")
      let hiddenImage = try await scene.render()
      for id in PlayerID.allCases {
        let p = try scene.screen(lastFrame!.players[id]!, id: id, tx: 200, ty: 200)
        try check(
          hiddenImage.rgb(x: p.0, y: p.1).allSatisfy { abs($0 - 0.15) < 0.015 },
          "stale surface remained rendered")
      }
      tests.append(
        "generation invalidation suppresses stale completed uploads, image visibility and old debug geometry"
      )
      let data = try JSONEncoder().encode(patches)
      let report: [String: Any] = [
        "device": store.device.name, "platform": "native macOS offscreen RealityRenderer",
        "toneMappingEnabled": scene.renderer.cameraSettings.isToneMappingEnabled,
        "defaultMaterialWritesDepth": defaultDepthWrites, "depthComparisons": depthComparisons,
        "patches": try JSONSerialization.jsonObject(with: data), "testsPassed": tests.count,
        "testsFailed": 0, "tests": tests, "renderedFrameChecks": renderedChecks,
        "activationChecks": audit.checked, "last16Activations": audit.ring,
        "renderCalls": scene.renders, "commits": store.commits, "completions": store.completions,
      ]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: folder + "/review.json"))
      print(
        "PASS \(tests.count) review groups, \(renderedChecks) checked rendered frames, \(patches.count) flat-patch measurements"
      )
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(1)
    }
  }
}
