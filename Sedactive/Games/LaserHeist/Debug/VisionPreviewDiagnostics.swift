#if DEBUG
import Foundation

/// DEBUG formatting only. Does not read images, subscribe to gameplay, or decide readiness.
nonisolated enum VisionPreviewDiagnostics {
  static let bundleID = "com.Edward-Kristian.Sedactive.VisionPreview"
  static func enabled(bundleID: String?, arguments: [String]) -> Bool {
    bundleID == Self.bundleID && arguments.contains("--vision-preview")
      && arguments.contains("--camera-diagnostics")
  }
  static func text(body: LiveBodyInputRead, mask: VisionPreviewMaskRead) -> String {
    var lines = [
      "DEVELOPMENT PREVIEW — no physical/calibration/gameplay acceptance",
      "E05 provider: \(body.status); source active: \(body.context?.isActive == true)",
      "Accepted calibration context revision: \(body.acceptedRevision); accepted players: \(body.context?.calibrationRevisions.count ?? 0)/2",
      "E04: \(body.calibration.phase.rawValue); samples \(body.calibration.sampleCount)/\(StandingCollectionPolicyV1.sampleCount); request \(body.calibration.request?.id.uuidString ?? "none")",
      body.calibration.reason,
    ]
    if let last = mask.last {
      lines += [
        "E03 last native output: \(last.quality.rawValue); supported torso regions: \(last.supportedRegions)/2; service \(String(format: "%.1f", last.serviceSeconds * 1000)) ms",
        "Mask diagnostic source current/fresh: \(mask.isCurrentSourceAndFresh); generation \(last.source.context.generation); epoch \(last.source.context.epoch); frame \(last.source.frameID); capturedAt \(last.source.capturedAt); geometry \(last.source.context.geometryRevision); control \(last.bindingRevision); calibration request \(last.calibrationRequest)",
        "Reported supported output bytes: \(last.reportedOutputBytes). Error-path zero is not a measured native allocation.",
        "Torso-label support and mask row/alignment convention remain unverified; labels are not PlayerIDs.",
      ]
    } else { lines.append("E03: NOT RUN / no compatible numeric mask result. Requires current confirmed pair + explicit collection.") }
    if let candidate = body.calibration.candidate {
      lines.append("Candidate \(candidate.id): UNACCEPTED; validated anatomical references: \(candidate.hasValidatedAnatomy). No baseline is fabricated.")
    }
    func scalar(_ value: EstimatedScalar) -> String {
      value.value.map { String(format: "%.3f", $0) + " (\(value.validity.rawValue))" }
        ?? "UNAVAILABLE (\(value.validity.rawValue))"
    }
    if let snapshot = body.latest {
      lines.append("E06 CP1 frame \(snapshot.frameID), capturedAt \(snapshot.capturedAt), generation \(snapshot.sessionGeneration), geometry \(snapshot.cameraGeometryRevision)")
      for id in PlayerID.allCases {
        guard let p = snapshot.players[id] else { continue }
        lines += [
          "\(id): \(p.trackingStatus.rawValue), calibration \(p.calibrationRevision.map(String.init) ?? "none")",
          "crown \(scalar(p.geometry.crownY)); wrists L \(scalar(p.geometry.leftWristY)), R \(scalar(p.geometry.rightWristY))",
          "soles L \(scalar(p.geometry.leftSoleY)), R \(scalar(p.geometry.rightSoleY)); airborne \(p.jumpState.phase.rawValue) / \(p.jumpState.validity.rawValue)",
        ]
      }
    } else { lines.append("E06: no current CP1 sample. Crown / wrists / separate soles / airborne UNAVAILABLE; no geometry inferred from preview.") }
    lines.append("No skeleton overlay: preview and latest B1 pose are not an exact same-frame packet. B1 numeric landmarks/confidences and B2 statuses are below. No complete B2 latency distribution or identity history.")
    lines.append("One camera run per app launch in this preview. Stop/Cancel stay safe; relaunch for a new run. No automatic bind or calibration acceptance.")
    return lines.joined(separator: "\n\n")
  }
}
#endif
