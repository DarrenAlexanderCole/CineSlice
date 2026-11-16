import AVFoundation
import Accelerate
import EditCore

/// Reads a music file once into peak amplitudes and caches them in the
/// project's Cache folder, so reopening a project doesn't re-decode the song.
enum WaveformAnalyzer {
    static let peaksPerSecond = 50.0
    private static let sampleRate = 44_100.0

    /// The cached waveform if present, otherwise analyzes and caches it.
    static func waveform(for url: URL, cacheURL: URL) async throws -> Waveform {
        if let data = try? Data(contentsOf: cacheURL), let cached = Waveform(data: data) { return cached }
        let waveform = try await analyze(url: url)
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? waveform.data.write(to: cacheURL, options: .atomic)
        return waveform
    }

    static func analyze(url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTrack(url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        // Mono float PCM at a fixed rate keeps the peak math simple.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: sampleRate,
            ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ImportError.unreadable(url.lastPathComponent) }

        let window = Int(sampleRate / peaksPerSecond)
        var peaks: [Float] = []
        var pending: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            pending.append(contentsOf: samples)
            var start = 0
            while pending.count - start >= window {
                peaks.append(peak(pending[start..<(start + window)]))
                start += window
            }
            pending.removeFirst(start)
        }
        if reader.status == .failed { throw reader.error ?? ImportError.unreadable(url.lastPathComponent) }
        if !pending.isEmpty { peaks.append(peak(pending[...])) }
        return Waveform(peaksPerSecond: peaksPerSecond, peaks: peaks.map { min($0, 1) })
    }

    private static func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.withUnsafeBufferPointer { vDSP.maximumMagnitude($0) }
    }
}
