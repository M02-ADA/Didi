#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation
import Testing
import Synchronization
import UIKit
@testable import Sedactive

nonisolated private struct InspectionFixture {
  var tracking: TrackingIntegrationFixture
  let pose: CameraPoseResult
  let admission: CameraTrackingAdmission
  let receipt: PlayerTrackingSnapshot
  let ticket: AnatomyInspectionTicket
  init() throws {
    var f = try TrackingIntegrationFixture(); try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id: UUID())
    _ = try f.gate.requestAnatomyInspection()
    let pose = try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let admission = try #require(f.gate.admit(pose.source))
    try #require(try f.finish(pose,stamp:admission))
    let receipt = try #require(f.gate.snapshot.latest)
    try #require(f.gate.beginMask(pose:pose,admission:admission,receipt:receipt))
    let ticket = try #require(f.gate.beginAnatomyInspection(pose:pose,admission:admission,receipt:receipt))
    tracking=f; self.pose=pose; self.admission=admission; self.receipt=receipt; self.ticket=ticket
  }
  func mask() -> PersonMaskObservation {
    var mask=LiveVisionFixtures.mask(pose)
    for (id,region) in mask.regions {
      mask.anatomy[id] = .init(source:pose.source,controlRevision:admission.revision,
        candidateID:region.candidateID,crown:.init(imageY:0.9,status:.experimental),
        leftSole:.init(imageY:0.1,status:.experimental),rightSole:.refused(.missingLandmarks))
    }
    return mask
  }
  func builder() -> AnatomyInspectionImageBuilder {
    .init(source:pose.source,budget:tracking.gate.anatomyInspectionBudget)
  }
  func buffer() throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    try #require(CVPixelBufferCreate(nil,1280,720,kCVPixelFormatType_32BGRA,nil,&value) == kCVReturnSuccess)
    let buffer=try #require(value)
    try #require(CVPixelBufferLockBaseAddress(buffer,[]) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
    let base=try #require(CVPixelBufferGetBaseAddress(buffer))
    base.initializeMemory(as:UInt8.self,repeating:0,count:CVPixelBufferGetDataSize(buffer))
    // Distinct original top-left and bottom-right pixels; no second orientation transform.
    base.storeBytes(of:UInt8(17),as:UInt8.self)
    base.advanced(by:719*CVPixelBufferGetBytesPerRow(buffer)+1279*4).storeBytes(of:UInt8(93),as:UInt8.self)
    return buffer
  }
  func publish(mask: PersonMaskObservation? = nil, image: Bool = true, cancelled: Bool = false) throws {
    let builder=builder()
    let picture=image ? builder.cameraImage(try buffer()) : nil
    tracking.gate.finishAnatomyInspection(ticket,pose:pose,admission:admission,receipt:receipt,
      mask:mask ?? self.mask(),images:builder,image:picture,cancelled:cancelled)
  }
  func reference(_ frame: AnatomyInspectionFrame, player: PlayerID = .player1,
    measurement: AnatomyInspectionMeasurement = .crown, point: AnatomyInspectionPoint? = .init(x:0.75,y:0.88)) -> AnatomyInspectionReference {
    .init(inspection:frame.ticket.id,source:frame.source,key:.init(player:player,measurement:measurement),
      candidateID:frame.players[player]!.candidateID,point:point)
  }
  func regions(_ frame: AnatomyInspectionFrame) throws {
    for id in PlayerID.allCases {
      let x=id == .player1 ? 0.51 : 0.01
      try tracking.gate.setAnatomyReferenceRegion(inspection:frame.ticket.id,source:frame.source,
        player:id,candidateID:frame.players[id]!.candidateID,a:.init(x:x,y:0),b:.init(x:x+0.48,y:1))
    }
  }
}

nonisolated private final class InspectionWorkerCount: Sendable { let value = Mutex(0) }

