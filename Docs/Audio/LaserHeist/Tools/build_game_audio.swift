// Builds the LaserHeist in-game audio from the Pixabay sources in ../Sources
// (cut, faded, mixed to mono, peak-levelled; see ../GAME-AUDIO.md) and
// synthesises the original background music stems. Deterministic: the same
// inputs always give the same files.
//
//   swiftc -O build_game_audio.swift -o build_game_audio
//   ./build_game_audio <Sources dir> <output dir>
//   (then convert the music stems to IMA4, see GAME-AUDIO.md)
import AVFoundation

let rate = 44_100.0
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: build_game_audio <sources> <output>"); exit(2) }
let sources = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// MARK: - Sample helpers

/// A source decoded to mono at 44.1 kHz.
func load(_ name: String) -> [Float] {
    let file = try! AVAudioFile(forReading: sources.appendingPathComponent(name))
    let format = file.processingFormat
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try! file.read(into: buffer)
    let n = Int(buffer.frameLength), channels = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: n)
    for c in 0..<channels { let d = buffer.floatChannelData![c]; for i in 0..<n { mono[i] += d[i] / Float(channels) } }
    return resample(mono, by: format.sampleRate / rate)
}

/// Reads `samples` at `step` source samples per output sample (linear
/// interpolation): above 1 raises the pitch and shortens the sound.
func resample(_ samples: [Float], by step: Double) -> [Float] {
    if step == 1 { return samples }
    let count = Int(Double(samples.count) / step)
    return (0..<count).map { i in
        let x = Double(i) * step, j = Int(x), f = Float(x - Double(j))
        let a = samples[min(j, samples.count - 1)], b = samples[min(j + 1, samples.count - 1)]
        return a + (b - a) * f
    }
}

func cut(_ s: [Float], _ from: Double, _ to: Double) -> [Float] {
    Array(s[Int(from * rate)..<min(s.count, Int(to * rate))])
}

/// Short fade-in (no click) and an eased fade-out over the tail.
func fade(_ s: [Float], in fadeIn: Double = 0.004, out fadeOut: Double) -> [Float] {
    var r = s
    let a = Int(fadeIn * rate), b = Int(fadeOut * rate)
    for i in 0..<min(a, r.count) { r[i] *= Float(i) / Float(a) }
    for i in 0..<min(b, r.count) { let t = Float(i) / Float(b); r[r.count - 1 - i] *= t * t }
    return r
}

/// Scales to a peak level in dBFS (headroom for mixing).
func level(_ s: [Float], peakDB: Float) -> [Float] {
    let peak = s.map(abs).max() ?? 0
    guard peak > 0 else { return s }
    let g = powf(10, peakDB / 20) / peak
    return s.map { $0 * g }
}

func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

func write(_ s: [Float], _ name: String) {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    // "lh-" prefix: Xcode copies synchronized-folder resources flat into the bundle.
    let url = output.appendingPathComponent("lh-" + name + ".caf")
    try? FileManager.default.removeItem(at: url)
    let file = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(s.count))!
    buffer.frameLength = AVAudioFrameCount(s.count)
    for i in 0..<s.count { buffer.floatChannelData![0][i] = max(-1, min(1, s[i])) }
    try! file.write(from: buffer)
    print(String(format: "%@  %.2fs", name, Double(s.count) / rate))
}

// MARK: - Sound effects (cut points chosen from the measured envelopes)

let click = load("digital-click-357350.mp3")
write(level(fade(cut(click, 0, 0.20), out: 0.06), peakDB: -14), "ui-tap")
write(level(fade(resample(cut(click, 0, 0.22), by: 1.12), out: 0.06), peakDB: -9), "vault-button")

// DUCK falls, JUMP rises: one clean 725 Hz beep, twice, the second a fourth lower or higher.
let beep = fade(cut(load("futuristic-ui-beeps-356129.mp3"), 0.995, 1.065), in: 0.003, out: 0.02)
write(level(beep + silence(0.035) + resample(beep, by: 0.75), peakDB: -6), "cue-duck")
write(level(beep + silence(0.035) + resample(beep, by: 1.335), peakDB: -6), "cue-jump")

write(level(fade(cut(load("reward-chime-144757.mp3"), 0.46, 1.30), out: 0.30), peakDB: -12), "laser-clear")
write(level(fade(cut(load("laser-zap-90575.mp3"), 0.07, 0.70), out: 0.15), peakDB: -7), "laser-hit")
write(level(fade(cut(load("safe-open-close-443345.mp3"), 0.06, 0.58), out: 0.08), peakDB: -8), "vault-open")
write(level(fade(cut(load("warning-notification-199277.mp3"), 0.04, 0.56), out: 0.10), peakDB: -11), "vault-warning")
write(level(fade(cut(load("game-bonus-144751.mp3"), 0.14, 1.45), out: 0.25), peakDB: -8), "diamond-time")

