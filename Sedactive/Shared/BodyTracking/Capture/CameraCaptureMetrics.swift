import CoreMedia
import Foundation
import Synchronization

/// Capture-only measurements. No images, gameplay clock, body evidence or per-frame logging.
nonisolated enum CameraHostClock {
  static func now() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}
nonisolated struct CameraLatencySummary: Sendable {
  let count: UInt64, retainedSamples: Int
  let p50MS: Double?, p95MS: Double?
}
nonisolated struct CameraLatencyWindow: Sendable {
  static let capacity = 1024
  private var values: [Double] = []
  private var cursor = 0
  private(set) var count: UInt64 = 0
  mutating func record(seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    if count < .max { count += 1 }
    if values.count < Self.capacity {
      values.append(seconds)
    } else {
      values[cursor] = seconds
      cursor = (cursor + 1) % Self.capacity
    }
  }
  var summary: CameraLatencySummary {
    let sorted = values.sorted()
    func percentile(_ p: Double) -> Double? {
      guard !sorted.isEmpty else { return nil }
      let index = max(0, Int(ceil(Double(sorted.count) * p)) - 1)
      return sorted[index] * 1000
    }
    return CameraLatencySummary(
      count: count, retainedSamples: values.count,
      p50MS: percentile(0.50), p95MS: percentile(0.95))
  }
}
nonisolated struct CameraCaptureStatistics: Sendable {
  let context: CameraSourceContext?
  let configurationDetails: String
  let lastFrame: CameraFrameMetadata?
  let delivered: UInt64, admitted: UInt64, processed: UInt64, processingRejects: UInt64
  let sourceFPS: Double?, processingFPS: Double?, sourceSpanSeconds: Double?
  let workspaceBytes: Int, peakWorkspaceBytes: Int
  let ownedPixelBytes: Int, peakOwnedPixelBytes: Int
  let callback, copy, wait, processing, endToEnd: CameraLatencySummary
}
nonisolated final class CameraCaptureMetrics: Sendable {
  private struct State: Sendable {
    var context: CameraSourceContext?
    var configurationDetails = "No hardware configuration yet"
    var lastFrame: CameraFrameMetadata?
    var delivered: UInt64 = 0, admitted: UInt64 = 0, processed: UInt64 = 0, rejects: UInt64 = 0
    var firstCapture: Double?, lastCapture: Double?, firstCompletion: Double?,
      lastCompletion: Double?
    var workspaceBytes = 0, peakWorkspaceBytes = 0
    var sourceBytes = 0, peakOwnedPixelBytes = 0
    #if DEBUG
      var previewBytes = 0
    #endif
    var ownedBytes: Int {
      var count = sourceBytes + workspaceBytes
      #if DEBUG
        count += previewBytes
      #endif
      return count
    }
    var callback = CameraLatencyWindow(), copy = CameraLatencyWindow(), wait = CameraLatencyWindow()
    var processing = CameraLatencyWindow(), endToEnd = CameraLatencyWindow()
  }
  private let state = Mutex(State())
  func begin(_ context: CameraSourceContext) {
    state.withLock {
      // Old workspace must have quiesced before pipeline restart; never hide live resource usage.
      let retained = $0.workspaceBytes
      let raw = $0.sourceBytes
      #if DEBUG
        let preview = $0.previewBytes
      #endif
      $0 = State(context: context)
      $0.workspaceBytes = retained
      $0.sourceBytes = raw
      $0.peakWorkspaceBytes = retained
      #if DEBUG
        $0.previewBytes = preview
      #endif
      $0.peakOwnedPixelBytes = $0.ownedBytes
    }
  }
  func configuration(_ context: CameraSourceContext, description: String) {
    state.withLock { if $0.context == context { $0.configurationDetails = description } }
  }
  func delivered(_ metadata: CameraFrameMetadata) {
    state.withLock {
      guard $0.context == metadata.context else { return }
      if $0.delivered < .max { $0.delivered += 1 }
      $0.firstCapture = $0.firstCapture ?? metadata.capturedAt
      $0.lastCapture = metadata.capturedAt
      $0.lastFrame = metadata
    }
  }
  func callback(_ context: CameraSourceContext, seconds: Double) {
    state.withLock { if $0.context == context { $0.callback.record(seconds: seconds) } }
  }
  func copied(_ context: CameraSourceContext, seconds: Double) {
    state.withLock { if $0.context == context { $0.copy.record(seconds: seconds) } }
  }
  func admitted(_ context: CameraSourceContext) {
    state.withLock { if $0.context == context, $0.admitted < .max { $0.admitted += 1 } }
  }
  func completed(_ frame: CameraSourceFrame, startedAt: Double, completedAt: Double) {
    state.withLock {
      guard $0.context == frame.metadata.context else { return }
      if $0.processed < .max { $0.processed += 1 }
      $0.firstCompletion = $0.firstCompletion ?? completedAt
      $0.lastCompletion = completedAt
      $0.wait.record(seconds: startedAt - frame.admittedAt)
      $0.processing.record(seconds: completedAt - startedAt)
      $0.endToEnd.record(seconds: completedAt - frame.metadata.capturedAt)
    }
  }
  func rejected(_ context: CameraSourceContext) {
    state.withLock { if $0.context == context, $0.rejects < .max { $0.rejects += 1 } }
  }
  func sourceBytes(_ bytes: Int) {
    state.withLock {
      $0.sourceBytes = bytes
      $0.peakOwnedPixelBytes = max($0.peakOwnedPixelBytes, $0.ownedBytes)
    }
  }
  func workspace(bytes: Int) {
    state.withLock {
      $0.workspaceBytes = bytes
      $0.peakWorkspaceBytes = max(bytes, $0.peakWorkspaceBytes)
      $0.peakOwnedPixelBytes = max($0.peakOwnedPixelBytes, $0.ownedBytes)
    }
  }
  #if DEBUG
    func previewBytes(_ bytes: Int) {
      state.withLock {
        $0.previewBytes = bytes
        $0.peakOwnedPixelBytes = max($0.peakOwnedPixelBytes, $0.ownedBytes)
      }
    }
  #endif
  var snapshot: CameraCaptureStatistics {
    let value = state.withLock { $0 }
    func rate(_ count: UInt64, _ first: Double?, _ last: Double?) -> Double? {
      guard count > 1, let first, let last, last > first else { return nil }
      return Double(count - 1) / (last - first)
    }
    return CameraCaptureStatistics(
      context: value.context, configurationDetails: value.configurationDetails,
      lastFrame: value.lastFrame, delivered: value.delivered, admitted: value.admitted,
      processed: value.processed, processingRejects: value.rejects,
      sourceFPS: rate(value.delivered, value.firstCapture, value.lastCapture),
      processingFPS: rate(value.processed, value.firstCompletion, value.lastCompletion),
      sourceSpanSeconds: value.firstCapture.flatMap { first in value.lastCapture.map { $0 - first }
      },
      workspaceBytes: value.workspaceBytes, peakWorkspaceBytes: value.peakWorkspaceBytes,
      ownedPixelBytes: value.ownedBytes,
      peakOwnedPixelBytes: value.peakOwnedPixelBytes,
      callback: value.callback.summary, copy: value.copy.summary, wait: value.wait.summary,
      processing: value.processing.summary, endToEnd: value.endToEnd.summary)
  }
}
