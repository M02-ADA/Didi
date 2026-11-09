import Foundation

/// Airborne evidence needs justified independent soles AND an accepted floor/time model.
/// Ankle elevation or a mask bottom alone never supplies this authority.
nonisolated enum JumpDetector {
  static func unavailable(_ reason: EvidenceValidity = .missingLandmarks) -> JumpState {
    .init(phase: .unknown, validity: reason == .valid ? .missingLandmarks : reason)
  }
}