nonisolated private final class InspectionWorkerSegmenter: AnatomyInspectionMaskDetecting {
  var anatomyInspectionImages: AnatomyInspectionImageBuilder?
  let calls: InspectionWorkerCount
  init(calls: InspectionWorkerCount) { self.calls=calls }
  func detect(in buffer: CVPixelBuffer, pose: CameraPoseResult,
    association: PlayerTrackingSnapshot) throws -> PersonMaskObservation {
    calls.value.withLock { $0 += 1 }
    let labels=Data(repeating:1,count:64)
    labels.withUnsafeBytes {
      anatomyInspectionImages?.captureMask(source:pose.source,width:8,height:8,stride:8,
        format:kCVPixelFormatType_OneComponent8,base:$0.baseAddress!)
    }
    var regions:[PlayerID:PersonMaskRegion]=[:]
    for id in PlayerID.allCases {
      if let candidate=association[id].candidateID {
        regions[id] = .init(candidateID:candidate,label:id == .player1 ? 2:1,
          minX:id == .player1 ? 0.5:0,maxX:id == .player1 ? 1:0.5,minY:0,maxY:1)
      }
    }
    return .init(source:pose.source,quality:.torsoSupportedGeometryUnverified,regions:regions,
      outputBytes:64,serviceSeconds:0.001)
  }
}

