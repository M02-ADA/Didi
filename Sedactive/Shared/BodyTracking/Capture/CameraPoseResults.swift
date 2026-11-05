import Foundation
import Synchronization

nonisolated struct CameraPoseStatistics: Sendable {
  var completed: UInt64 = 0, rejected: UInt64 = 0, failures: UInt64 = 0
  var counts: [UInt64] = [0, 0, 0, 0]  // Successful frames with zero / one / two / more bodies.
  var inference = CameraLatencyWindow(), age = CameraLatencyWindow()
  var firstCompletion: Double?, lastCompletion: Double?
  mutating func increment(_ key: WritableKeyPath<Self, UInt64>) {
    if self[keyPath: key] < .max { self[keyPath: key] += 1 }
  }
  var framesPerSecond: Double? {
    guard completed > 1, let firstCompletion, let lastCompletion,
      lastCompletion > firstCompletion else { return nil }
    return Double(completed - 1) / (lastCompletion - firstCompletion)
  }
}
nonisolated struct CameraPoseSnapshot: Sendable {
  let latest: CameraPoseResult?
  let statistics: CameraPoseStatistics
}

/// One latest immutable result, no observer/stream and no raw image ownership or pose history.
nonisolated final class CameraPoseResults: Sendable {
  private struct State {
    var context: CameraSourceContext?
    var token = UUID()
    var lastStarted: UInt64?
    var latest: CameraPoseResult?
    var statistics = CameraPoseStatistics()
  }
  private let state = Mutex(State())
  nonisolated struct Ticket: Sendable {
    let source: CameraFrameMetadata
    fileprivate let token: UUID
  }
  func begin(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context != context else { return }
      $0 = State(context: context)
    }
  }
  func invalidate(_ context: CameraSourceContext) {
    state.withLock {
      guard $0.context == context else { return }
      $0.context = nil
      $0.latest = nil
      $0.token = UUID()
    }
  }
  func start(_ source: CameraFrameMetadata) -> Ticket? {
    state.withLock {
      guard $0.context == source.context, source.frameID > ($0.lastStarted ?? 0) else {
        $0.statistics.increment(\.rejected)
        return nil
      }
      $0.lastStarted = source.frameID
      return Ticket(source: source, token: $0.token)
    }
  }
  @discardableResult
  func finish(_ result: CameraPoseResult, ticket: Ticket, startedAt: Double, completedAt: Double,
    cancelled: Bool = false) -> Bool
  {
    state.withLock {
      guard !cancelled, $0.context == ticket.source.context, $0.token == ticket.token,
        result.source == ticket.source, result.matchesSource, $0.lastStarted == result.source.frameID,
        result.source.frameID > ($0.latest?.source.frameID ?? 0),
        startedAt.isFinite, completedAt.isFinite, completedAt >= startedAt,
        startedAt >= result.source.capturedAt
      else {
        $0.statistics.increment(\.rejected)
        return false
      }
      $0.latest = result
      $0.statistics.increment(\.completed)
      let bucket = min(result.observationCount, 3)
      if $0.statistics.counts[bucket] < .max { $0.statistics.counts[bucket] += 1 }
      $0.statistics.inference.record(seconds: completedAt - startedAt)
      $0.statistics.age.record(seconds: completedAt - result.source.capturedAt)
      $0.statistics.firstCompletion = $0.statistics.firstCompletion ?? completedAt
      $0.statistics.lastCompletion = completedAt
      return true
    }
  }
  func failed(_ ticket: Ticket) {
    state.withLock {
      guard $0.context == ticket.source.context, $0.token == ticket.token,
        $0.lastStarted == ticket.source.frameID,
        ($0.latest?.source.frameID ?? 0) < ticket.source.frameID else {
        $0.statistics.increment(\.rejected)
        return
      }
      $0.statistics.increment(\.failures)
      $0.latest = nil
    }
  }
  var snapshot: CameraPoseSnapshot {
    state.withLock { CameraPoseSnapshot(latest: $0.latest, statistics: $0.statistics) }
  }
}
