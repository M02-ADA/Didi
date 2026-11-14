#if DEBUG
import SwiftUI

/// Existing in-game DEBUG setup only. No stream subscription, calibration authority or disk output.
struct AnatomyEvidenceInspectorView: View {
  let model: LiveAvatarSmokeModel
  let onStop: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var selectedPlayer: PlayerID = .player1
  @State private var selectedMeasurement: AnatomyInspectionMeasurement = .crown
  @State private var drawingRegion = true
  @State private var mirrored = false
  @State private var showMask = false
  @State private var error: String?
  private var gate: CameraTrackingGate { model.service.camera.frames.tracking }
  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 0.2)) { _ in
        let inspection = gate.readAnatomyInspection()
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            Text("EXPERIMENTAL · frozen same-frame comparison · NO VALIDATION OR GAMEPLAY")
              .font(.headline).foregroundStyle(.orange)
            setupControls(inspection)
            Text("Inspection-owned images: \(gate.anatomyInspectionBudget.usage.bytes) B / 8 MiB. One frame only; credit remains charged while the UI retains its image.")
            if let error { Text(error).foregroundStyle(.orange) }
            if let failure = inspection.lastFailure {
              Text("Inspection \(failure.rawValue): STOP and report. No automatic retry or replacement frame.").foregroundStyle(.orange)
            }
            if let frame = inspection.frame {
              provenance(frame)
              HStack {
                Toggle("Display mirror \(mirrored ? "ON" : "OFF")", isOn: $mirrored)
                Toggle("Native mask (normalized mapping under evaluation)", isOn: $showMask)
                  .disabled(!inspection.revealed || frame.mask == nil)
              }
              Text("Before predictions are revealed: draw an independent full-body box around each labelled person, then mark their crown and left/right sole on the CAMERA IMAGE. Boxes must not overlap. Left/right means the participant’s own left/right. No point is pre-filled. If anatomy/person identity is unclear, mark unavailable or discard the frame.")
              HStack {
                Picker("Person", selection: $selectedPlayer) {
                  ForEach(PlayerID.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Draw player reference box", isOn: $drawingRegion)
                Picker("Reference", selection: $selectedMeasurement) {
                  ForEach(AnatomyInspectionMeasurement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
              }.disabled(inspection.revealed)
              AnatomyInspectionCanvas(frame: frame, state: inspection, mirrored: mirrored,
                showMask: showMask && inspection.revealed) { a, b in
                perform {
                  guard !inspection.revealed, let player = frame.players[selectedPlayer] else { throw AnatomyInspectionError.incompatible }
                  if drawingRegion {
                    try gate.setAnatomyReferenceRegion(inspection: frame.ticket.id, source: frame.source,
                      player: selectedPlayer, candidateID: player.candidateID, a: a, b: b)
                  } else { try mark(frame, point: b) }
                }
              }.frame(height: 350)
              HStack {
                Button("Reference unavailable / cannot identify") { perform { try mark(frame, point: nil) } }
                  .disabled(inspection.revealed)
                Button("Reveal Y comparisons (\(inspection.references.count)/6 marked)") {
                  perform { try gate.revealAnatomyComparisons() }
                }.disabled(inspection.revealed || inspection.references.count != 6)
                Button("Discard frame / incorrect association") { gate.discardAnatomyInspection(); showMask = false }
              }.buttonStyle(.bordered)
              Text("Prediction lines are Y-only estimates. Green reference dots are evaluator marks. No predicted X exists: Euclidean XY error is NOT MEASURABLE. Line width comes from the reference box, not predicted anatomy.")
              evidenceRows(frame, inspection: inspection)
            } else {
              Text(inspection.ticket == nil ? "No retained frame. Confirm the genuine pair, begin one standing collection, then explicitly request ONE frame."
                : "Waiting for the next admitted mask frame. No extra request or camera is started. Expires with the original 30-second request deadline.")
            }
            summaries(inspection)
            Text("All results remain experimental. Missing/low-confidence evidence remains unavailable. Aggregate confidence, anatomical accuracy, accepted calibration, airborne and gameplay authority are not supplied by this inspector.")
          }.font(.caption).padding()
        }
      }
      .navigationTitle("Same-frame anatomy evidence")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close / release frame") { gate.discardAnatomyInspection(); dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("STOP CAMERA") { gate.discardAnatomyInspection(); onStop(); dismiss() }
        }
      }
    }.privacySensitive()
      .onDisappear { gate.discardAnatomyInspection() }
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
        gate.discardAnatomyInspection(); dismiss()
      }
  }
  private func setupControls(_ value: AnatomyInspectionState) -> some View {
    VStack(alignment: .leading) {
      let progress = model.service.calibrationProgress
      Text("Existing collection: \(progress.phase.rawValue) · \(progress.sampleCount)/10. \(progress.reason)")
      HStack {
        Button("Confirm genuine P1/P2") {
          perform {
            guard let setup = model.session?.setup else { throw AnatomyInspectionError.inactive }
            try setup.confirmPlayers()
          }
        }.disabled(model.sourceGeneration == nil)
        Button("Begin ONE standing collection") {
          perform {
            guard let setup = model.session?.setup else { throw AnatomyInspectionError.inactive }
            try setup.requestCalibration(id: UUID())
          }
        }.disabled(model.session?.setup?.phase != .awaitingCalibration)
        Button("Request ONE evidence frame") { perform { _ = try gate.requestAnatomyInspection(); showMask = false } }
          .disabled(value.ticket != nil || value.frame != nil || model.sourceGeneration == nil
            || gate.anatomyInspectionBudget.usage.bytes != 0 || value.lastFailure != nil
            || (progress.phase != .collecting && progress.phase != .waitingForReliablePair))
      }.buttonStyle(.bordered)
      Text("Start and Arm remain explicit controls in the game scene. Collection retains the existing 1 Hz schedule and 30-second lifetime; inspection never extends either. At most ten inspected frames per collection. No automatic next frame.")
    }
  }
  private func provenance(_ frame: AnatomyInspectionFrame) -> some View {
    VStack(alignment: .leading) {
      Text("FROZEN HISTORICAL FRAME — NOT LIVE · \(frame.source.frameID) @ \(frame.source.capturedAt)").bold()
      Text("Generation \(frame.source.context.generation) · epoch \(frame.source.context.epoch) · geometry \(frame.source.context.geometryRevision)")
      Text("Control \(frame.ticket.calibration.bindingRevision) · accepted context \(frame.ticket.acceptedRevision) · binding \(frame.acknowledgment.requestID) · ack frame \(frame.acknowledgment.source.frameID) · collection \(frame.ticket.calibration.request.id)")
      Text("Original pixels already upright / unmirrored; capture connection rotation \(frame.source.rotationAngle)°. Display mirroring is a separate explicit toggle.")
      Text("Native mask: \(frame.quality.rawValue) · \(frame.nativeWidth.map(String.init) ?? "?")×\(frame.nativeHeight.map(String.init) ?? "?") · stride \(frame.nativeStride.map(String.init) ?? "?") · format \(frame.nativeFormat.map { String(format: "0x%08X", $0) } ?? "NOT MEASURABLE") · service \(String(format: "%.2f",frame.serviceSeconds * 1000)) ms")
      Text("Original inspection deadline: \(frame.ticket.expiresAt). Source loss, control/context change, Stop or deadline withdraws the image and marks. Later tracking uncertainty does not change this frozen original association and never restores live authority.")
    }.font(.caption2.monospaced())
  }
  private func mark(_ frame: AnatomyInspectionFrame, point: AnatomyInspectionPoint?) throws {
    guard let player = frame.players[selectedPlayer] else { throw AnatomyInspectionError.incompatible }
    try gate.markAnatomyReference(.init(inspection: frame.ticket.id, source: frame.source,
      key: .init(player: selectedPlayer, measurement: selectedMeasurement), candidateID: player.candidateID, point: point))
  }
  private func evidenceRows(_ frame: AnatomyInspectionFrame, inspection: AnatomyInspectionState) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(PlayerID.allCases, id: \.self) { id in
        if let player = frame.players[id] {
          Text("\(id.rawValue) · original candidate \(player.candidateID) · \(player.tracking.state.rawValue) / \(player.tracking.reason.rawValue) / rebind \(player.tracking.requiresRebind) / genuine binding").bold()
          ForEach(AnatomyInspectionMeasurement.allCases, id: \.self) { measurement in
            let key = AnatomyInspectionKey(player: id, measurement: measurement)
            let scalar = measurement.scalar(player.anatomy)
            let reference = inspection.references[key]
            Text("\(measurement.rawValue): \(scalar?.status.rawValue ?? "NO CANDIDATE") · estimate Y \(inspection.revealed ? scalar?.imageY.map { String(format:"%.6f",$0) } ?? "UNAVAILABLE" : "HIDDEN") · aggregate confidence NOT PROVIDED")
            Text(measurement.inputs.map { joint in
              "\(joint.rawValue): " + (player.joints[joint].map { String(format:"%.6f",$0.confidence) + ($0.confidence >= AnatomicalCandidatePolicyV1.confidence ? " ≥0.5" : " <0.5") } ?? "MISSING")
            }.joined(separator: " · ")).font(.caption2.monospaced())
            if inspection.revealed, let estimate = scalar?.imageY, scalar?.status == .experimental, let point = reference?.point {
              Text("Independent reference Y \(String(format:"%.6f",point.y)) · |ΔY| \(String(format:"%.3f",abs(estimate-point.y)*Double(frame.source.descriptor.height))) SOURCE pixels")
            } else { Text(reference == nil ? "Reference UNMARKED" : reference?.point == nil ? "Reference UNAVAILABLE" : "Reference independently marked; comparison hidden").font(.caption2) }
          }
        }
      }
    }
  }
  private func summaries(_ value: AnatomyInspectionState) -> some View {
    let count = value.frames > 0 ? value.frames : value.historicalSummary?.frames ?? 0
    let summaries = value.frames > 0 ? value.summaries : value.historicalSummary?.summaries ?? [:]
    return VStack(alignment: .leading) {
      if value.frames == 0, let history = value.historicalSummary {
        Text("HISTORICAL NUMERIC SUMMARY ONLY · generation \(history.lastSource.context.generation) / epoch \(history.lastSource.context.epoch) / geometry \(history.lastSource.context.geometryRevision) · last frame \(history.lastSource.frameID) @ \(history.lastSource.capturedAt) · control \(history.ticket.calibration.bindingRevision) · collection \(history.ticket.calibration.request.id)")
      }
      if let history = value.historicalSummary, value.frames == 0 {
        Text("Inspected original frames: " + history.sources.map { "\($0.frameID) @ \($0.capturedAt)" }.joined(separator: "; "))
      }
      Text("Coverage among \(count) explicitly INSPECTED mask frames only (not all camera frames)").bold()
      ForEach(PlayerID.allCases, id: \.self) { id in
        ForEach(AnatomyInspectionMeasurement.allCases, id: \.self) { measurement in
          let summary = summaries[.init(player: id, measurement: measurement)] ?? .init()
          Text("\(id.rawValue) \(measurement.rawValue): eligible \(summary.eligible)/\(summary.observed) · no candidate \(summary.noCandidate) · refusals \(summary.refusals.values.reduce(0,+)) · reference unavailable \(summary.referenceMissing) · comparisons \(summary.compared) · mean |ΔY| \(summary.compared > 0 ? String(format:"%.3f",summary.totalVerticalErrorPixels / Double(summary.compared)) : "NOT MEASURABLE") px · max \(summary.compared > 0 ? String(format:"%.3f",summary.maximumVerticalErrorPixels) : "NOT MEASURABLE") px")
        }
      }
    }.font(.caption2.monospaced())
  }
  private func perform(_ action: () throws -> Void) {
    do { try action(); error = nil } catch { self.error = "Inspection refused: \(error). No reference or authority was fabricated." }
  }
}

