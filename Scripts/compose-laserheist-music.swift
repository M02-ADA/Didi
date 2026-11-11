// Laser Heist music: an original stealth-heist loop in two synchronized layers.
// 112 BPM, D minor, 8 bars (17.142857 s, exactly 756 000 samples at 44.1 kHz).
//   base  (Home / setup, and under rounds): soft pad, tiptoe pizzicato motif with a spy echo, light ticks
//   drive (joins in rounds):                staccato bass ostinato, kick + rim, laser blips building in bars 5–8
// Deterministic: same output every run. Seamless: rendered over two loops and folded.
import AVFoundation
import Foundation

let sr = 44_100.0
let bpm = 112.0
let beat = 60 / bpm
let loopSamples = 756_000
let total = loopSamples * 2

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 2 - 1 } }
func midi(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }
let names: [String: Double] = ["C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11]
func note(_ s: String) -> Double {   // "D5", "Bb1"
    let octave = Double(String(s.last!))!
    return midi(names[String(s.dropLast())]! + 12 * (octave + 1))
}

final class Track {
    var data = [Double](repeating: 0, count: total)
    func add(_ start: Double, _ seconds: Double, _ f: (Double) -> Double) {
        let s0 = Int(start * sr), n = Int(seconds * sr)
        for i in 0..<n where s0 + i < total && s0 + i >= 0 { data[s0 + i] += f(Double(i) / sr) }
    }
}

// MARK: Instruments

/// Pizzicato / marimba-like pluck: a few harmonics, fast attack, short decay.
func pluck(_ t: Track, _ at: Double, _ freq: Double, _ gain: Double) {
    t.add(at, 0.6) { x in
        let env = min(1, x / 0.003) * exp(-x / 0.11)
        let w = 2 * Double.pi * freq * x
        return gain * env * (sin(w) + 0.35 * sin(2 * w) * exp(-x / 0.05) + 0.12 * sin(3 * w) * exp(-x / 0.03))
    }
}
/// Warm pad: detuned saw-ish stack through a one-pole low-pass, slow swell.
func pad(_ t: Track, _ at: Double, _ dur: Double, _ freqs: [Double], _ gain: Double) {
    var lp = 0.0
    let a = 1 - exp(-2 * Double.pi * 900 / sr)
    t.add(at, dur + 0.6) { x in
        let env = min(1, x / 0.5) * (x > dur ? exp(-(x - dur) / 0.25) : 1)
        var s = 0.0
        for f in freqs {
            for d in [-0.004, 0.0, 0.004] {
                let ph = (f * (1 + d) * x).truncatingRemainder(dividingBy: 1)
                s += (2 * ph - 1) * 0.33
            }
        }
        lp += a * (s / Double(freqs.count) - lp)
        return gain * env * lp
    }
}
/// Staccato synth bass: square-ish with harmonics for small speakers, low-passed.
func bass(_ t: Track, _ at: Double, _ freq: Double, _ gain: Double, _ len: Double = 0.17) {
    var lp = 0.0
    let a = 1 - exp(-2 * Double.pi * 1100 / sr)
    t.add(at, len + 0.08) { x in
        let env = min(1, x / 0.004) * (0.65 + 0.35 * exp(-x / 0.05)) * (x > len ? exp(-(x - len) / 0.02) : 1)
        let ph = (freq * x).truncatingRemainder(dividingBy: 1)
        let sq = ph < 0.5 ? 1.0 : -1.0
        lp += a * (sq - lp)
        return gain * env * (0.7 * lp + 0.3 * sin(2 * Double.pi * freq * x))
    }
}
func kick(_ t: Track, _ at: Double, _ gain: Double) {
    t.add(at, 0.35) { x in
        let f = 45 + 75 * exp(-x / 0.035)
        let phase = 2 * Double.pi * (45 * x + 75 * 0.035 * (1 - exp(-x / 0.035)))
        _ = f
        return gain * exp(-x / 0.13) * sin(phase)
    }
}
func rim(_ t: Track, _ at: Double, _ gain: Double, _ rng: inout RNG) {
    var prev = 0.0
    var noise: [Double] = (0..<Int(0.12 * sr)).map { _ in rng.next() }
    for i in stride(from: noise.count - 1, to: 0, by: -1) { noise[i] -= noise[i - 1] }   // high-pass
    t.add(at, 0.12) { x in
        let i = min(noise.count - 1, Int(x * sr))
        prev = noise[i]
        return gain * exp(-x / 0.035) * (0.55 * prev + 0.5 * sin(2 * Double.pi * 410 * x) * exp(-x / 0.02))
    }
}
func tick(_ t: Track, _ at: Double, _ gain: Double, _ rng: inout RNG) {
    var noise: [Double] = (0..<Int(0.06 * sr)).map { _ in rng.next() }
    for _ in 0..<2 { for i in stride(from: noise.count - 1, to: 0, by: -1) { noise[i] -= noise[i - 1] } }
    t.add(at, 0.06) { x in gain * exp(-x / 0.012) * noise[min(noise.count - 1, Int(x * sr))] * 0.5 }
}
/// "Laser blip": a short sine with a quick downward chirp.
func blip(_ t: Track, _ at: Double, _ freq: Double, _ gain: Double) {
    t.add(at, 0.25) { x in
        let phase = 2 * Double.pi * (freq * 0.5 * x + freq * 0.5 * 0.03 * (1 - exp(-x / 0.03)))
        return gain * min(1, x / 0.002) * exp(-x / 0.07) * sin(phase)
    }
}
/// A feedback echo (dotted eighth), folded into the loop later.
func echo(_ t: Track, delay: Double, feedback: Double, mix: Double) {
    let d = Int(delay * sr)
    var out = t.data
    for i in d..<total { out[i] += feedback * out[i - d] }
    for i in 0..<total { t.data[i] = t.data[i] + mix * (out[i] - t.data[i]) }
}

// MARK: Score (8 bars, chords: Dm Dm Bb Bb Gm Gm A A)

let e8 = beat / 2
let roots = ["D", "D", "Bb", "Bb", "G", "G", "A", "A"]
let padChords: [[String]] = [["D3", "F3", "A3", "C4", "E4"], ["Bb2", "D3", "F3", "A3", "C4"],
                             ["G2", "Bb2", "D3", "F3", "A3"], ["A2", "C#3", "E3", "G3", "Bb3"]]
// Tiptoe motif on the eighth grid ("-" = rest); original, not quoted from any theme.
let motif: [[String]] = [
    ["-", "D5", "-", "F5", "-", "A5", "G#5", "A5"],
    ["-", "-", "C6", "-", "A5", "-", "F5", "-"],
    ["-", "D5", "-", "F5", "-", "Bb5", "A5", "Bb5"],
    ["-", "-", "D6", "-", "Bb5", "-", "F5", "-"],
    ["-", "G5", "-", "Bb5", "-", "D6", "C#6", "D6"],
    ["-", "-", "F6", "-", "D6", "-", "Bb5", "-"],
    ["-", "A5", "-", "C#6", "-", "E6", "-", "G6"],
    ["F6", "-", "E6", "-", "C#6", "-", "-", "-"],
]
// Bass ostinato per bar: root, root, rest, root, colour, rest, root, approach.
let bassBars: [[String]] = [
    ["D2", "D2", "-", "D2", "F2", "-", "D2", "C#2"],
    ["D2", "D2", "-", "D2", "A2", "-", "G2", "F2"],
    ["Bb1", "Bb1", "-", "Bb1", "D2", "-", "Bb1", "A1"],
    ["Bb1", "Bb1", "-", "Bb1", "F2", "-", "D2", "C2"],
    ["G1", "G1", "-", "G1", "Bb1", "-", "G1", "F#1"],
    ["G1", "G1", "-", "G1", "D2", "-", "C2", "Bb1"],
    ["A1", "A1", "-", "A1", "C#2", "-", "A1", "G#1"],
    ["A1", "A1", "-", "A1", "E2", "-", "C#2", "C#2"],
]

let base = Track(), motifTrack = Track(), drive = Track()
var rng = RNG(s: 0x5EDAC71E)
for loop in 0..<2 {
    let l0 = Double(loop * loopSamples) / sr
    for bar in 0..<8 {
        let b0 = l0 + Double(bar) * 4 * beat
        if bar % 2 == 0 { pad(base, b0, 8 * beat - 0.1, padChords[bar / 2].map(note), 0.075) }
        for (i, n) in motif[bar].enumerated() where n != "-" { pluck(motifTrack, b0 + Double(i) * e8, note(n), 0.16) }
        for i in 0..<8 { tick(base, b0 + Double(i) * e8, i % 2 == 1 ? 0.06 : 0.035, &rng) }
        for (i, n) in bassBars[bar].enumerated() where n != "-" { bass(drive, b0 + Double(i) * e8, note(n), 0.17) }
        kick(drive, b0, 0.42); kick(drive, b0 + 2 * beat, 0.36)
        if bar % 2 == 1 { kick(drive, b0 + 3.5 * beat, 0.25) }
        rim(drive, b0 + beat, 0.16, &rng); rim(drive, b0 + 3 * beat, 0.16, &rng)
        // Laser blips: off-beat sixteenths, sparse in bars 1–4, busier in 5–8.
        let steps = bar < 4 ? [3, 11] : [3, 6, 11, 14]
        let chord = padChords[bar / 2].map(note)
        for (k, s) in steps.enumerated() { blip(drive, b0 + Double(s) * beat / 4, chord[(k + bar) % chord.count] * 4, 0.05) }
    }
}
echo(motifTrack, delay: 0.75 * beat, feedback: 0.32, mix: 0.45)
for i in 0..<total { base.data[i] += motifTrack.data[i] }

func write(_ track: Track, _ path: String, peakDB: Double) throws {
    // Fold the second loop's start (tails of loop one) onto loop two's own decays: take loop two
    // whole, and add loop one's spill past its end into the start, so the wrap is seamless.
    var loopData = Array(track.data[loopSamples..<total])
    for i in 0..<loopSamples where loopSamples * 2 + i < total { loopData[i] += track.data[loopSamples * 2 + i] }
    let peak = loopData.map(abs).max() ?? 1
    let gain = pow(10, peakDB / 20) / peak
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(loopSamples))!
    buffer.frameLength = AVAudioFrameCount(loopSamples)
    for i in 0..<loopSamples { buffer.floatChannelData![0][i] = Float(loopData[i] * gain) }
    let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
    try file.write(from: buffer)
}
let out = CommandLine.arguments[1]
try write(base, out + "/lh-music-base.wav", peakDB: -10)
try write(drive, out + "/lh-music-drive.wav", peakDB: -10)
print("ok")
