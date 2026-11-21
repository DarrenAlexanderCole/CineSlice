import Accelerate
import CoreML

/// DBS-TIGER (Tsinghua, Apache-2.0; trained on DnR, dialogue / music / effects), split into
/// speech and everything else, for one 6 s window of sound at 44.1 kHz.
///
/// The model is mono and speech-trained, so it hears each channel on its own and its speech
/// estimate is taken out of that channel; the scene keeps its stereo. What's left of the voice
/// then goes through `cleanUp`. Barks and other animal sounds are effects to it, not voices.
///
/// The network is four bundled Core ML models (made by `Tools/dbs_tiger/export.py`): the band
/// splitting front, one separator pass (run 8 times, as the model reuses its weights; in one piece
/// the unrolled network is too big for an iPhone to load), and the mask back end. Its
/// spectrogram in and out are done here exactly as `torch.stft` / `torch.istft` do them with
/// their defaults (centred, reflect-padded, unnormalised).
final class Tiger: VoiceModel {
    static let sampleRate = 44_100.0
    /// Samples in one window, the length the model was trained on.
    static let window = 264_600
    private static let fftSize = 2048
    private static let hop = 512
    private static let bins = 1025
    /// Spectrogram frames in one window: window / hop + 1, as `torch.stft` with `center`.
    private static let frames = 517
    /// `center` pads half a frame each side.
    private static let pad = fftSize / 2
    private static let paddedLength = window + 2 * pad

    var segment: Int { Self.window }

    enum ModelError: LocalizedError {
        case missingModel

        var errorDescription: String? { "The voice separation model is missing from the app." }
    }

    /// The separator's passes over the front's tokens.
    private static let passes = 8

    private let front: MLModel
    private let firstStep: MLModel
    private let step: MLModel
    private let back: MLModel
    private let fft: FFTSetup
    private let hann: [Float]
    /// The summed squared windows `torch.istft` divides by, over the padded window.
    private let envelope: [Float]