private struct AnatomyInspectionCanvas: View {
  let frame: AnatomyInspectionFrame
  let state: AnatomyInspectionState
  let mirrored: Bool
  let showMask: Bool
  let mark: (AnatomyInspectionPoint, AnatomyInspectionPoint) -> Void
  var body: some View {
    GeometryReader { geometry in
      let size = CGSize(width: frame.source.descriptor.width, height: frame.source.descriptor.height)
      let rect = CameraPreviewLayout.rect(image: size, in: geometry.size)
      ZStack {
        Color.black
        if let image = showMask ? frame.mask : frame.image {
          Image(decorative: image, scale: 1).resizable().interpolation(.none)
            .frame(width: rect.width, height: rect.height)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .position(x: rect.midX, y: rect.midY)
        } else { Text("SOURCE IMAGE UNAVAILABLE · no point comparisons") }
        Canvas { context, _ in
          for (id, player) in frame.players {
            // Source-associated torso labels only, never anatomical predictions.
            if let left = player.joints[.leftHip], let right = player.joints[.rightHip] {
              let point = AnatomyInspectionGeometry.display(.init(x:(left.x+right.x)/2,y:(left.y+right.y)/2), in:rect,mirrored:mirrored)
              context.draw(Text("\(id.rawValue) / \(player.candidateID)").font(.caption.bold()).foregroundStyle(.yellow), at:point)
            }
            if let box = state.referenceRegions[id] {
              let a = AnatomyInspectionGeometry.display(.init(x:box.minX,y:box.maxY),in:rect,mirrored:mirrored)
              let b = AnatomyInspectionGeometry.display(.init(x:box.maxX,y:box.minY),in:rect,mirrored:mirrored)
              let boxRect = CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
              context.stroke(Path(boxRect), with:.color(.green),lineWidth:1)
              if state.revealed {
                for measurement in AnatomyInspectionMeasurement.allCases {
                  if let scalar = measurement.scalar(player.anatomy), scalar.status == .experimental, let y = scalar.imageY {
                    let left = AnatomyInspectionGeometry.display(.init(x:box.minX,y:y),in:rect,mirrored:mirrored)
                    let right = AnatomyInspectionGeometry.display(.init(x:box.maxX,y:y),in:rect,mirrored:mirrored)
                    var line = Path(); line.move(to:left); line.addLine(to:right)
                    context.stroke(line,with:.color(.red),lineWidth:2)
                    context.draw(Text(measurement.rawValue).font(.caption2).foregroundStyle(.red),at:left,anchor:.leading)
                  }
                }
              }
            }
          }
          for (key, reference) in state.references {
            if let point = reference.point {
              let p = AnatomyInspectionGeometry.display(point,in:rect,mirrored:mirrored)
              context.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.green))
              context.draw(Text("\(key.player.rawValue) \(key.measurement.rawValue)").font(.caption2).foregroundStyle(.green),at:CGPoint(x:p.x+6,y:p.y),anchor:.leading)
            }
          }
        }
      }.contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance:0).onEnded { value in
          guard !showMask, !state.revealed,
            let a = AnatomyInspectionGeometry.canonical(value.startLocation,image:size,bounds:geometry.size,mirrored:mirrored),
            let b = AnatomyInspectionGeometry.canonical(value.location,image:size,bounds:geometry.size,mirrored:mirrored) else { return }
          mark(a,b)
        })
    }
  }
}
#endif