let diamond = fade(cut(load("diamond-found-190255.mp3"), 0, 0.55), out: 0.25)
for (index, step) in [1.0, 1.06, 0.95].enumerated() {
    write(level(resample(diamond, by: step), peakDB: -9), "diamond-collect-\(index + 1)")
}
write(level(fade(cut(load("victory-fanfare-152480.mp3"), 0.06, 3.10), out: 0.30), peakDB: -6), "round-success")
write(level(fade(cut(load("playful-failure-310480.mp3"), 0.10, 1.10), out: 0.15), peakDB: -8), "round-failure")

// MARK: - Original background music ("Vault Run", 126 BPM, 8 bars, C–Am–F–G)
//
// Two stems of one loop, played in sync: "base" (pad, arpeggio, bell motif)
// alone on the menus; "drive" (bass and drums) faded in for gameplay. 126 BPM
// makes the loop exactly 672,000 frames, a whole number of IMA4 packets, so it
// loops without a gap.

let beatFrames = Int(rate * 60 / 126)
let loopFrames = beatFrames * 32
var base = [Float](repeating: 0, count: loopFrames)
var drive = [Float](repeating: 0, count: loopFrames)

/// Adds a voice at `start` frames, wrapping past the end of the loop so the seam is seamless.
func add(_ into: inout [Float], at start: Int, _ length: Int, _ sample: (Double) -> Float) {
    for i in 0..<length { into[(start + i) % loopFrames] += sample(Double(i) / rate) }
}
func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
func tri(_ phase: Double) -> Float { Float(2 * abs(2 * (phase - floor(phase + 0.5))) - 1) }

var seed: UInt32 = 0x2545F491
func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 23) - 1 }

let chords: [[Int]] = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]] // C, Am, F, G
let roots = [36, 33, 29, 31]
for bar in 0..<8 {
    let chord = chords[bar % 4], start = bar * 4 * beatFrames
    // Pad: soft triangles, slow swell, one chord per bar.
    for note in chord {
        let f = hz(note)
        add(&base, at: start, 4 * beatFrames) { t in
            let env = Float(min(1, t / 0.35) * min(1, (4 * 60 / 126 - t) / 0.3))
            return tri(f * t) * env * 0.05
        }
    }
    // Arpeggio: plucked eighths up the chord, an octave up.
    let arp = [chord[0], chord[1], chord[2], chord[1] + 12, chord[2] + 12, chord[1] + 12, chord[2], chord[1]]
    for (step, note) in arp.enumerated() {
        let f = hz(note + 12)
        add(&base, at: start + step * beatFrames / 2, beatFrames) { t in
            Float(sin(2 * .pi * f * t) + 0.3 * sin(4 * .pi * f * t)) * Float(exp(-t * 9)) * 0.07
        }
    }
    // Bell motif on odd bars: a small rising call.
    if bar % 2 == 0 {
        for (step, note) in [chord[2] + 12, chord[0] + 24, chord[1] + 24].enumerated() {
            let f = hz(note)
            add(&base, at: start + (2 + step) * beatFrames / 2, 2 * beatFrames) { t in
                Float(sin(2 * .pi * f * t) * exp(-t * 4) + 0.2 * sin(2 * .pi * 2.76 * f * t) * exp(-t * 9)) * 0.05
            }
        }
    }
    // Bass: root eighths with an octave bounce.
    for step in 0..<8 {
        let f = hz(roots[bar % 4] + (step % 4 == 3 ? 12 : 0))
        add(&drive, at: start + step * beatFrames / 2, beatFrames / 2) { t in
            tri(f * t) * Float(exp(-t * 5) * min(1, t / 0.005)) * 0.16
        }
    }
    // Drums: kick on 1 and 3, clap on 2 and 4, closed hats on the off-beats.
    for beat in 0..<4 {
        let at = start + beat * beatFrames
        if beat % 2 == 0 {
            add(&drive, at: at, Int(0.18 * rate)) { t in
                Float(sin(2 * .pi * (50 * t + 70 * (1 - exp(-t * 30)) / 30))) * Float(exp(-t * 18)) * 0.32
            }
        } else {
            add(&drive, at: at, Int(0.14 * rate)) { t in noise() * Float(exp(-t * 28)) * 0.09 }
        }
        var last: Float = 0
        add(&drive, at: at + beatFrames / 2, Int(0.04 * rate)) { t in
            let n = noise(); let hp = n - last; last = n
            return hp * Float(exp(-t * 90)) * 0.035
        }
    }
}
write(level(base, peakDB: -10), "music-base")
write(level(drive, peakDB: -10), "music-drive")
print("loop frames \(loopFrames) (IMA4 packets: \(Double(loopFrames) / 64))")
