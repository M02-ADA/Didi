import Foundation

/// PROPOSED App-owned adapter against Kevin commit e7b4a2f; not a public D06 field freeze.
nonisolated enum VisionK03PacketFactory: VisionAvatarPacketFactory {
  static func status(_ s: VisionNumericPoseStatus) -> AvatarSourceStatus {
    AvatarSourceStatus(revision:s.revision,isActive:s.active,
      context:s.context.map(AvatarSourceContext.init),controlRevision:s.controlRevision,layout:s.layout,
      calibrations:s.calibrationRevisions.reduce(into:[:]) { result, pair in
        if let cutover = s.cutovers[pair.key] {
          result[pair.key] = AvatarCalibrationStatus(revision:pair.value,cutover:cutover)
        }
      })
  }
  static func output(source: PlayerTrackingSource, revision: UInt64,
    player1: PlayerTrackingSlotResult, player2: PlayerTrackingSlotResult,
    candidates: [PoseCandidate], calibration: [PlayerID: VisionAvatarCalibrationValues]) -> AvatarSourceOutput {
    AvatarSourceOutput(source:AvatarSourceFrame(source),contextRevision:revision,
      player1:AvatarTrackedSlot(player1),player2:AvatarTrackedSlot(player2),candidates:candidates,
      calibration:calibration.mapValues { c in
        AvatarCalibrationInput(revision:c.revision,mapping:c.mapping,
          standingCrownImageY:c.standingCrownImageY,standingHipImageY:c.standingHipImageY,
          standingLeftAnkleImageY:c.standingLeftAnkleImageY,standingRightAnkleImageY:c.standingRightAnkleImageY,
          visual:nil) // no CP1 reader or experimental anatomy promoted to visual truth
      })
  }
}