nonisolated struct AnatomyEvidenceInspectionTests {
  @Test func explicitRequestCannotArmOrStartCalibration() throws {
    let f=try TrackingIntegrationFixture()
    #expect(throws:AnatomyInspectionError.self) { try f.gate.requestAnatomyInspection() }
    #expect(f.gate.snapshot.requestID == nil && f.gate.snapshot.acknowledgment == nil)
    #expect(f.gate.readBody().calibration.request == nil)
  }
  @Test func admissionBeforeInspectionCannotBorrowNewIntent() throws {
    var f=try TrackingIntegrationFixture();try f.bind()
    try f.gate.configureBody(LiveVisionFixtures.configuration(f.context.generation))
    _ = try f.gate.requestCalibration(id:UUID())
    let pose=try f.result(3,0.25,LiveVisionFixtures.standingPair)
    let before=try #require(f.gate.admit(pose.source))
    _ = try f.gate.requestAnatomyInspection()
    try #require(try f.finish(pose,stamp:before))
    let receipt=try #require(f.gate.snapshot.latest)
    #expect(f.gate.beginAnatomyInspection(pose:pose,admission:before,receipt:receipt) == nil)
  }
  @Test func originalFrameConfidenceAndExperimentalStatusRemainExact() throws {
    let f=try InspectionFixture();try f.publish()
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame)
    #expect(frame.source == f.pose.source)
    #expect(frame.acknowledgment.requestID == f.ticket.calibration.bindingRequest)
    for id in PlayerID.allCases {
      let player=try #require(frame.players[id])
      let original=try #require(f.pose.frame.candidates.first { $0.candidateID == player.candidateID })
      #expect(player.joints == original.joints)
      #expect(player.anatomy?.crown.status == .experimental)
      #expect(player.anatomy?.rightSole.status == .missingLandmarks)
    }
    #expect(f.tracking.gate.readAnatomyInspection().references.isEmpty)
    #expect(f.tracking.gate.readBody().context?.calibrationRevisions.isEmpty == true)
  }
  @Test func foreignMaskCannotPublishAnImageUnderOriginalMetadata() throws {
    let f=try InspectionFixture()
    let wrong=try f.tracking.result(4,0.3,LiveVisionFixtures.standingPair)
    try f.publish(mask:LiveVisionFixtures.mask(wrong))
    let rejected=f.tracking.gate.readAnatomyInspection()
    #expect(rejected.frame == nil && rejected.ticket == nil && !rejected.capturing)
    #expect(rejected.lastFailure == .rejectedCompletion)
    #expect(throws:AnatomyInspectionError.self) { try f.tracking.gate.requestAnatomyInspection() }
    #expect(f.tracking.gate.anatomyInspectionBudget.usage.bytes == 0)
  }
  @Test func foreignNestedAnatomyAndMissingCandidateRemainUnavailableIndependently() throws {
    let f=try InspectionFixture();var mask=f.mask()
    let wrong=try f.tracking.result(4,0.3,LiveVisionFixtures.standingPair)
    let raw=try #require(mask.anatomy[.player1])
    mask.anatomy[.player1] = .init(source:wrong.source,controlRevision:raw.controlRevision,
      candidateID:raw.candidateID,crown:raw.crown,leftSole:raw.leftSole,rightSole:raw.rightSole)
    try f.publish(mask:mask,image:false)
    let state=f.tracking.gate.readAnatomyInspection()
    #expect(state.frame?.players[.player1]?.anatomy == nil)
    #expect(state.summaries[.init(player:.player1,measurement:.crown)]?.noCandidate == 1)
    #expect(state.summaries[.init(player:.player2,measurement:.crown)]?.eligible == 1)
    #expect(state.summaries[.init(player:.player2,measurement:.rightSole)]?.refusals[.missingLandmarks] == 1)
  }
  @Test func independentMarksProduceVerticalErrorOnlyOnce() throws {
    let f=try InspectionFixture();try f.publish()
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame)
    try f.regions(frame)
    for id in PlayerID.allCases {
      for measurement in AnatomyInspectionMeasurement.allCases {
        let point=AnatomyInspectionPoint(x:id == .player1 ? 0.75:0.25,y:measurement == .crown ? 0.88:0.12)
        try f.tracking.gate.markAnatomyReference(f.reference(frame,player:id,measurement:measurement,point:point))
      }
    }
    #expect(f.tracking.gate.readAnatomyInspection().summaries[.init(player:.player1,measurement:.crown)]?.compared == 0)
    try f.tracking.gate.revealAnatomyComparisons()
    let state=f.tracking.gate.readAnatomyInspection()
    let crown=try #require(state.summaries[.init(player:.player1,measurement:.crown)])
    #expect(crown.compared == 1)
    #expect(abs(crown.maximumVerticalErrorPixels - 14.4) < 0.000001)
    #expect(state.summaries[.init(player:.player1,measurement:.rightSole)]?.compared == 0)
    #expect(throws:AnatomyInspectionError.self) { try f.tracking.gate.revealAnatomyComparisons() }
    #expect(throws:AnatomyInspectionError.self) { try f.tracking.gate.markAnatomyReference(f.reference(frame)) }
  }
  @Test(arguments:[0,1,2,3]) func incorrectReferenceAssociationIsRejected(_ fault:Int) throws {
    let f=try InspectionFixture();try f.publish()
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame);try f.regions(frame)
    let wrongSource=try f.tracking.result(4,0.3).source
    let reference=AnatomyInspectionReference(inspection:fault == 0 ? UUID():frame.ticket.id,
      source:fault == 1 ? wrongSource:frame.source,key:.init(player:.player1,measurement:.crown),
      candidateID:fault == 2 ? frame.players[.player2]!.candidateID:frame.players[.player1]!.candidateID,
      point:.init(x:fault == 3 ? 0.25:0.75,y:0.88))
    #expect(throws:AnatomyInspectionError.self) { try f.tracking.gate.markAnatomyReference(reference) }
    #expect(f.tracking.gate.readAnatomyInspection().references.isEmpty)
  }
  @Test func independentlyDrawnRegionsCannotOverlapAndDoNotComeFromMask() throws {
    let f=try InspectionFixture();try f.publish()
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame)
    #expect(f.tracking.gate.readAnatomyInspection().referenceRegions.isEmpty)
    try f.tracking.gate.setAnatomyReferenceRegion(inspection:frame.ticket.id,source:frame.source,
      player:.player1,candidateID:10,a:.init(x:0.5,y:0),b:.init(x:1,y:1))
    #expect(throws:AnatomyInspectionError.self) {
      try f.tracking.gate.setAnatomyReferenceRegion(inspection:frame.ticket.id,source:frame.source,
        player:.player2,candidateID:20,a:.init(x:0.25,y:0),b:.init(x:0.75,y:1))
    }
  }
  @Test func unavailableImageAndReferenceDoNotFabricateError() throws {
    let f=try InspectionFixture();try f.publish(image:false)
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame)
    #expect(throws:AnatomyInspectionError.self) { try f.tracking.gate.markAnatomyReference(f.reference(frame)) }
    for id in PlayerID.allCases {
      for measurement in AnatomyInspectionMeasurement.allCases {
        try f.tracking.gate.markAnatomyReference(f.reference(frame,player:id,measurement:measurement,point:nil))
      }
    }
    try f.tracking.gate.revealAnatomyComparisons()
    #expect(f.tracking.gate.readAnatomyInspection().summaries.values.allSatisfy { $0.compared == 0 && $0.referenceMissing == 1 })
  }
  @Test(arguments:[false,true]) func mappingUsesAspectFitYUpAndExplicitMirror(_ mirrored:Bool) throws {
    let image=CGSize(width:1280,height:720),bounds=CGSize(width:1000,height:1000)
    let canonical=AnatomyInspectionPoint(x:0.2,y:0.8)
    let rect=CameraPreviewLayout.rect(image:image,in:bounds)
    let displayed=AnatomyInspectionGeometry.display(canonical,in:rect,mirrored:mirrored)
    let recovered=try #require(AnatomyInspectionGeometry.canonical(displayed,image:image,bounds:bounds,mirrored:mirrored))
    #expect(abs(recovered.x-canonical.x) < 0.000001 && abs(recovered.y-canonical.y) < 0.000001)
    #expect(AnatomyInspectionGeometry.canonical(.zero,image:image,bounds:bounds,mirrored:mirrored) == nil)
  }
  @Test func sourcePixelsAreNotRotatedTwiceOrBorrowedFromPreview() throws {
    let f=try InspectionFixture();try f.publish()
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame)
    let image=try #require(frame.image),data=try #require(image.dataProvider?.data)
    let pointer=try #require(CFDataGetBytePtr(data))
    #expect(frame.source.rotationAngle == 180)
    #expect(pointer[0] == 17 && pointer[(719*1280+1279)*4] == 93)
  }
  @Test(arguments:[0.499,0.5,0.501]) func freshnessBoundaryCannotPublishStaleEvidence(_ age:Double) throws {
    let f=try InspectionFixture();f.tracking.clock.time=f.pose.source.capturedAt+age
    try f.publish(image:false)
    #expect((f.tracking.gate.readAnatomyInspection().frame != nil) == (age < 0.5))
  }
  @Test(arguments:[0,1,2,3]) func sourceControlBackgroundAndCancellationRejectBlockedCompletion(_ action:Int) throws {
    let f=try InspectionFixture()
    switch action {
    case 0:f.tracking.gate.sourceLost(f.tracking.context)
    case 1:f.tracking.gate.revoke()
    case 2:
      let center=NotificationCenter()
      f.tracking.gate.observeApplicationLifecycle(center,initiallyForeground:true)
      center.post(name:UIApplication.didEnterBackgroundNotification,object:nil)
    default:f.tracking.gate.cancelCalibration(f.ticket.calibration.request)
    }
    try f.publish()
    #expect(f.tracking.gate.readAnatomyInspection().frame == nil)
    #expect(f.tracking.gate.anatomyInspectionBudget.usage.bytes == 0)
  }
  @Test func cancelledWorkerAndServiceOverrunCannotPublish() throws {
    let f=try InspectionFixture();try f.publish(cancelled:true)
    #expect(f.tracking.gate.readAnatomyInspection().frame == nil)
    let other=try InspectionFixture();var mask=other.mask()
    mask = .init(source:mask.source,quality:mask.quality,regions:mask.regions,outputBytes:64,serviceSeconds:0.101,anatomy:mask.anatomy)
    other.tracking.gate.finishMask(mask,pose:other.pose,admission:other.admission,receipt:other.receipt)
    try other.publish(mask:mask)
    #expect(other.tracking.gate.readAnatomyInspection().frame == nil)
    #expect(other.tracking.gate.readBody().calibration.phase == .stoppedForReview)
  }
  @Test func imageCreditSurvivesInvalidationUntilProviderActuallyReleases() throws {
    let budget:CameraPreviewBudget
    var provider:CGDataProvider?
    do {
      let f=try InspectionFixture();budget=f.tracking.gate.anatomyInspectionBudget
      let store=FrameStore(tracking:f.tracking.gate)
      try f.publish()
      do { let frame=try #require(f.tracking.gate.readAnatomyInspection().frame);provider=frame.image?.dataProvider }
      f.tracking.gate.sourceLost(f.tracking.context)
      #expect(f.tracking.gate.readAnatomyInspection().frame == nil)
      #expect(store.metrics.snapshot.ownedPixelBytes == 1280*720*4)
      #expect(budget.usage.bytes == 1280*720*4)
      #expect(provider != nil)
    }
    provider=nil
    #expect(budget.usage.bytes == 0 && budget.usage.backings == 0)
  }
  @Test func oneFrozenFrameCannotBeReplacedAndSummarySurvivesStopWithoutPixels() throws {
    let f=try InspectionFixture();try f.publish()
    #expect(throws:AnatomyInspectionError.self) { try f.tracking.gate.requestAnatomyInspection() }
    f.tracking.gate.sourceLost(f.tracking.context)
    let state=f.tracking.gate.readAnatomyInspection()
    #expect(state.frame == nil && state.references.isEmpty && state.referenceRegions.isEmpty)
    #expect(state.historicalSummary?.frames == 1)
    #expect(state.historicalSummary?.sources == [f.pose.source])
    #expect(f.tracking.gate.anatomyInspectionBudget.usage.bytes == 0)
    try f.publish(image:false) // old blocked completion may not replace the historical receipt
    #expect(f.tracking.gate.readAnatomyInspection().historicalSummary?.sources == [f.pose.source])
  }
  @Test func tenSampleCapAndNoAutomaticCaptureAreIndependentOfCandidateSuccess() throws {
    let f=try InspectionFixture();var state=AnatomyInspectionState()
    for i in 0..<10 {
      let time=Double(i)+0.25
      let pose=try f.tracking.result(UInt64(i+3),time,LiveVisionFixtures.standingPair)
      let id=try state.request(calibration:f.ticket.calibration,acceptedRevision:0,at:time,deadline:30,ownedBytes:0)
      #expect(state.frame == nil)
      let begun=state.begin(id,calibration:f.ticket.calibration,source:pose.source,at:time)
      let ticket=try #require(begun)
      let players=Dictionary(uniqueKeysWithValues:PlayerID.allCases.map { player in
        (player,AnatomyInspectionPlayer(candidateID:player == .player1 ? 10:20,
          tracking:f.receipt[player],joints:[:],region:nil,anatomy:nil))
      })
      let frame=AnatomyInspectionFrame(ticket:ticket,source:pose.source,
        acknowledgment:try #require(f.tracking.gate.snapshot.acknowledgment),players:players,image:nil,mask:nil,
        nativeWidth:nil,nativeHeight:nil,nativeStride:nil,nativeFormat:nil,quality:.unsupportedOutput,serviceSeconds:0.01)
      let accepted=state.finish(frame,at:time)
      let duplicate=state.finish(frame,at:time)
      #expect(accepted)
      #expect(!duplicate)
      state.discard()
    }
    #expect(state.frames == 10 && state.inspectedSources.count == 10)
    #expect(state.summaries.values.allSatisfy { $0.observed == 10 && $0.noCandidate == 10 && $0.compared == 0 })
    #expect(throws:AnatomyInspectionError.self) {
      try state.request(calibration:f.ticket.calibration,acceptedRevision:0,at:11,deadline:30,ownedBytes:0)
    }
  }
  @Test func requestDeadlineCannotBeExtendedAndHistoricalFrameIsNeverLive() throws {
    var f=try InspectionFixture();try f.publish(image:false)
    let original=f.ticket.expiresAt
    for i in 4...8 {
      let t=Double(i-1)*0.125
      let pose=try f.tracking.result(UInt64(i),t,LiveVisionFixtures.standingPair)
      try #require(try f.tracking.finish(pose))
    }
    let state=f.tracking.gate.readAnatomyInspection()
    #expect(state.frame?.source.frameID == 3) // frozen original, not latest B1/B2
    #expect(state.frame?.ticket.expiresAt == original)
    f.tracking.clock.time=original
    let expired=f.tracking.gate.readAnatomyInspection()
    #expect(expired.frame == nil && expired.ticket == nil)
  }

  @Test func existingWorkerRunsExactlyOneOptionalMaskAndReleasesInspectionOnStop() async throws {
    let clock=TrackingIntegrationClock()
    let gate=CameraTrackingGate(automaticDeadlines:false,now:{ clock.time })
    let store=FrameStore(tracking:gate),context=CameraTestFrames.context()
    _ = store.begin(context)
    let calls=InspectionWorkerCount()
    let sink=CameraCopySink(metrics:store.metrics,poses:store.poses,tracking:gate,
      makeDetector:{ SprintPoseDetector() },makeSegmenter:{ InspectionWorkerSegmenter(calls:calls) })
    try gate.configureBody(LiveVisionFixtures.configuration(context.generation))
    _ = try gate.arm(request:gate.makeBindingRequest())
    let buffer=try CameraTestFrames.buffer();try CameraTestFrames.fill(buffer,17)
    for i in 1...3 {
      let time=Double(i-1)*0.125;clock.time=time
      let metadata=CameraFrameMetadata(context:context,frameID:try store.nextIdentity(context),capturedAt:time,
        descriptor:try CameraFrameDescriptor(width:8,height:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),
          pixelFormat:kCVPixelFormatType_32BGRA,maximumBytes:1024),rotationAngle:180,mirrored:false)
      try store.copy(buffer,metadata:metadata)
      let lease=try CameraTestFrames.lease(store,context)
      try await sink.consume(lease.frame);store.complete(lease)
      if i == 2 { _ = try gate.requestCalibration(id:UUID());_ = try gate.requestAnatomyInspection() }
    }
    #expect(calls.value.withLock { $0 } == 1)
    do {
      let frame=try #require(gate.readAnatomyInspection().frame)
      #expect(frame.source.frameID == 3 && frame.source.capturedAt == 0.25)
      #expect(frame.image != nil && frame.mask != nil)
      #expect(frame.nativeFormat == kCVPixelFormatType_OneComponent8)
      #expect(gate.anatomyInspectionBudget.usage.bytes == 2*8*8*4)
    }
    #expect(store.poses.snapshot.statistics.completed == 3)
    #expect(gate.readBody().delivery != .claimed) // no CP1 subscriber added by inspection
    store.end(context);await sink.reset()
    #expect(gate.readAnatomyInspection().frame == nil)
    #expect(gate.anatomyInspectionBudget.usage.bytes == 0)
    #expect(store.metrics.snapshot.ownedPixelBytes == 0)
  }

  @Test func frozenHistoricalReferenceDoesNotRestoreExpiredLiveAuthority() throws {
    let f=try InspectionFixture();try f.publish()
    let frame=try #require(f.tracking.gate.readAnatomyInspection().frame)
    f.tracking.clock.time=0.8
    f.tracking.gate.expireDue()
    #expect(f.tracking.gate.snapshot.latest == nil)
    #expect(f.tracking.gate.readBody().latest == nil)
    // A frozen original association is for inspection only, never a current pose or pair claim.
    try f.tracking.gate.markAnatomyReference(f.reference(frame,point:nil))
    #expect(f.tracking.gate.readAnatomyInspection().frame?.source == frame.source)
    #expect(f.tracking.gate.readBody().latest == nil)
    f.tracking.gate.sourceLost(f.tracking.context)
    #expect(f.tracking.gate.readAnatomyInspection().frame == nil)
  }

}
#endif
