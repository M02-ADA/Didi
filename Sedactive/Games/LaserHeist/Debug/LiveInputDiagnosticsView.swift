#if DEBUG
  import Foundation
  import Observation
  import SwiftUI
  import UIKit

  /// App-retained diagnostic controller. Views only observe it; they never allocate a camera.
  @MainActor @Observable final class LiveInputDiagnosticsModel {
    let camera: CameraPipeline
    let visionPreviewEnabled: Bool
    @ObservationIgnored private let bodyInput: BodyInputService?
    private(set) var visionRunStarted = false
    private(set) var visionDetails = "Vision provider has not started"
    private(set) var permission = "Not checked"
    private(set) var details = "No observations yet"
    private(set) var message = "Camera is stopped"
    private(set) var lastExport: URL?
    private(set) var runningObservation = false
    private var control: Task<Void, Never>?
    private var controlToken: UUID?
    private var sample: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private let now: @MainActor () -> Double
    private var observer: UUID?
    private var history: [String] = []
    @ObservationIgnored private var previewWorker: Task<Void, Never>?
    private var previewVisible = false
    private(set) var previewEnabled = ProcessInfo.processInfo.arguments.contains(
      "--camera-preview-on")
    private(set) var previewFrame: CameraPreviewFrame?
    @ObservationIgnored private var rssFirst: UInt64?
    @ObservationIgnored private var rssLast: UInt64?
    @ObservationIgnored private var rssPeak: UInt64?
    private var startedAt: Double?
    private var endedAt: Double?
    var elapsedSeconds: Double? { startedAt.map { (endedAt ?? now()) - $0 } }
    private var startDuration: Double?
    private var stopDuration: Double?
    private var negotiated: CameraNegotiatedConfiguration?
    private var automatedRunStarted = false
    init(camera: CameraPipeline, bodyInput: BodyInputService? = nil,
      visionPreview: Bool = VisionPreviewDiagnostics.enabled(bundleID: Bundle.main.bundleIdentifier,
        arguments: ProcessInfo.processInfo.arguments),
      now: @escaping @MainActor () -> Double = CameraHostClock.now) {
      self.camera = camera
      self.bodyInput = bodyInput
      visionPreviewEnabled = visionPreview && bodyInput != nil
      self.now = now
      let preview = camera.frames.preview
      previewWorker = Task { @concurrent in await preview.run() }
      observer = try? camera.observe { [weak self] state in
        guard let self else { return }
        if let negotiated = state.negotiated { self.negotiated = negotiated }
        let text =
          String(format: "%.6f", self.now()) + " " + String(describing: state.status)
        if self.history.count == 32 { self.history.removeFirst() }
        self.history.append(text)
        self.message = Self.explain(state.status)
        if case .running = state.status {} else { self.previewFrame = nil }
        if case .failed = state.status { self.endedAt = self.now() }
      }
    }
    deinit { previewWorker?.cancel() }
    func setPreviewVisible(_ visible: Bool) {
      previewVisible = visible
      camera.frames.preview.setEnabled(visible && previewEnabled)
      if !visible { previewFrame = nil }
    }
    func setPreviewEnabled(_ enabled: Bool) {
      previewEnabled = enabled
      camera.frames.preview.setEnabled(previewVisible && enabled)
      if !enabled { previewFrame = nil }
    }
    func refreshPreview() {
      let preview = camera.frames.preview
      if let latest = preview.takeLatest(at: now()) { previewFrame = latest }
      if let frame = previewFrame, !preview.isCurrent(frame, at: now()) { previewFrame = nil }
    }
    static func explain(_ status: CameraPipelineStatus) -> String {
      switch status {
      case .stopped: return "Stopped — Start creates a new generation."
      case .requestingPermission:
        return "Waiting for camera authorization. Stop invalidates this request."
      case .configuring: return "Configuring front camera off MainActor."
      case .running:
        return "Session running — delivered-frame measurements below confirm actual output."
      case .interrupted(let reason):
        return
          "Camera interrupted (reason \(reason.map(String.init) ?? "not supplied")). Await source recovery or Stop."
      case .failed(let failure):
        switch failure {
        case .permissionDenied:
          return "Camera denied. Enable Camera in Settings → Sedactive, return, then Start."
        case .permissionRestricted:
          return "Camera restricted by device policy. Review restrictions before retrying."
        case .unsupported(let requirement, let alternatives):
          return
            "Unsupported: \(requirement). \(alternatives.joined(separator: "; ")) No fallback was applied. If Center Stage is active, turn it off in the system camera controls and retry."
        case .geometryChanged:
          return
            "Geometry changed (rotation, zoom, framing or format). Restore mounted landscape configuration, Stop, then Start."
        case .clockNormalizationFailure:
          return
            "Source synchronization clock unavailable/changed/invalid. Stop and retry; do not substitute arrival time."
        default:
          return "Capture failed: \(failure). Stop before a new generation; report this failure."
        }
      }
    }
    func armTracking() {
      do { _ = try camera.armBinding(request: camera.makeBindingRequest()) }
      catch { message = "Binding refused: \(error). Full rebind starts a new capture generation." }
    }
    func cancelTracking() { camera.cancelBinding() }
    @discardableResult func rebindTracking() -> Task<Void, Never>? {
      guard control == nil, shutdown == nil else { return nil }
      guard !visionPreviewEnabled else {
        message = "Vision preview uses one provider session per launch. Stop and relaunch for a new generation."
        return nil
      }
      let request: CameraBindingRequest
      do { request = try camera.makeBindingRequest() } // stamp the actual button intent, not a later Task
      catch { message = "Full rebind refused: \(error)"; return nil }
      let token = UUID()
      controlToken = token
      let task = Task { [weak self] in
        guard let self else { return }
        defer { if self.controlToken == token { self.control = nil; self.controlToken = nil } }
        do { try await self.camera.requestFullRebind(request: request) }
        catch { if self.controlToken == token { self.message = "Full rebind refused: \(error)" } }
      }
      control = task
      return task
    }
    @discardableResult func start(observeFor30Seconds: Bool = false) -> Task<Void, Never>? {
      guard control == nil, shutdown == nil, !runningObservation else { return nil }
      if visionPreviewEnabled {
        guard !visionRunStarted else { message = "Relaunch the preview app for another camera run."; return nil }
        visionRunStarted = true
      }
      let token = UUID()
      controlToken = token
      negotiated = nil
      history.removeAll(keepingCapacity: true)
      rssFirst = nil
      rssLast = nil
      rssPeak = nil
      startedAt = now()
      endedAt = nil
      startDuration = nil
      stopDuration = nil
      control = Task { [weak self] in
        guard let self else { return }
        await self.camera.stop()
        do {
          try Task.checkCancellation()
          if self.visionPreviewEnabled, let provider = self.bodyInput {
            try await provider.start(configuration: .init(sessionGeneration: UUID(), calibrations: [:],
              playerPlaneLayout: .init(leftCenterX: -1, rightCenterX: 1, gameUnitsPerImageHeight: 2)))
          } else { try await self.camera.start(generation: UUID()) }
          self.startDuration = self.startedAt.map { self.now() - $0 }
          if observeFor30Seconds, self.controlToken == token, !Task.isCancelled {
            self.runningObservation = true
            self.sample = Task { [weak self] in
              do { try await Task.sleep(for: .seconds(30)) } catch { return }
              await self?.stopAndExport(reason: "30-second observation complete")
            }
          }
        } catch {
          // Preserve the pipeline's explicit failure, including unsupported hardware.
        }
        if self.controlToken == token {
          self.control = nil
          await self.refresh()
          if case .failed = self.camera.status { self.export() }
        }
      }
      return control
    }
    func stopAndExport(reason: String = "explicit stop/close") async {
      if let shutdown {
        await shutdown.value
        return
      }
      // Close/onDismiss/background may all request cleanup. Preserve the first completed stop.
      guard camera.state.context != nil || control != nil else {
        await refresh()
        return
      }
      if history.count == 32 { history.removeFirst() }
      history.append(String(format: "%.6f", now()) + " diagnostics shutdown requested: " + reason)
      controlToken = nil
      control?.cancel()
      control = nil
      sample?.cancel()
      sample = nil
      runningObservation = false
      let stopStart = now()
      let camera = self.camera
      let provider = visionPreviewEnabled ? bodyInput : nil
      let stopping = Task {
        if let provider { await provider.stop() } else { await camera.stop() }
      }
      shutdown = stopping
      await stopping.value
      endedAt = endedAt ?? now()
      stopDuration = now() - stopStart
      shutdown = nil
      await refresh()
      export()
    }
    func refresh() async {
      if let rss = CameraPreviewProcessMemory.residentBytes() {
        rssFirst = rssFirst ?? rss
        rssLast = rss
        rssPeak = max(rssPeak ?? rss, rss)
      }
      permission = String(describing: await camera.permissionStatus())
      let statistics = camera.frames.metrics.snapshot
      let usage = camera.frames.usage
      let drops = camera.frames.diagnostics
      func number(_ n: Double?) -> String { n.map { String(format: "%.3f", $0) } ?? "not measured" }
      func latency(_ name: String, _ value: CameraLatencySummary) -> String {
        "\(name): n=\(value.count), window=\(value.retainedSamples), p50=\(number(value.p50MS)) ms, p95=\(number(value.p95MS)) ms"
      }
      func rate(_ count: UInt64) -> String {
        guard let span = statistics.sourceSpanSeconds, span > 0 else { return "not measured" }
        return number(Double(count) / span)
      }
      var lines = [
        "Capture diagnostics only — not calibrated gameplay evidence.",
        "Permission: \(permission)", "Status: \(message)",
        "Start-request interval (frozen after shutdown/failure): \(number(elapsedSeconds)) s",
        "Start request → native ready (includes authorization): \(number(startDuration.map { $0 * 1000 })) ms; awaited shutdown: \(number(stopDuration.map { $0 * 1000 })) ms",
        statistics.configurationDetails,
        "Generation: \(statistics.context?.generation.uuidString ?? "none")",
        "Epoch: \(statistics.context?.epoch.uuidString ?? "none")",
        "Geometry revision: \(statistics.context.map { String($0.geometryRevision) } ?? "none")",
        "Delivered / admitted / completed: \(statistics.delivered) / \(statistics.admitted) / \(statistics.processed)",
        "Input FPS (capture timestamps): \(number(statistics.sourceFPS)); sink FPS: \(number(statistics.processingFPS))",
        "Admission / replacement mean rate: \(rate(statistics.admitted)) / \(rate(drops.superseded)) per capture-span second",
        "Observed callbacks / AV drops: \(drops.sourceCallbacks) / \(drops.avDrops)",
        "Pending replacements / capacity drops / stale drops: \(drops.superseded) / \(drops.capacityDrops) / \(drops.staleDrops)",
        "Construction rejects / owner-byte budget rejects / sink rejects: \(drops.constructionDrops) / \(drops.budgetDrops) / \(statistics.processingRejects)",
        "Raw owners current/peak: \(usage.frames)/\(usage.peakFrames); raw bytes current/peak: \(usage.bytes)/\(usage.peakBytes) (cap 12582912)",
        "Workspace bytes current/peak: \(statistics.workspaceBytes)/\(statistics.peakWorkspaceBytes) (cap 4194304)",
        "Owned pixel bytes current/peak: \(statistics.ownedPixelBytes)/\(statistics.peakOwnedPixelBytes). This excludes framework/allocator memory; not process RSS.",
        "Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue); CPU utilization not measured; process RSS sampled separately below.",
        latency("Callback total", statistics.callback),
        latency("Independent Data copy", statistics.copy),
        latency("Copy-complete → worker wait", statistics.wait),
        latency("Total processing sink (copy + optional Vision)", statistics.processing),
        latency("Capture → sink completion", statistics.endToEnd),
      ]
      if let frame = statistics.lastFrame {
        let d = frame.descriptor
        lines.append(
          "Last validated frame: \(frame.frameID), \(d.width)x\(d.height), stride \(d.bytesPerRow), bytes \(d.byteCount), format 0x\(String(d.pixelFormat, radix: 16)) (BGRA)"
        )
        lines.append(
          "capturedAt host seconds: \(String(format: "%.6f", frame.capturedAt)); host age: \(number(CameraHostClock.now() - frame.capturedAt)) s; clock normalization succeeded for this frame"
        )
        lines.append(
          "Source rotation \(frame.rotationAngle)°, mirrored \(frame.mirrored). Last-frame metadata remains visible after Stop; it is not a live frame."
        )
      } else {
        lines.append("No validated camera frame / host timestamp yet.")
      }
      if let negotiated {
        lines.append(
          "Native: \(negotiated.nativeWidth)x\(negotiated.nativeHeight), requested output \(negotiated.outputWidth)x\(negotiated.outputHeight), preset \(negotiated.sessionPreset)"
        )
        lines.append(
          "Center Stage active \(negotiated.centerStageActive); stabilization \(negotiated.stabilizationEnabled); no mirrored source"
        )
      }
      let tracking = camera.frames.tracking.snapshot
      lines.append("B2b EXPERIMENTAL DIAGNOSTICS ONLY — no calibrated gameplay or identity guarantee.")
      lines.append("Policy: \(tracking.policyVersion); control revision \(tracking.revision); request \(tracking.requestID?.uuidString ?? "none"); status \(tracking.reason)")
      lines.append("Tracking accepted / rejected / refused: \(tracking.accepted) / \(tracking.rejected) / \(tracking.refusals); expiry / invalidation: \(tracking.expiries) / \(tracking.invalidations); watermark \(tracking.watermark)")
      lines.append("Stale source/control/order/age rejects: \(tracking.staleRejected); last capture → final tracking commit: \(number(tracking.captureToCommitAge)) s")
      lines.append("Last accepted pair coverage: \(tracking.mutualCoreCount.map(String.init) ?? "unavailable")/4 (Option A; not identity confidence)")
      if let ack = tracking.acknowledgment {
        lines.append("Atomic binding acknowledgment #\(tracking.acknowledgments): request \(ack.requestID), revision \(ack.source.controlRevision), frame \(ack.source.frameID), capturedAt \(ack.source.capturedAt)")
      }
      if let current = tracking.latest {
        if let source = current.source {
          lines.append("Tracking source: generation \(source.context.generation), epoch \(source.context.epoch), geometry \(source.context.geometryRevision), frame \(source.frameID), control \(source.controlRevision), capturedAt \(source.capturedAt), age \(number(now() - source.capturedAt)) s; evaluatedAt \(number(current.evaluatedAt))")
        }
        for (label, slot) in [("P1", current.player1), ("P2", current.player2)] {
          lines.append("\(label): \(slot.state.rawValue) / \(slot.reason.rawValue), frame-local candidate \(slot.candidateID.map(String.init) ?? "none"), rebind \(slot.requiresRebind), last confirmed \(number(slot.lastConfirmedAt))")
        }
      } else { lines.append("No current authorized tracking result.") }
      let rawPose = camera.frames.poses.snapshot
      let poseStats = rawPose.statistics
      lines.append("LH-13B1 RAW VISION ONLY — temporary candidates; no P1/P2 binding or calibration.")
      lines.append("Pose successful / rejected / failures: \(poseStats.completed) / \(poseStats.rejected) / \(poseStats.failures); Vision result FPS: \(number(poseStats.framesPerSecond))")
      lines.append("Pose count buckets zero / one / two / more: \(poseStats.counts.map(String.init).joined(separator: "/"))")
      lines.append(latency("Vision inference", poseStats.inference.summary))
      lines.append(latency("Capture → pose result", poseStats.age.summary))
      if let result = rawPose.latest {
        let source = result.source
        lines.append("Latest raw pose frame \(source.frameID), generation \(source.context.generation), epoch \(source.context.epoch), geometry \(source.context.geometryRevision), \(source.descriptor.width)×\(source.descriptor.height); capturedAt \(number(source.capturedAt)); current age \(number(now() - source.capturedAt)) s; source rotation \(source.rotationAngle)°, mirrored \(source.mirrored)")
        lines.append("Vision observations \(result.observationCount); retained candidates \(result.frame.candidates.count) (cap \(PoseEstimator.maximumCandidates)); invalid/unobserved returned joints \(result.invalidJointCount)")
        for candidate in result.frame.candidates {
          let confidences = candidate.joints.values.map(\.confidence)
          let mean = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
          // No coordinates are persisted. Low-confidence is a diagnostic label, not a gameplay threshold.
          let low = confidences.filter { $0 < 0.3 }.count
          lines.append("Frame-local candidate \(candidate.candidateID): present \(candidate.joints.count)/\(PoseEstimator.joints.count), missing \(PoseEstimator.joints.count - candidate.joints.count), low-confidence (<0.3, diagnostic only) \(low), confidence min/mean/max \(number(confidences.min()))/\(number(mean))/\(number(confidences.max()))")
        }
      } else { lines.append("No compatible raw pose result. Camera running does not imply pose/calibration readiness.") }
      let preview = camera.frames.preview
      let ps = preview.statistics
      let pu = preview.budget.usage
      lines.append(
        "Preview enabled/visible: \(previewEnabled)/\(previewVisible); admitted/converted/presented: \(ps.admitted)/\(ps.converted)/\(ps.presented); presented FPS: \(number(ps.displayFPS))"
      )
      lines.append(
        "Preview busy/cadence/budget/context/stale/failure drops: \(ps.busyDrops)/\(ps.cadenceDrops)/\(ps.budgetDrops)/\(ps.contextDrops)/\(ps.staleDrops)/\(ps.failures)"
      )
      lines.append(
        "Preview provider-backed bytes current/peak: \(pu.bytes)/\(pu.peakBytes), backing count: \(pu.backings), cap \(preview.configuration.maximumBytes)"
      )
      lines.append(
        "Process RSS bytes first/last/peak: \(rssFirst.map(String.init) ?? "unavailable")/\(rssLast.map(String.init) ?? "unavailable")/\(rssPeak.map(String.init) ?? "unavailable"). Sampled at numeric refresh; includes framework/renderer memory."
      )
      lines.append(latency("Preview independent copy", ps.copying.summary))
      lines.append(latency("Preview conversion (lazy image creation)", ps.conversion.summary))
      lines.append(latency("Preview age at MainActor acceptance", ps.age.summary))
      lines.append(
        "Preview is mirrored exactly once; full source canvas, no capture rotation reapplied. Optical/device review still required. Core Graphics decoding/display costs are outside conversion timing."
      )
      lines.append(
        "Recent lifecycle transitions (host seconds):\n" + history.joined(separator: "\n"))
      if visionPreviewEnabled {
        visionDetails = VisionPreviewDiagnostics.text(body: camera.frames.tracking.readBody(),
          mask: camera.frames.tracking.readVisionPreviewMask())
        lines.append(visionDetails)
      }
      details = lines.joined(separator: "\n\n")
    }
    func collectStandingCandidate() {
      guard visionPreviewEnabled, let bodyInput else { return }
      do { _ = try bodyInput.requestStandingCalibration(id: UUID()) }
      catch { message = "Standing collection refused: \(error). Requires a current confirmed pair; no retry was issued." }
    }
    func cancelStandingCollection() {
      guard visionPreviewEnabled, let bodyInput, let request = bodyInput.calibrationProgress.request else { return }
      bodyInput.cancelStandingCalibration(request)
    }
    func export() {
      do {
        let directory = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true)
        let url = directory.appending(path: "LH13A2-observation.txt")
        try details.write(to: url, atomically: true, encoding: .utf8)
        lastExport = url  // One overwritten numeric report. No images or per-frame records.
      } catch { message = "Diagnostics export failed: \(error.localizedDescription)" }
    }
    func runExplicitLaunchExperimentIfRequested() {
      guard !visionPreviewEnabled, !automatedRunStarted,
        ProcessInfo.processInfo.arguments.contains("--camera-diagnostics-run")
      else { return }
      automatedRunStarted = true
      start(observeFor30Seconds: true)
    }
  }

  private struct CameraDiagnosticPreviewPanel: View {
    let frame: CameraPreviewFrame?
    let enabled: Bool
    var body: some View {
      GeometryReader { geometry in
        ZStack {
          Color.black
          if let frame {
            let d = frame.metadata.descriptor
            let rect = CameraPreviewLayout.rect(
              image: CGSize(width: d.width, height: d.height), in: geometry.size)
            Image(decorative: frame.image, scale: 1, orientation: .up)
              .resizable().interpolation(.medium)
              .frame(width: rect.width, height: rect.height)
              .scaleEffect(x: -1, y: 1)
              .position(x: rect.midX, y: rect.midY)
            Rectangle().stroke(.yellow, lineWidth: 1)
              .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
          } else {
            Text(enabled ? "No current compatible preview" : "Preview disabled")
              .foregroundStyle(.white)
          }
        }.clipped().transaction { $0.animation = nil }
      }
    }
  }

  struct LiveInputDiagnosticsView: View {
    let model: LiveInputDiagnosticsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("Capture diagnostics only — not calibrated gameplay evidence.").font(.headline)
            Text(model.message)
            HStack {
              Button(model.visionPreviewEnabled ? "Start Vision pipeline" : "Start Camera") { model.start() }
                .disabled(model.visionPreviewEnabled && model.visionRunStarted)
              Button("Stop Camera") { Task { await model.stopAndExport() } }
              if !model.visionPreviewEnabled {
                Button("Observe 30 seconds") { model.start(observeFor30Seconds: true) }
                  .disabled(model.runningObservation)
              }
            }.buttonStyle(.bordered)
            HStack {
              Button("Arm pair binding") { model.armTracking() }
              Button("Cancel binding") { model.cancelTracking() }
              if !model.visionPreviewEnabled {
                Button("Full rebind (restart camera)") { model.rebindTracking() }
              }
            }.buttonStyle(.bordered)
            if model.visionPreviewEnabled {
              HStack {
                Button("Collect standing candidate") { model.collectStandingCandidate() }
                Button("Cancel calibration") { model.cancelStandingCollection() }
              }.buttonStyle(.bordered)
              Text(model.visionDetails).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            }
            Text("P1 = canonical image-right (mirrored preview-left). Binding is diagnostic only.")
            Toggle(
              "DEBUG preview (max 5 Hz)",
              isOn: Binding(get: { model.previewEnabled }, set: { model.setPreviewEnabled($0) }))
            CameraDiagnosticPreviewPanel(frame: model.previewFrame, enabled: model.previewEnabled)
              .frame(height: 260)
            if let frame = model.previewFrame {
              Text(
                "Preview frame \(frame.metadata.frameID) • geometry \(frame.metadata.context.geometryRevision) • \(frame.metadata.descriptor.width)×\(frame.metadata.descriptor.height)"
              )
              .font(.caption.monospacedDigit())
            }
            Text(model.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Save numeric snapshot") {
              Task {
                await model.refresh()
                model.export()
              }
            }
            if model.lastExport != nil {
              Text("Numeric report saved in app Documents/LH13A2-observation.txt")
            }
            Text(
              "DEBUG preview only. Physical orientation/mirroring still requires Edo and Kevin review."
            )
          }.padding()
        }
        .navigationTitle(model.visionPreviewEnabled ? "Vision E03–E06 Preview" : "LH-13A2 Camera")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Close") {
              Task {
                await model.stopAndExport()
                dismiss()
              }
            }
          }
        }
        .task {
          model.setPreviewVisible(true)
          model.runExplicitLaunchExperimentIfRequested()
          var refreshCount = 0
          while !Task.isCancelled {
            model.refreshPreview()
            if refreshCount % 5 == 0 { await model.refresh() }
            refreshCount += 1
            do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
          }
        }
        .onDisappear { model.setPreviewVisible(false) }
        .onChange(of: phase) { _, newPhase in
          // Debug capture policy only. Gameplay recovery remains Jevon's responsibility.
          if newPhase == .background {
            Task { await model.stopAndExport(reason: "scene background") }
          }
        }
        .interactiveDismissDisabled()
      }
    }
  }
#endif
