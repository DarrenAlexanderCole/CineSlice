import Accelerate
import CoreML

/// Meta's HTDemucs source separation (MIT licence), split into voice and everything else, for one
/// 7.8 s segment of stereo sound at 44.1 kHz.
///
/// The bundled Core ML model (`HTDemucs.mlpackage`, made by `Tools/demucs/export.py`) is the
/// network alone; the spectrogram it reads and the one it writes are done here, exactly as
/// demucs's `_spec` and `_ispec` do them, so its output matches the PyTorch model. A stem is the
/// inverse spectrogram of its spectral output plus its waveform output.
final class Demucs {
    static let sampleRate = 44_100.0
    /// Samples in one segment, the length the model was trained on.
    static let segment = 343_980
    private static let fftSize = 4096
    private static let hop = 1024
    private static let bins = 2048
    /// Spectrogram frames in one segment: segment / hop, rounded up.
    private static let frames = 336
    /// demucs pads the signal by 3/4 of a hop on each side, so frames line up with the waveform.
    private static let pad = hop / 2 * 3
    private static let paddedLength = frames * hop + 2 * pad

    struct Stems {
        /// Left and right, each `segment` long.
        var voice: [[Float]]
        var rest: [[Float]]
    }

    enum DemucsError: LocalizedError {
        case missingModel

        var errorDescription: String? { "The voice separation model is missing from the app." }
    }

    private let model: MLModel
    private let fft: FFTSetup
    private let window: [Float]

    /// The Neural Engine can't compile this model (iPhone 17 Pro, iOS 26), and trying first costs
    /// seconds before Core ML falls back, so it runs on the GPU.
    init(computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        guard let url = Bundle(for: Demucs.self).url(forResource: "HTDemucs", withExtension: "mlmodelc") else {
            throw DemucsError.missingModel
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
        fft = vDSP_create_fftsetup(vDSP_Length(12), FFTRadix(kFFTRadix2))!
        // Periodic Hann, as torch.hann_window.
        window = (0..<Self.fftSize).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.fftSize)) }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Separates one segment. `channels` is left and right, each at most `segment` long; shorter
    /// sound is padded with silence, as demucs does.
    func separate(_ channels: [[Float]]) throws -> Stems {
        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: Self.segment)], dataType: .float32)
        let spec = try MLMultiArray(
            shape: [1, 4, NSNumber(value: Self.bins), NSNumber(value: Self.frames)], dataType: .float32)
        let mixPointer = mix.dataPointer.assumingMemoryBound(to: Float.self)
        let specPointer = spec.dataPointer.assumingMemoryBound(to: Float.self)
        mixPointer.initialize(repeating: 0, count: 2 * Self.segment)
        for c in 0..<2 {
            var x = [Float](repeating: 0, count: Self.segment)
            let n = min(channels[c].count, Self.segment)
            x.replaceSubrange(0..<n, with: channels[c][0..<n])
            (mixPointer + c * Self.segment).update(from: x, count: Self.segment)
            spectrogram(x, re: specPointer + (2 * c) * Self.bins * Self.frames,
                im: specPointer + (2 * c + 1) * Self.bins * Self.frames)
        }

        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mix, "spec": spec]))
        func scalars(_ name: String) -> [Float] {
            MLShapedArray<Float>(converting: out.featureValue(for: name)!.multiArrayValue!).scalars
        }
        func stem(_ spectral: [Float], _ wave: [Float]) -> [[Float]] {
            (0..<2).map { c in
                var x = waveform(spectral, channel: c)
                vDSP.add(x, wave[(c * Self.segment)..<((c + 1) * Self.segment)], result: &x)
                return x
            }
        }
        return Stems(
            voice: stem(scalars("voiceSpec"), scalars("voiceWave")),
            rest: stem(scalars("restSpec"), scalars("restWave")))
    }

    /// demucs `_spec`: reflect-pad, normalised STFT, last bin dropped. Writes [bin][frame].
    private func spectrogram(_ x: [Float], re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let n = x.count
        let padded = (0..<Self.paddedLength).map { i -> Float in
            var j = i - Self.pad
            if j < 0 { j = -j }
            if j >= n { j = 2 * (n - 1) - j }
            return x[j]
        }
        // vDSP's forward real FFT is twice the DFT; torch's `normalized` divides by sqrt(n).
        let scale = 0.5 / Float(Self.fftSize).squareRoot()
        var frame = [Float](repeating: 0, count: Self.fftSize)
        var real = [Float](repeating: 0, count: Self.bins)
        var imag = [Float](repeating: 0, count: Self.bins)
        for t in 0..<Self.frames {
            padded.withUnsafeBufferPointer { p in
                vDSP.multiply(p[(t * Self.hop)..<(t * Self.hop + Self.fftSize)], window, result: &frame)
            }
            forward(frame, &real, &imag)
            // Packed: imag[0] is the Nyquist bin, which demucs drops.
            imag[0] = 0
            for k in 0..<Self.bins {
                re[k * Self.frames + t] = real[k] * scale
                im[k * Self.frames + t] = imag[k] * scale
            }
        }
    }

    /// demucs `_ispec` for one channel of a spectral output laid out [channel][re/im][bin][frame].
    private func waveform(_ spectral: [Float], channel c: Int) -> [Float] {
        let plane = Self.bins * Self.frames
        let reBase = (2 * c) * plane
        let imBase = (2 * c + 1) * plane
        var sum = [Float](repeating: 0, count: Self.paddedLength)
        var real = [Float](repeating: 0, count: Self.bins)
        var imag = [Float](repeating: 0, count: Self.bins)
        var frame = [Float](repeating: 0, count: Self.fftSize)
        // vDSP's inverse is n times the inverse DFT; torch's `normalized` multiplies by sqrt(n).
        let scale = 1 / Float(Self.fftSize).squareRoot()
        for t in 0..<Self.frames {
            for k in 0..<Self.bins {
                real[k] = spectral[reBase + k * Self.frames + t]
                imag[k] = spectral[imBase + k * Self.frames + t]
            }
            imag[0] = 0  // the Nyquist bin, zero as in demucs
            inverse(&real, &imag, &frame)
            vDSP.multiply(frame, window, result: &frame)
            vDSP.multiply(scale, frame, result: &frame)
            sum.withUnsafeMutableBufferPointer { s in
                let start = t * Self.hop
                vDSP.add(s[start..<(start + Self.fftSize)], frame, result: &s[start..<(start + Self.fftSize)])
            }
        }
        // Squared Hann windows at a quarter-window hop sum to 1.5 throughout what's kept.
        return vDSP.divide(Array(sum[Self.pad..<(Self.pad + Self.segment)]), 1.5)
    }

    private func forward(_ frame: [Float], _ real: inout [Float], _ imag: inout [Float]) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.bins))
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(12), FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func inverse(_ real: inout [Float], _ imag: inout [Float], _ frame: inout [Float]) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(12), FFTDirection(kFFTDirection_Inverse))
                frame.withUnsafeMutableBytes {
                    vDSP_ztoc(&split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(Self.bins))
                }
            }
        }
    }
}
