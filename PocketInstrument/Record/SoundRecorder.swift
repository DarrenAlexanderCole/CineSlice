@preconcurrency import AVFoundation
import Accelerate
import Observation

/// Sound mode's recorder: the microphone through a 10-band graphic EQ, metered and analysed
/// all the time it's open (not only while recording), written to a file while a take runs, and
/// heard in headphones when monitoring is on. Monitoring is only offered with headphones in, so
/// the speaker never feeds back into the mic. The EQ shapes what's recorded, not just what's
/// heard; its settings are kept for the next visit.
@MainActor
@Observable
final class SoundRecorder {
    /// The graphic EQ's bands, an octave apart.
    nonisolated static let bands: [Float] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    nonisolated static let gainRange: ClosedRange<Float> = -12...12
    /// The analyser's columns, a third of an octave apart from 25 Hz to 20 kHz.
    nonisolated static let spectrumColumns = 30

    /// Each band's boost or cut, in dB.
    private(set) var gains = [Float](repeating: 0, count: SoundRecorder.bands.count)
    /// A trim on the whole signal before it's recorded, in dB.
    private(set) var trim: Float = 0
    private(set) var isEQOn = true
    /// Headphones (wired, Bluetooth, USB) are the output, so monitoring is safe.
    private(set) var hasHeadphones = false
    /// The microphone is heard in the headphones.
    private(set) var isMonitoring = false
    /// The signal's level after the EQ, 0…1 over −60…0 dB, and its recent peak.
    private(set) var level: Float = 0
    private(set) var peak: Float = 0
    /// The spectrum after the EQ, each column 0…1 over −80…0 dB.
    private(set) var spectrum = [Float](repeating: 0, count: SoundRecorder.spectrumColumns)
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 48_000
    private(set) var channels = 1
    private(set) var inputName = "Microphone"

    var onError: (String) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private let eq = AVAudioUnitEQ(numberOfBands: SoundRecorder.bands.count)
    private let monitor = AVAudioMixerNode()
    private let tap = SoundTap()
    private var observers: [NSObjectProtocol] = []

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.gainsKey) as? [Float], saved.count == gains.count {
            gains = saved.map { min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, $0)) }
        }
        trim = UserDefaults.standard.float(forKey: Self.trimKey)
        isEQOn = UserDefaults.standard.object(forKey: Self.onKey) as? Bool ?? true
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.bands[i]
            band.bandwidth = 1
            band.bypass = false
        }
        applyEQ()
        tap.recorder = self
        engine.attach(eq)
        engine.attach(monitor)
    }

    // MARK: Running

    /// Opens the microphone: metering, the analyser and monitoring run from now until `stop`.
    func start() {
        guard !isRunning else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            // Short buffers, so what's heard in the headphones isn't late.
            try? audio.setPreferredIOBufferDuration(0.005)
            try audio.setActive(true)
            try build()
            try engine.start()
            isRunning = true
            observe()
            readRoute()
        } catch {
            teardown()
            onError("Couldn't open the microphone. \(error.localizedDescription)")
        }
    }

    /// Closes the microphone (finishing a take first) and gives the app's sound back.
    func stop() {
        guard isRunning else { return }
        teardown()
        CameraRig.restorePlayback()
    }

    private func build() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw SoundError.noMicrophone }
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Microphone"
        engine.disconnectNodeOutput(input)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(monitor)
        engine.connect(input, to: eq, format: format)
        engine.connect(eq, to: monitor, format: format)
        engine.connect(monitor, to: engine.mainMixerNode, format: format)
        monitor.outputVolume = isMonitoring ? 1 : 0
        tap.prepare(sampleRate: format.sampleRate)
        eq.installTap(onBus: 0, bufferSize: 2048, format: format) { [tap] buffer, _ in tap.receive(buffer) }
    }

    private func teardown() {
        _ = tap.finish()
        eq.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        isRunning = false
        level = 0
        peak = 0
        spectrum = spectrum.map { _ in 0 }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.readRoute() }
            })
        // A new route (headphones in or out) stops the engine: start it again on the new one.
        observers.append(
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            })
    }

    private func restart() {
        guard isRunning else { return }
        let wasRecording = isRecording
        let finished = tap.finish()
        eq.removeTap(onBus: 0)
        engine.stop()
        do {
            try build()
            try engine.start()
        } catch {
            teardown()
            onError("The microphone stopped. \(error.localizedDescription)")
        }
        if wasRecording, let finished { onInterruptedTake?(finished) }
    }

    /// Hands over a take cut short by the sound changing route; what was recorded is kept.
    var onInterruptedTake: ((URL) -> Void)?

    private func readRoute() {
        let headphones: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .airPlay, .lineOut,
        ]
        hasHeadphones = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            headphones.contains($0.portType)
        }
        if !hasHeadphones, isMonitoring { setMonitoring(false) }
    }

    // MARK: Recording

    private(set) var isRecording = false

    /// Starts writing the signal, after the EQ, to a new file.
    func startRecording(to url: URL) throws {
        guard isRunning else { throw SoundError.noMicrophone }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: min(2, channels),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let format = eq.outputFormat(forBus: 0)
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        tap.begin(file)
        isRecording = true
    }

    /// Stops writing and returns the finished file.
    func stopRecording() -> URL? {
        isRecording = false
        return tap.finish()
    }

    // MARK: Settings

    func setGain(_ db: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, db))
        applyEQ()
    }

    func setTrim(_ db: Float) {
        trim = min(Self.gainRange.upperBound, max(Self.gainRange.lowerBound, db))
        applyEQ()
    }

    func setEQOn(_ on: Bool) {
        isEQOn = on
        Haptics.detent()
        applyEQ()
    }

    /// Every band back to 0 dB.
    func flatten() {
        gains = gains.map { _ in 0 }
        Haptics.press()
        applyEQ()
    }

    func setMonitoring(_ on: Bool) {
        isMonitoring = on && hasHeadphones
        monitor.outputVolume = isMonitoring ? 1 : 0
        Haptics.detent()
    }

    /// Saves the settings for next time; called as a fader is let go.
    func save() {
        UserDefaults.standard.set(gains, forKey: Self.gainsKey)
        UserDefaults.standard.set(trim, forKey: Self.trimKey)
        UserDefaults.standard.set(isEQOn, forKey: Self.onKey)
    }

    private func applyEQ() {
        for (i, band) in eq.bands.enumerated() { band.gain = isEQOn ? gains[i] : 0 }
        eq.globalGain = trim
    }

    /// The EQ's effect at `hz`, in dB, for its curve: each band's bell, an octave wide.
    func response(at hz: Float) -> Float {
        guard isEQOn else { return trim }
        var total = trim
        for (i, centre) in Self.bands.enumerated() where gains[i] != 0 {
            let octaves = log2(hz / centre)
            total += gains[i] * exp(-(octaves * octaves) / (2 * 0.42 * 0.42))
        }
        return total
    }

    /// The analyser's column frequencies.
    nonisolated static let columnFrequencies: [Float] = (0..<spectrumColumns).map { 25 * pow(2, Float($0) / 3) }

    // MARK: From the audio thread

    fileprivate func received(level newLevel: Float, spectrum newSpectrum: [Float]?) {
        // Rises at once, falls away gently, like a meter's needle.
        level = max(newLevel, level - 0.04)
        peak = max(newLevel, peak - 0.008)
        guard let newSpectrum else { return }
        for i in spectrum.indices {
            spectrum[i] = max(newSpectrum[i], spectrum[i] - 0.05)
        }
    }

    private enum SoundError: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "No microphone is available." }
    }

    private static let gainsKey = "record.eq.gains"
    private static let trimKey = "record.eq.trim"
    private static let onKey = "record.eq.on"
}

