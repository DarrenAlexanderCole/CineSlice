import AVFoundation
import Accelerate
import EditCore

/// Splits a source's sound with HTDemucs (see `Demucs`), once, into the two versions a clip can
/// play: the voices alone, and everything else (the scene, music, noise) with the voices taken
/// out. It runs on the device; nothing leaves it.
///
/// The model takes 7.8 s at a time, so the sound goes through in overlapping segments that are
/// cross-faded back together, as demucs's `apply_model` does (a quarter overlap, triangular
/// weights). It streams: only a couple of segments are held in memory, whatever the clip's length.
enum VoiceSeparator {
    static let sampleRate = Demucs.sampleRate
    private static let segment = Demucs.segment
    /// Segments start this far apart, so each overlaps the next by a quarter.
    private static let stride = segment * 3 / 4
    /// demucs's cross-fade: rising to the segment's middle and falling after it.
    private static let weight: [Float] = {
        let half = segment / 2
        let peak = Float(max(half, segment - half))
        return (0..<segment).map { i in Float(i < half ? i + 1 : segment - i) / peak }
    }()

    enum SeparationError: LocalizedError {
        case noAudio

        var errorDescription: String? { "This clip has no sound to process." }
    }

    /// Writes `voiceURL` (the voices) and `reducedURL` (everything but the voices), both stereo,
    /// for the sound of the file at `url`, each the same length as that sound and starting where
    /// it starts. Files are written aside and moved into place at the end, so a cancelled run
    /// leaves nothing.
    static func separate(
        source url: URL, voiceURL: URL, reducedURL: URL, progress: @Sendable (Double) -> Void
    ) async throws {
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
            var split = Splitter(
                demucs: try Demucs(), voice: try losslessFile(voiceTemp), rest: try losslessFile(reducedTemp))
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                var samples = [Float](repeating: 0, count: count)
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(
                        block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
                }
                if try split.add(interleaved: samples) {
                    progress(min(Double(split.framesOut) / expectedFrames, 0.99))
                }
            }
            if reader.status == .failed { throw reader.error ?? ImportError.unreadable(url.lastPathComponent) }
            try split.finish()
        }()

        for (temp, final) in [(voiceTemp, voiceURL), (reducedTemp, reducedURL)] {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: temp, to: final)
        }
        progress(1)
    }

    /// Apple Lossless, stereo: about half the size of PCM, and unlike AAC no encoder delay to
    /// shift the sound.
    private static func losslessFile(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: 16,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Runs the recording through `Demucs` a segment at a time and writes the cross-faded stems
    /// as soon as no later segment can change them.
    private struct Splitter {
        let demucs: Demucs
        let voice: AVAudioFile
        let rest: AVAudioFile
        /// The recording, left and right, from `base` on.
        var input: [[Float]] = [[], []]
        /// Weighted sums of the stems and of the weights, from `base` on.
        var voiceSum: [[Float]] = [[], []]
        var restSum: [[Float]] = [[], []]
        var weightSum: [Float] = []
        /// The recording frame `input` and the sums start at.
        var base = 0
        /// Where the next segment starts.
        var next = 0
        private(set) var framesIn = 0
        private(set) var framesOut = 0

        init(demucs: Demucs, voice: AVAudioFile, rest: AVAudioFile) {
            self.demucs = demucs
            self.voice = voice
            self.rest = rest
        }

        /// Takes interleaved stereo; returns true when it finished a segment.
        mutating func add(interleaved samples: [Float]) throws -> Bool {
            let frames = samples.count / 2
            framesIn += frames
            for i in 0..<frames {
                input[0].append(samples[2 * i])
                input[1].append(samples[2 * i + 1])
            }
            var separated = false
            while framesIn - next >= VoiceSeparator.segment {
                try separateNext()
                separated = true
            }
            return separated
        }

        mutating func finish() throws {
            while next < framesIn { try separateNext() }
            try write(framesIn - base)
        }

        /// Separates the segment at `next` (padded with silence past the end), adds it to the
        /// sums, and writes what's now final: everything before the following segment.
        private mutating func separateNext() throws {
            try Task.checkCancellation()
            let start = next - base
            let end = min(input[0].count, start + VoiceSeparator.segment)
            let stems = try demucs.separate(input.map { Array($0[start..<end]) })
            let needed = start + VoiceSeparator.segment
            if weightSum.count < needed {
                let more = needed - weightSum.count
                weightSum += repeatElement(0, count: more)
                for c in 0..<2 {
                    voiceSum[c] += repeatElement(0, count: more)
                    restSum[c] += repeatElement(0, count: more)
                }
            }
            let w = VoiceSeparator.weight
            for c in 0..<2 {
                voiceSum[c].withUnsafeMutableBufferPointer { s in
                    vDSP.add(s[start..<needed], vDSP.multiply(stems.voice[c], w), result: &s[start..<needed])
                }
                restSum[c].withUnsafeMutableBufferPointer { s in
                    vDSP.add(s[start..<needed], vDSP.multiply(stems.rest[c], w), result: &s[start..<needed])
                }
            }
            weightSum.withUnsafeMutableBufferPointer { s in
                vDSP.add(s[start..<needed], w, result: &s[start..<needed])
            }
            next += VoiceSeparator.stride
            try write(min(next, framesIn) - base)
        }

        /// Writes and drops the first `count` frames.
        private mutating func write(_ count: Int) throws {
            guard count > 0 else { return }
            for (file, sums) in [(voice, voiceSum), (rest, restSum)] {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                for c in 0..<2 {
                    let out = vDSP.divide(sums[c][0..<count], weightSum[0..<count])
                    out.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: count) }
                }
                try file.write(from: buffer)
            }
            for c in 0..<2 {
                input[c].removeFirst(count)
                voiceSum[c].removeFirst(count)
                restSum[c].removeFirst(count)
            }
            weightSum.removeFirst(count)
            base += count
            framesOut += count
        }
    }
}