    init(computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        func load(_ name: String) throws -> MLModel {
            guard let url = Bundle(for: Tiger.self).url(forResource: name, withExtension: "mlmodelc") else {
                throw ModelError.missingModel
            }
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        front = try load("TigerFront")
        firstStep = try load("TigerStepFirst")
        step = try load("TigerStep")
        back = try load("TigerBack")
        fft = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2))!
        // Periodic Hann, as torch.hann_window.
        hann = (0..<Self.fftSize).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.fftSize)) }
        var envelope = [Float](repeating: 0, count: Self.paddedLength)
        let squared = vDSP.square(hann)
        for t in 0..<Self.frames {
            let start = t * Self.hop
            envelope.withUnsafeMutableBufferPointer { e in
                vDSP.add(e[start..<(start + Self.fftSize)], squared, result: &e[start..<(start + Self.fftSize)])
            }
        }
        self.envelope = envelope
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Separates one window. `channels` is left and right, each at most `window` long; shorter
    /// sound is padded with silence.
    func separate(_ channels: [[Float]]) throws -> VoiceStems {
        let n = min(channels[0].count, Self.window)
        let padded = channels.map { c -> [Float] in
            var x = [Float](repeating: 0, count: Self.window)
            x.replaceSubrange(0..<n, with: c[0..<n])
            return x
        }
        let left = try speech(in: padded[0])
        // A mono recording has the same sound on both sides: no need to hear it twice.
        let right = padded[1] == padded[0] ? left : try speech(in: padded[1])
        let voice = [left, right]
        return VoiceStems(
            voice: voice,
            rest: (0..<2).map { c in cleanUp(vDSP.subtract(padded[c], voice[c]), voice: voice[c]) })
    }

    /// The model's speech estimate for one channel, `window` long.
    private func speech(in x: [Float]) throws -> [Float] {
        let spec = try MLMultiArray(
            shape: [1, 2, NSNumber(value: Self.bins), NSNumber(value: Self.frames)], dataType: .float32)
        let pointer = spec.dataPointer.assumingMemoryBound(to: Float.self)
        spectrogram(x, re: pointer, im: pointer + Self.bins * Self.frames)

        func run(_ model: MLModel, _ inputs: [String: Any]) throws -> MLFeatureProvider {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        }
        let split = try run(front, ["spec": spec])
        let tokens = split.featureValue(for: "tokens")!
        let mask = split.featureValue(for: "mask")!
        var x = try run(firstStep, ["tokens": tokens, "mask": mask]).featureValue(for: "x")!
        for _ in 1..<Self.passes {
            x = try run(step, ["x": x, "tokens": tokens, "mask": mask]).featureValue(for: "next")!
        }
        let out = try run(back, [
            "separated": x, "hard": split.featureValue(for: "hard")!,
            "tokenProbs": split.featureValue(for: "tokenProbs")!, "tokenMask": split.featureValue(for: "tokenMask")!,
            "spec": spec,
        ])
        func scalars(_ name: String) -> [Float] {
            MLShapedArray<Float>(converting: out.featureValue(for: name)!.multiArrayValue!).scalars
        }
        return waveform(re: scalars("speechRe"), im: scalars("speechIm"))
    }

    /// Frames (about a second) over which the voice still left in the rest is measured.
    private static let leftoverSpan = 87
    /// How hard what's left where the voice was loud is pushed down.
    private static let cleanUpStrength: Float = 4

    /// Takes out what's left of the voice: in each frequency band, the part of `rest` that moves
    /// with the voice estimate over the last second or so is cancelled, phase and all; then the
    /// band is turned down where the voice still outweighs the rest.
    private func cleanUp(_ rest: [Float], voice: [Float]) -> [Float] {
        let count = Self.bins * Self.frames
        var rr = [Float](repeating: 0, count: count), ri = rr, vr = rr, vi = rr
        rr.withUnsafeMutableBufferPointer { re in
            ri.withUnsafeMutableBufferPointer { spectrogram(rest, re: re.baseAddress!, im: $0.baseAddress!) }
        }
        vr.withUnsafeMutableBufferPointer { re in
            vi.withUnsafeMutableBufferPointer { spectrogram(voice, re: re.baseAddress!, im: $0.baseAddress!) }
        }
        let frames = Self.frames
        let half = Self.leftoverSpan / 2
        var sums = [Double](repeating: 0, count: 3 * (frames + 1))
        for k in 0..<Self.bins {
            let row = k * frames
            // Running sums of rest × conj(voice) and |voice|², for sums over any span of frames.
            for t in 0..<frames {
                let (ar, ai, br, bi) = (rr[row + t], ri[row + t], vr[row + t], vi[row + t])
                sums[3 * (t + 1)] = sums[3 * t] + Double(ar * br + ai * bi)
                sums[3 * (t + 1) + 1] = sums[3 * t + 1] + Double(ai * br - ar * bi)
                sums[3 * (t + 1) + 2] = sums[3 * t + 2] + Double(br * br + bi * bi)
            }
            for t in 0..<frames {
                let lo = max(0, t - half), hi = min(frames, t + half + 1)
                let power = sums[3 * hi + 2] - sums[3 * lo + 2] + 1e-10
                var ar = Float((sums[3 * hi] - sums[3 * lo]) / power)
                var ai = Float((sums[3 * hi + 1] - sums[3 * lo + 1]) / power)
                // Never take out more than the estimate itself.
                let size = (ar * ar + ai * ai).squareRoot()
                if size > 1 { ar /= size; ai /= size }
                let (br, bi) = (vr[row + t], vi[row + t])
                let cr = rr[row + t] - (ar * br - ai * bi)
                let ci = ri[row + t] - (ar * bi + ai * br)
                let left = cr * cr + ci * ci
                let gain = left / (left + Self.cleanUpStrength * (br * br + bi * bi) + 1e-10)
                rr[row + t] = cr * gain
                ri[row + t] = ci * gain
            }
        }
        return waveform(re: rr, im: ri)
    }

    /// `torch.stft` (centred, reflect-padded, Hann, unnormalised). Writes [bin][frame].
    private func spectrogram(_ x: [Float], re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        let n = x.count
        let padded = (0..<Self.paddedLength).map { i -> Float in
            var j = i - Self.pad
            if j < 0 { j = -j }
            if j >= n { j = 2 * (n - 1) - j }
            return x[j]
        }
        // vDSP's forward real FFT is twice the DFT.
        var frame = [Float](repeating: 0, count: Self.fftSize)
        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imag = [Float](repeating: 0, count: Self.fftSize / 2)
        for t in 0..<Self.frames {
            padded.withUnsafeBufferPointer { p in
                vDSP.multiply(p[(t * Self.hop)..<(t * Self.hop + Self.fftSize)], hann, result: &frame)
            }
            forward(frame, &real, &imag)
            // Packed: imag[0] holds the Nyquist bin's real part.
            re[t] = real[0] * 0.5
            im[t] = 0
            re[(Self.bins - 1) * Self.frames + t] = imag[0] * 0.5
            im[(Self.bins - 1) * Self.frames + t] = 0
            for k in 1..<(Self.bins - 1) {
                re[k * Self.frames + t] = real[k] * 0.5
                im[k * Self.frames + t] = imag[k] * 0.5
            }
        }
    }

    /// `torch.istft` of a [bin][frame] spectrum, `window` long.
    private func waveform(re: [Float], im: [Float]) -> [Float] {
        var sum = [Float](repeating: 0, count: Self.paddedLength)
        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imag = [Float](repeating: 0, count: Self.fftSize / 2)
        var frame = [Float](repeating: 0, count: Self.fftSize)
        // vDSP's inverse is n times the inverse DFT.
        let scale = 1 / Float(Self.fftSize)
        for t in 0..<Self.frames {
            real[0] = re[t]
            imag[0] = re[(Self.bins - 1) * Self.frames + t]
            for k in 1..<(Self.bins - 1) {
                real[k] = re[k * Self.frames + t]
                imag[k] = im[k * Self.frames + t]
            }
            inverse(&real, &imag, &frame)
            vDSP.multiply(frame, hann, result: &frame)
            vDSP.multiply(scale, frame, result: &frame)
            sum.withUnsafeMutableBufferPointer { s in
                let start = t * Self.hop
                vDSP.add(s[start..<(start + Self.fftSize)], frame, result: &s[start..<(start + Self.fftSize)])
            }
        }
        return vDSP.divide(
            sum[Self.pad..<(Self.pad + Self.window)], envelope[Self.pad..<(Self.pad + Self.window)])
    }

    private func forward(_ frame: [Float], _ real: inout [Float], _ imag: inout [Float]) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBytes {
                    vDSP_ctoz(
                        $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(11), FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func inverse(_ real: inout [Float], _ imag: inout [Float], _ frame: inout [Float]) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(11), FFTDirection(kFFTDirection_Inverse))
                frame.withUnsafeMutableBytes {
                    vDSP_ztoc(
                        &split, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(Self.fftSize / 2))
                }
            }
        }
    }
}