/// The signal off the audio thread: writes it to the take's file and measures its level and
/// spectrum, handing those to the recorder on the main actor.
private final class SoundTap: @unchecked Sendable {
    weak var recorder: SoundRecorder?

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var sampleRate: Double = 48_000
    private static let size = 2048
    private var window = [Float](repeating: 0, count: SoundTap.size)
    private var hann = [Float](repeating: 0, count: SoundTap.size)
    private var samples = [Float](repeating: 0, count: SoundTap.size)
    private var fft: FFTSetup?
    private var lastSent = 0.0

    init() {
        vDSP_hann_window(&hann, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        fft = vDSP_create_fftsetup(vDSP_Length(log2(Float(Self.size))), FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fft { vDSP_destroy_fftsetup(fft) }
    }

    func prepare(sampleRate: Double) {
        lock.withLock { self.sampleRate = sampleRate }
    }

    func begin(_ file: AVAudioFile) {
        lock.withLock { self.file = file }
    }

    /// Stops writing; the file closes as it's let go. Its address, or nil without a take.
    func finish() -> URL? {
        lock.withLock {
            let url = file?.url
            file = nil
            return url
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            do {
                try file?.write(from: buffer)
            } catch {
                file = nil
            }
        }
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let first = data[0]

        // Keep the latest 2048 samples of the first channel.
        if frames >= Self.size {
            samples.withUnsafeMutableBufferPointer { out in
                out.baseAddress!.update(from: first + (frames - Self.size), count: Self.size)
            }
        } else {
            samples.removeFirst(frames)
            samples.append(contentsOf: UnsafeBufferPointer(start: first, count: frames))
        }

        var rms: Float = 0
        vDSP_rmsqv(first, 1, &rms, vDSP_Length(frames))
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 60) / 60))

        // The analyser about 25 times a second is plenty.
        let now = CACurrentMediaTime()
        guard now - lastSent > 0.04 else {
            Task { @MainActor [weak recorder] in recorder?.received(level: level, spectrum: nil) }
            return
        }
        lastSent = now
        let columns = spectrum()
        Task { @MainActor [weak recorder] in recorder?.received(level: level, spectrum: columns) }
    }

    /// The window's power in each third-octave column, 0…1 over −80…0 dB.
    private func spectrum() -> [Float] {
        guard let fft else { return [Float](repeating: 0, count: SoundRecorder.spectrumColumns) }
        let n = Self.size
        vDSP_vmul(samples, 1, hann, 1, &window, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                window.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2(Float(n))), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        let binWidth = Float(sampleRate) / Float(n)
        // zrip's output is twice the transform's; the Hann window halves a sine's amplitude.
        let scale = 1 / Float(n * n)
        return SoundRecorder.columnFrequencies.map { centre in
            let low = max(1, Int(centre / pow(2, 1 / 6) / binWidth))
            let high = min(n / 2 - 1, max(low, Int(centre * pow(2, 1 / 6) / binWidth)))
            var total: Float = 0
            for bin in low...high { total += power[bin] }
            let db = 10 * log10(max(total * scale, 1e-12))
            return max(0, min(1, (db + 80) / 80))
        }
    }
}
