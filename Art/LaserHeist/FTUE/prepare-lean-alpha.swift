import AVFoundation
import CoreGraphics

@main struct Convert {
 static func main() async throws {
  let source = URL(fileURLWithPath: CommandLine.arguments[1])
  let output = URL(fileURLWithPath: CommandLine.arguments[2])
  let asset = AVURLAsset(url: source)
  let track = try await asset.loadTracks(withMediaType: .video)[0]
  let size = try await track.load(.naturalSize)
  let fps = try await track.load(.nominalFrameRate)
  let width = Int(size.width), height = Int(size.height)
  let reader = try AVAssetReader(asset: asset)
  let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
  reader.add(decoded)
  let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
  let encoded = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey:AVVideoCodecType.hevcWithAlpha,AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoCompressionPropertiesKey:[AVVideoQualityKey:0.95,AVVideoExpectedSourceFrameRateKey:fps]])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:encoded,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
  writer.add(encoded)
  guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error! }
  writer.startSession(atSourceTime:.zero)
  var frames = 0
  while let sample = decoded.copyNextSampleBuffer(), let original = CMSampleBufferGetImageBuffer(sample) {
   while !encoded.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(2)) }
   var pixel: CVPixelBuffer?
   CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&pixel)
   guard let pixel else { fatalError("pixel pool") }
   CVPixelBufferLockBaseAddress(original,.readOnly);CVPixelBufferLockBaseAddress(pixel,[])
   let src = CVPixelBufferGetBaseAddress(original)!.assumingMemoryBound(to:UInt8.self)
   let dst = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)
   let sr = CVPixelBufferGetBytesPerRow(original), dr = CVPixelBufferGetBytesPerRow(pixel)
   for y in 0..<height { for x in 0..<width {
    let s = y*sr+x*4, d = y*dr+x*4
    // The supplied white silhouette over black is its own coverage matte. Bake once,
    // preserving antialiasing and every original source timestamp; no runtime keying.
    let a = max(src[s],src[s+1],src[s+2])
    // BGRA premultiplied cream (#FEE3BB), transparent black outside the figures.
    dst[d] = UInt8((Int(a)*187)/255);dst[d+1] = UInt8((Int(a)*227)/255)
    dst[d+2] = UInt8((Int(a)*254)/255);dst[d+3] = a
   } }
   CVPixelBufferUnlockBaseAddress(pixel,[]);CVPixelBufferUnlockBaseAddress(original,.readOnly)
   guard adaptor.append(pixel,withPresentationTime:CMSampleBufferGetPresentationTimeStamp(sample)) else { throw writer.error! }
   frames += 1
  }
  encoded.markAsFinished();await writer.finishWriting()
  if let error = writer.error { throw error }
  print("frames=\(frames) size=\(width)x\(height) fps=\(fps) duration=\(try await asset.load(.duration).seconds) status=\(writer.status.rawValue)")
 }
}
