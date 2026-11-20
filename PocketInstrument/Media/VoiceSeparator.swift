import AVFoundation
import Accelerate
import AudioToolbox
import EditCore

/// Splits a source's sound with Apple's on-device voice isolation (AUSoundIsolation), once, into
/// the two versions a clip can play: the voices alone, and the recording with the isolated voices
/// subtracted from it (their level matched every 50 ms). It runs offline, far faster than
/// real time, and nothing leaves the device.
///
/// Isolation removes most background noise, so Voice Only is clean. Subtraction leaves some of
/// the voice behind (it lowers it, typically 8 dB or so), hence "Reduce", not "Remove".
enum VoiceSeparator {
    static let sampleRate = 48_000.0
    /// Frames rendered per pass through the isolation unit.
    private static let chunk = 4096
    /// Frames over which the subtraction's level is matched (50 ms).
    private static let block = 2400
    /// The most the isolated voice is scaled up before it's subtracted.
    private static let maxGain: Float = 3

    enum SeparationError: LocalizedError {
        case unavailable
        case noAudio

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Voice isolation isn't available on this device."
            case .noAudio: return "This clip has no sound to process."
            }
        }
    }

    private static var isolationDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    }

    /// Writes `voiceURL` (mono, the voices) and `reducedURL` (stereo, the voices taken down) for the
    /// sound of the file at `url`, each the same length as that sound and starting where it starts.
    /// Files are written aside and moved into place at the end, so a cancelled run leaves nothing.
    static func separate(
        source url: URL, voiceURL: URL, reducedURL: URL, progress: @Sendable (Double) -> Void
    ) async throws {
        var description = isolationDescription
        guard AudioComponentFindNext(nil, &description) != nil else { throw SeparationError.unavailable }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SeparationError.noAudio
        }
        let expectedFrames = max(1, try await track.load(.timeRange).duration.seconds * sampleRate)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: sampleRate,
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ImportError.unreadable(url.lastPathComponent) }
        defer { reader.cancelReading() }

        let folder = voiceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let voiceTemp = folder.appendingPathComponent(UUID().uuidString + ".m4a")
        let reducedTemp = folder.appendingPathComponent(UUID().uuidString + ".m4a")
        defer {
            try? FileManager.default.removeItem(at: voiceTemp)
            try? FileManager.default.removeItem(at: reducedTemp)
        }

        // Scoped so both files are finished (closed) before they're moved into place.
        try {
            let isolator = try Isolator()
            var split = Splitter(
                voice: try losslessFile(voiceTemp, channels: 1), reduced: try losslessFile(reducedTemp, channels: 2),
                latency: isolator.latency)
            var lastReport = 0.0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                var samples = [Float](repeating: 0, count: count)
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                }
                try split.add(interleaved: samples, through: isolator)
                let done = min(Double(split.framesIn) / expectedFrames, 0.99)
                if done - lastReport >= 0.01 {
                    lastReport = done
                    progress(done)
                }
            }
            if reader.status == .failed { throw reader.error ?? ImportError.unreadable(url.lastPathComponent) }
            try split.finish(through: isolator)
        }()

        for (temp, final) in [(voiceTemp, voiceURL), (reducedTemp, reducedURL)] {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: temp, to: final)
        }
        progress(1)
    }

    /// Apple Lossless: about half the size of PCM, and unlike AAC no encoder delay to shift the sound.
    private static func losslessFile(_ url: URL, channels: Int) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: 16,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// The isolation unit in an offline engine: mono in, the voices out, `latency` frames late.
    private final class Isolator {
        private let engine = AVAudioEngine()
        private let player = AVAudioPlayerNode()
        private let format = AVAudioFormat(standardFormatWithSampleRate: VoiceSeparator.sampleRate, channels: 1)!
        private let rendered: AVAudioPCMBuffer
        let latency: Int

        init() throws {
            let unit = AVAudioUnitEffect(audioComponentDescription: VoiceSeparator.isolationDescription)
            // The standard model: the high-quality one reshapes the voice, so it subtracts poorly.
            AudioUnitSetParameter(
                unit.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice), 0)
            AudioUnitSetParameter(
                unit.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
            engine.attach(player)
            engine.attach(unit)
            engine.connect(player, to: unit, format: format)
            engine.connect(unit, to: engine.mainMixerNode, format: format)
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: AVAudioFrameCount(VoiceSeparator.chunk))
            try engine.start()
            player.play()
            rendered = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(VoiceSeparator.chunk))!
            var seconds = Float64(0)
            var size = UInt32(MemoryLayout<Float64>.size)
            AudioUnitGetProperty(
                unit.audioUnit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size)
            latency = Int((seconds * VoiceSeparator.sampleRate).rounded())
        }

        deinit { engine.stop() }

        /// Isolates the voices in `samples` (exactly one chunk), returning what the unit puts out.
        func process(_ samples: ArraySlice<Float>) throws -> [Float] {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            input.frameLength = AVAudioFrameCount(samples.count)
            _ = samples.withUnsafeBufferPointer { memcpy(input.floatChannelData![0], $0.baseAddress!, $0.count * 4) }
            player.scheduleBuffer(input)
            guard try engine.renderOffline(AVAudioFrameCount(samples.count), to: rendered) == .success else {
                throw SeparationError.unavailable
            }
            return Array(UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength)))
        }
    }

    /// Lines the isolated voices up with the recording (dropping the unit's latency) and writes
    /// both versions a block at a time.
    private struct Splitter {
        let voice: AVAudioFile
        let reduced: AVAudioFile
        /// Isolated frames still to drop: the unit's latency.
        var skip: Int
        /// The recording, left and right, not yet written.
        var left: [Float] = []
        var right: [Float] = []
        /// Mono, not yet a whole chunk for the unit.
        var mono: [Float] = []
        /// Isolated voices, aligned with `left`/`right`, not yet written.
        var isolated: [Float] = []
        /// The subtraction level each channel ended the last block at.
        var gains: (Float, Float)?
        private(set) var framesIn = 0

        init(voice: AVAudioFile, reduced: AVAudioFile, latency: Int) {
            self.voice = voice
            self.reduced = reduced
            skip = latency
        }

        mutating func add(interleaved samples: [Float], through isolator: Isolator) throws {
            let frames = samples.count / 2
            framesIn += frames
            for i in 0..<frames {
                let l = samples[2 * i]
                let r = samples[2 * i + 1]
                left.append(l)
                right.append(r)
                mono.append((l + r) / 2)
            }
            try feed(through: isolator)
        }

        mutating func finish(through isolator: Isolator) throws {
            // Push silence through until every recorded frame has its isolated voice.
            while isolated.count < left.count {
                mono.append(contentsOf: repeatElement(0, count: VoiceSeparator.chunk))
                try feed(through: isolator)
            }
            try write(left.count)
        }

        private mutating func feed(through isolator: Isolator) throws {
            let chunk = VoiceSeparator.chunk
            var start = 0
            while mono.count - start >= chunk {
                var out = try isolator.process(mono[start..<(start + chunk)])
                start += chunk
                let dropped = min(skip, out.count)
                out.removeFirst(dropped)
                skip -= dropped
                isolated.append(contentsOf: out)
            }
            mono.removeFirst(start)
            let ready = min(isolated.count, left.count)
            let whole = ready - ready % VoiceSeparator.block
            if whole > 0 { try write(whole) }
        }

        /// Writes the first `count` aligned frames of both versions.
        private mutating func write(_ count: Int) throws {
            guard count > 0 else { return }
            let voiceBuffer = AVAudioPCMBuffer(
                pcmFormat: voice.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            let reducedBuffer = AVAudioPCMBuffer(
                pcmFormat: reduced.processingFormat, frameCapacity: AVAudioFrameCount(count))!
            voiceBuffer.frameLength = AVAudioFrameCount(count)
            reducedBuffer.frameLength = AVAudioFrameCount(count)
            let v = voiceBuffer.floatChannelData![0]
            let outL = reducedBuffer.floatChannelData![0]
            let outR = reducedBuffer.floatChannelData![1]
            var start = 0
            while start < count {
                let end = min(count, start + VoiceSeparator.block)
                let iso = isolated[start..<end]
                let target = (Self.gain(left[start..<end], iso), Self.gain(right[start..<end], iso))
                let from = gains ?? target
                let n = Float(end - start)
                for (k, i) in (start..<end).enumerated() {
                    // Glide from the last block's level to this one's, so the subtraction never steps.
                    let t = Float(k + 1) / n
                    let gl = from.0 + (target.0 - from.0) * t
                    let gr = from.1 + (target.1 - from.1) * t
                    v[i] = isolated[i]
                    outL[i] = left[i] - gl * isolated[i]
                    outR[i] = right[i] - gr * isolated[i]
                }
                gains = target
                start = end
            }
            try voice.write(from: voiceBuffer)
            try reduced.write(from: reducedBuffer)
            left.removeFirst(count)
            right.removeFirst(count)
            isolated.removeFirst(count)
        }

        /// The level of the isolated voices in `channel`: the least-squares fit, kept in range.
        private static func gain(_ channel: ArraySlice<Float>, _ iso: ArraySlice<Float>) -> Float {
            channel.withUnsafeBufferPointer { c in
                iso.withUnsafeBufferPointer { v in
                    let fit = vDSP.dot(c, v) / (vDSP.sumOfSquares(v) + 1e-9)
                    return min(max(fit, 0), VoiceSeparator.maxGain)
                }
            }
        }
    }
}
