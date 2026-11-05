//
//  PoseSmoothing.swift
//  Sedactive
//

#if DEBUG
import Foundation

/// Adaptive low-pass filter (the "1€ filter"): strong smoothing when a value
/// is still, almost none when it moves fast, so jitter is removed without
/// adding visible lag to real movement.
struct OneEuroFilter {
    var minimumCutoff: Double
    var beta: Double
    var derivativeCutoff: Double = 1
    private var value: Float?
    private var derivative: Float = 0

    init(minimumCutoff: Double, beta: Double) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
    }

    mutating func reset() { value = nil; derivative = 0 }

    mutating func filter(_ input: Float, dt: Double) -> Float {
        guard let previous = value, dt > 0 else { value = input; derivative = 0; return input }
        let raw = (input - previous) / Float(dt)
        derivative += Self.alpha(derivativeCutoff, dt) * (raw - derivative)
        let cutoff = minimumCutoff + beta * Double(abs(derivative))
        let result = previous + Self.alpha(cutoff, dt) * (input - previous)
        value = result
        return result
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Float {
        Float(1 / (1 + 1 / (2 * .pi * cutoff * dt)))
    }
}
#endif
