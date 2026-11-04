#if DEBUG
  import Foundation
  import Observation
  import SwiftUI
  import UIKit

  /// App-retained diagnostic controller. Views only observe it; they never allocate a camera.
  @MainActor @Observable final class LiveInputDiagnosticsModel {
    let camera: CameraPipeline
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
    private var startedAt: Double?
    private var endedAt: Double?
    var elapsedSeconds: Double? { startedAt.map { (endedAt ?? now()) - $0 } }
    private var startDuration: Double?
    private var stopDuration: Double?
    private var negotiated: CameraNegotiatedConfiguration?
    private var automatedRunStarted = false
    init(camera: CameraPipeline, now: @escaping @MainActor () -> Double = CameraHostClock.now) {
      self.camera = camera
      self.now = now
      observer = try? camera.observe { [weak self] state in
        guard let self else { return }
        if let negotiated = state.negotiated { self.negotiated = negotiated }
        let text =
          String(format: "%.6f", self.now()) + " " + String(describing: state.status)
        if self.history.count == 32 { self.history.removeFirst() }
        self.history.append(text)
        self.message = Self.explain(state.status)
        if case .failed = state.status { self.endedAt = self.now() }
      }
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
    func start(observeFor30Seconds: Bool = false) {
      guard control == nil, shutdown == nil, !runningObservation else { return }
      let token = UUID()
      controlToken = token
      negotiated = nil
      history.removeAll(keepingCapacity: true)
      startedAt = now()
      endedAt = nil
      startDuration = nil
      stopDuration = nil
      control = Task { [weak self] in
        guard let self else { return }
        await self.camera.stop()
        do {
          try Task.checkCancellation()
          try await self.camera.start(generation: UUID())
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
      let stopping = Task { await camera.stop() }
      shutdown = stopping
      await stopping.value
      endedAt = endedAt ?? now()
      stopDuration = now() - stopStart
      shutdown = nil
      await refresh()
      export()
    }
    func refresh() async {
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
        "Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue); CPU/RSS not measured by this screen.",
        latency("Callback total", statistics.callback),
        latency("Independent Data copy", statistics.copy),
        latency("Copy-complete → worker wait", statistics.wait),
        latency("Reconstruction sink", statistics.processing),
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
      lines.append(
        "Preview deferred: no session crosses the actor boundary. Proposed display mirror exactly once; Kevin review pending."
      )
      lines.append(
        "Recent lifecycle transitions (host seconds):\n" + history.joined(separator: "\n"))
      details = lines.joined(separator: "\n\n")
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
      guard !automatedRunStarted,
        ProcessInfo.processInfo.arguments.contains("--camera-diagnostics-run")
      else { return }
      automatedRunStarted = true
      start(observeFor30Seconds: true)
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
              Button("Start Camera") { model.start() }
              Button("Stop Camera") { Task { await model.stopAndExport() } }
              Button("Observe 30 seconds") { model.start(observeFor30Seconds: true) }
                .disabled(model.runningObservation)
            }.buttonStyle(.bordered)
            Text(model.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if model.lastExport != nil {
              Text("Numeric report saved in app Documents/LH13A2-observation.txt")
            }
            Text(
              "No visual preview. Source orientation and display mirroring need Kevin-reviewed validation."
            )
          }.padding()
        }
        .navigationTitle("LH-13A2 Camera")
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
          model.runExplicitLaunchExperimentIfRequested()
          while !Task.isCancelled {
            await model.refresh()
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
          }
        }
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
