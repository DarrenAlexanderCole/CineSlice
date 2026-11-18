import AVFoundation
import EditCore

/// Turns a guide's clicks into sound. Saved guides are rendered once to a 16-bit WAV in the
/// project's media, so preview and export play them through the same composition as any song,
/// sample-accurate, with nothing scheduled by timers. The sheet's preview plays the same clicks
/// from memory on a looping `AVAudioPlayerNode`.
enum GuideRenderer {
    static let sampleRate = 44_100.0

    /// A mono buffer of `duration` with each click drawn in: a short decaying tone, highest and
    /// loudest on accents, quietest on subdivisions.
    static func buffer(_ clicks: [GuideClick], duration: MediaTime) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw ExportError.failed("No audio format")
        }
        let frameCount = AVAudioFrameCount(max(1, (duration.seconds * sampleRate).rounded(.up)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let samples = buffer.floatChannelData?[0]
        else { throw ExportError.failed("No audio buffer") }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) { samples[i] = 0 }
        for click in clicks {
            let (pitch, gain, seconds): (Double, Float, Double) =
                switch click.weight {
                case .accent: (1_600, 0.9, 0.04)
                case .beat: (1_000, 0.45, 0.04)
                case .subdivision: (800, 0.22, 0.025)
                }
            let start = Int((click.time.seconds * sampleRate).rounded())
            guard start >= 0, start < Int(frameCount) else { continue }
            for n in 0..<min(Int(sampleRate * seconds), Int(frameCount) - start) {
                let t = Double(n) / sampleRate
                samples[start + n] += gain * Float(sin(2 * .pi * pitch * t) * exp(-t * 120))
            }
        }
        return buffer
    }

    static func write(_ clicks: [GuideClick], duration: MediaTime, to url: URL) throws {
        let buffer = try buffer(clicks, duration: duration)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// Plays a few bars of a guide on a loop while it's being set up, from a rendered buffer: the
/// hardware clock keeps the clicks even, never the UI.
@MainActor
final class GuidePreview {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isPlaying = false

    init() {
        engine.attach(player)
    }

    /// Loops `clicks` over `length`, replacing whatever was playing.
    func play(_ clicks: [GuideClick], length: MediaTime) {
        stop()
        guard let buffer = try? GuideRenderer.buffer(clicks, duration: length) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        isPlaying = true
    }

    func stop() {
        player.stop()
        engine.stop()
        isPlaying = false
    }
}
