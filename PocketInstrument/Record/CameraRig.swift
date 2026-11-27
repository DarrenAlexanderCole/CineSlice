@preconcurrency import AVFoundation
import CoreImage
import EditCore
import Observation
import UIKit

/// What a take on the Record page produced, still in a temporary file (or memory, for a photo)
/// until the project adopts it, with the look it was shot through.
enum RecordedTake {
    case video(URL, Look?)
    case photo(Data, Look?)
    case sound(URL)
}

/// The camera's settings as it shoots, for the readout beside the histogram.
struct CameraData: Equatable {
    /// The lens's f-number.
    var aperture: Float = 0
    /// How long each frame is exposed, in seconds.
    var shutter: Double = 0
    var iso: Float = 0
    /// The white balance's colour temperature, in kelvin.
    var kelvin: Float = 0
}

/// The Record page's camera and microphone. Video and photo go through one capture session
/// (the back or front camera plus the microphone); sound mode stops it and hands the microphone
/// to the sound recorder (EQ, analyser, headphone monitoring), so the mic is never held twice.
/// The camera runs automatically until a setting is taken by hand: shutter and ISO together,
/// exposure compensation while exposure is automatic, white balance, and the frame rate. Takes are recorded the way the phone is
/// held (the rotation coordinator reads it from gravity, not from the screen), so a phone held
/// sideways records a wide picture. Every take is handed to `onTake` as soon as it's finished.
@MainActor
@Observable
final class CameraRig {
    enum Mode: CaseIterable {
        case video, photo, sound

        var title: String {
            switch self {
            case .video: "VIDEO"
            case .photo: "PHOTO"
            case .sound: "SOUND"
            }
        }
    }

    enum Access { case unknown, granted, denied }

    private(set) var mode: Mode
    private(set) var cameraAccess = Access.unknown
    private(set) var micAccess = Access.unknown
    /// No camera on this device (the simulator): video and photo can't be taken.
    private(set) var hasCamera = true
    private(set) var position = AVCaptureDevice.Position.back
    /// A video or sound take is running.
    private(set) var isRecording = false
    /// When the running take began, for the counter.
    private(set) var recordingStarted: Date?
    /// A flash on the picture as a photo is taken.
    private(set) var flash = false
    /// The picture's red, green and blue levels, about ten times a second.
    private(set) var histogram: RGBHistogram?
    /// The zoom as the phone's camera app shows it: 1 is the main camera, 0.5 the ultra wide.
    private(set) var zoom: Double = 1
    private(set) var zoomRange: ClosedRange<Double> = 1...1
    /// The zooms worth marking on the ring: the usual stops, and where the camera changes lens.
    private(set) var zoomMarks: [Double] = [1]
    /// Where the focus ring is turned: `autoFocusDial` is automatic, 0…1 the lens from its
    /// nearest to its farthest.
    private(set) var focusDial = CameraRig.autoFocusDial
    /// The look on the live picture and on every take shot with it; nil is the clean picture.
    private(set) var look: Look?
    /// The camera's settings, a few times a second.
    private(set) var cameraData = CameraData()
    /// The live picture can be shown through a look (the phone can afford the frame copy).
    private(set) var canShowLooks = true
    /// The camera's lens can be set by hand, so the focus ring turns it.
    private(set) var canFocus = false

    /// Exposure is the camera's own; off, `shutterSpeed` and `iso` hold.
    private(set) var isAutoExposure = true
    /// The manual shutter, in seconds, and ISO.
    private(set) var shutterSpeed: Double = 1.0 / 60
    private(set) var iso: Float = 100
    /// Brighter or darker than the camera's own exposure, in stops, while it's automatic.
    private(set) var exposureBias: Float = 0
    private(set) var shutterRange: ClosedRange<Double> = 1.0 / 8000...1.0 / 30
    private(set) var isoRange: ClosedRange<Float> = 50...1600
    private(set) var biasRange: ClosedRange<Float> = -2...2
    /// The camera takes exposure by hand.
    private(set) var canExpose = false
    /// White balance is the camera's own; off, `kelvin` and `tint` hold.
    private(set) var isAutoWhiteBalance = true
    private(set) var kelvin: Float = 5600
    /// Green (−) to magenta (+).
    private(set) var tint: Float = 0
    private(set) var canBalance = false
    /// The frames per second video is shot at, and the rates this camera offers.
    private(set) var frameRate = 30
    private(set) var frameRates = [30]
    static let kelvinRange: ClosedRange<Float> = 2500...9000
    static let tintRange: ClosedRange<Float> = -50...50

    /// Sound mode's microphone.
    let sound = SoundRecorder()

    static let autoFocusDial = -0.3
    var isAutoFocus: Bool { focusDial < Self.autoFocusDial / 2 }

    var onTake: (RecordedTake) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    nonisolated let session = AVCaptureSession()
    private nonisolated let queue = DispatchQueue(label: "cineslice.record.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let frameOutput = AVCaptureVideoDataOutput()
    private nonisolated let frameQueue = DispatchQueue(label: "cineslice.record.frames")
    /// One of the camera's lenses as a camera of its own, and where it starts on the zoom scale
    /// (0.5 the ultra wide, 1 the main camera, 3 or 5 the telephoto).
    private struct Lens {
        let device: AVCaptureDevice
        let base: Double
        /// Where, on the zoom scale, a combined camera changes lens inside itself.
        var changes: [Double] = []
    }

    /// How the back camera's lenses are used. ZOOM is the phone's combined camera: one smooth
    /// zoom across every lens, but it won't take focus, exposure or white balance by hand, only
    /// hold them (lock). PRIME uses each lens on its own, with everything by hand; the zoom ring
    /// changes lens at its marks.
    enum LensMode: String {
        case zoom, prime
    }

    private(set) var lensMode = LensMode.zoom
    /// This side can choose between ZOOM and PRIME (a back camera with more than one lens).
    private(set) var hasLensChoice = false

    /// This side's lenses, widest first: the combined camera alone for ZOOM, each lens for PRIME.
    private var lenses: [Lens] = []
    /// Exposure and white balance can be held where the camera has them, though not set.
    private(set) var canLockExposure = false
    private(set) var canLockBalance = false
    private var photoSize: CMVideoDimensions?
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    private var dataTask: Task<Void, Never>?
    /// The look a running video take started with: the whole take keeps it.
    private var takeLook: Look?
    private let delegate = CaptureDelegate()
    private let frameTap = FrameTap()

    init(mode: Mode) {
        self.mode = mode
        delegate.rig = self
        frameTap.rig = self
        if let saved = UserDefaults.standard.object(forKey: Self.frameRateKey) as? Int { frameRate = saved }
        lensMode = UserDefaults.standard.string(forKey: Self.lensModeKey).flatMap(LensMode.init) ?? .zoom
        sound.onError = { [weak self] in self?.onError($0) }
        sound.onInterruptedTake = { [weak self] url in
            guard let self, self.mode == .sound, self.isRecording else { return }
            self.isRecording = false
            self.recordingStarted = nil
            self.onTake(.sound(url))
        }
    }

    // MARK: Start / stop

    /// Asks for what the mode needs and starts it.
    func start() async {
        micAccess = await Self.access(for: .audio)
        if mode == .sound {
            if micAccess == .granted { sound.start() }
        } else {
            await startCamera()
        }
        dataTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.readCameraData()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Stops everything and gives the app's sound back to playback.
    func stop() {
        if isRecording { stopRecording() }
        dataTask?.cancel()
        sound.stop()
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        Self.restorePlayback()
    }

    func setMode(_ new: Mode) {
        guard new != mode, !isRecording else { return }
        let old = mode
        mode = new
        Haptics.detent()
        if new == .sound {
            // The camera lets go of the microphone before the recorder takes it.
            let session = session
            Task {
                await withCheckedContinuation { done in
                    queue.async {
                        if session.isRunning { session.stopRunning() }
                        done.resume()
                    }
                }
                if mode == .sound, micAccess == .granted { sound.start() }
            }
        } else if old == .sound {
            sound.stop()
            Task { await startCamera() }
        }
    }

    private func startCamera() async {
        cameraAccess = await Self.access(for: .video)
        guard cameraAccess == .granted else { return }
        if !configured {
            configured = true
            configure()
        }
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        lenses = Self.lenses(at: position, mode: lensMode)
        guard let camera = (lenses.first { $0.base == 1 } ?? lenses.first)?.device,
            let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
        else {
            hasCamera = false
            return
        }
        session.addInput(input)
        videoInput = input
        if micAccess == .granted, let mic = AVCaptureDevice.default(for: .audio),
            let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput)
        {
            session.addInput(micInput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .balanced
            // The next photo can be taken while the last is still being processed.
            if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
            if photoOutput.isFastCapturePrioritizationSupported {
                photoOutput.isFastCapturePrioritizationEnabled = true
            }
        }
        stabilize()
        // A copy of the picture for the histogram; the recording itself is untouched.
        frameOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(frameTap, queue: frameQueue)
        if session.canAddOutput(frameOutput) {
            session.addOutput(frameOutput)
            // Some older phones can't afford it alongside the recording: go without.
            if session.hardwareCost > 1 { session.removeOutput(frameOutput) }
        }
        canShowLooks = session.outputs.contains(frameOutput)
        readLenses()
    }

    /// The live picture's layer, once it's on screen: the session plays into it and it turns
    /// with the phone.
    func attach(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
        followRotation()
    }

    /// Keeps the live picture level as the phone turns; takes read the angle as they start.
    private func followRotation() {
        guard let device = videoInput?.device else { return }
        // The frame copy (drawn for looks) is mirrored for the front camera, like the preview.
        if let frames = frameOutput.connection(with: .video), frames.isVideoMirroringSupported {
            frames.automaticallyAdjustsVideoMirroring = false
            frames.isVideoMirrored = device.position == .front
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        let key = \AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelPreview
        rotationObservation = coordinator.observe(key, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                // The look's picture is drawn from the frame copy, so it turns with the preview.
                if let frames = self?.frameOutput.connection(with: .video),
                    frames.isVideoRotationAngleSupported(angle)
                {
                    frames.videoRotationAngle = angle
                }
                guard let connection = self?.previewLayer?.connection, connection.isVideoRotationAngleSupported(angle)
                else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    private func applyCaptureRotation(to connection: AVCaptureConnection?) {
        guard let connection, let angle = rotation?.videoRotationAngleForHorizonLevelCapture,
            connection.isVideoRotationAngleSupported(angle)
        else { return }
        connection.videoRotationAngle = angle
    }

    /// Back camera to front, or front to back.
    func flipCamera() {
        guard !isRecording, let old = videoInput else { return }
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        let nextLenses = Self.lenses(at: next, mode: lensMode)
        guard let camera = (nextLenses.first { $0.base == 1 } ?? nextLenses.first)?.device,
            let input = try? AVCaptureDeviceInput(device: camera)
        else { return }
        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            position = next
            lenses = nextLenses
        } else {
            session.addInput(old)
        }
        stabilize()
        session.commitConfiguration()
        readLenses()
        Haptics.detent()
    }

    // MARK: Look and readout

    /// Shoots through `look` from now on (nil: the clean picture); the live picture shows it.
    func setLook(_ look: Look?) {
        guard !isRecording || mode == .photo else { return }
        self.look = look
        frameTap.look = look
        Haptics.detent()
    }

    /// Where the picture through the look is shown, once it's on screen.
    func attachLookRenderer(_ renderer: AVSampleBufferVideoRenderer) {
        frameTap.renderer = renderer
    }

    private func readCameraData() {
        guard let device = videoInput?.device, mode != .sound else { return }
        let gains = device.deviceWhiteBalanceGains
        let range = 1...device.maxWhiteBalanceGain
        let valid = range.contains(gains.redGain) && range.contains(gains.greenGain) && range.contains(gains.blueGain)
        let next = CameraData(
            aperture: device.lensAperture, shutter: device.exposureDuration.seconds, iso: device.iso,
            kelvin: valid ? device.temperatureAndTintValues(for: gains).temperature : 0)
        if next != cameraData { cameraData = next }
    }

    // MARK: Exposure, white balance, frame rate

    /// What this camera can do by hand.
    private func learn(_ device: AVCaptureDevice) {
        let format = device.activeFormat
        canFocus = device.isLockingFocusWithCustomLensPositionSupported
        canExpose = device.isExposureModeSupported(.custom)
        canBalance = device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        canLockExposure = device.isExposureModeSupported(.locked)
        canLockBalance = device.isWhiteBalanceModeSupported(.locked)
        hasLensChoice = Self.combinedCamera(at: position) != nil
        isoRange = format.minISO...max(format.minISO, format.maxISO)
        let low = max(1.0 / 8000, format.minExposureDuration.seconds)
        shutterRange = low...max(low, format.maxExposureDuration.seconds)
        biasRange = max(-3, device.minExposureTargetBias)...min(3, device.maxExposureTargetBias)
        let ranges = format.videoSupportedFrameRateRanges
        frameRates = [24, 25, 30, 48, 50, 60].filter { rate in
            ranges.contains { Double(rate) >= $0.minFrameRate && Double(rate) <= $0.maxFrameRate }
        }
        if frameRates.isEmpty { frameRates = [30] }
    }

    /// After a change of lens or side: learns the camera and carries every setting taken by hand
    /// onto it (or back to automatic where this camera can't hold it).
    private func lensChanged() {
        guard let device = videoInput?.device else { return }
        learn(device)
        choosePhotoSize(for: device)
        followRotation()
        if !canFocus { focusDial = Self.autoFocusDial }
        turnFocus(to: focusDial)
        // A held (locked) setting doesn't carry to another camera: it goes back to automatic.
        if !canExpose { isAutoExposure = true }
        if !canBalance { isAutoWhiteBalance = true }
        exposureBias = min(biasRange.upperBound, max(biasRange.lowerBound, exposureBias))
        let (autoExposure, autoBalance, bias) = (isAutoExposure, isAutoWhiteBalance, exposureBias)
        adjust(device) { device in
            if autoExposure, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(bias, completionHandler: nil)
            if autoBalance, device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
        setFrameRate(frameRates.contains(frameRate) ? frameRate : frameRates.contains(30) ? 30 : frameRates[0])
        if !isAutoExposure {
            shutterSpeed = min(longestShutter, max(shutterRange.lowerBound, shutterSpeed))
            iso = min(isoRange.upperBound, max(isoRange.lowerBound, iso))
            applyExposure()
        }
        if !isAutoWhiteBalance { setWhiteBalance() }
    }

    /// The longest shutter the frame rate allows: one frame.
    var longestShutter: Double { min(shutterRange.upperBound, 1 / Double(frameRate)) }

    /// Shoots video at `rate` frames a second.
    func setFrameRate(_ rate: Int) {
        guard let device = videoInput?.device, frameRates.contains(rate), !isRecording else { return }
        frameRate = rate
        UserDefaults.standard.set(rate, forKey: Self.frameRateKey)
        let frame = CMTime(value: 1, timescale: CMTimeScale(rate))
        adjust(device) { device in
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
        }
        if !isAutoExposure, shutterSpeed > longestShutter { setShutter(longestShutter) }
    }

    /// Holds the shutter at `seconds`; exposure becomes manual, keeping the ISO it had.
    func setShutter(_ seconds: Double) {
        guard canExpose else { return }
        takeExposure()
        shutterSpeed = min(longestShutter, max(shutterRange.lowerBound, seconds))
        applyExposure()
    }

    /// Holds the ISO; exposure becomes manual, keeping the shutter it had.
    func setISO(_ value: Float) {
        guard canExpose else { return }
        takeExposure()
        iso = min(isoRange.upperBound, max(isoRange.lowerBound, value))
        applyExposure()
    }

    /// Manual exposure, starting where the camera had it, and back to automatic.
    /// Where exposure can't be set by hand (ZOOM), it's held where the camera has it instead.
    func toggleAutoExposure() {
        guard canExpose || canLockExposure, let device = videoInput?.device else { return }
        Haptics.detent()
        if isAutoExposure, canExpose {
            takeExposure()
            applyExposure()
        } else if isAutoExposure {
            isAutoExposure = false
            shutterSpeed = device.exposureDuration.seconds
            iso = device.iso
            adjust(device) { $0.exposureMode = .locked }
        } else {
            isAutoExposure = true
            adjust(device) { $0.exposureMode = .continuousAutoExposure }
        }
    }

    /// Brighter or darker than the camera's own exposure, in stops.
    func setExposureBias(_ stops: Float) {
        guard let device = videoInput?.device else { return }
        exposureBias = min(biasRange.upperBound, max(biasRange.lowerBound, stops))
        let bias = exposureBias
        adjust(device) { $0.setExposureTargetBias(bias, completionHandler: nil) }
    }

    private func takeExposure() {
        guard isAutoExposure, let device = videoInput?.device else { return }
        isAutoExposure = false
        shutterSpeed = min(longestShutter, max(shutterRange.lowerBound, device.exposureDuration.seconds))
        iso = min(isoRange.upperBound, max(isoRange.lowerBound, device.iso))
    }

    private func applyExposure() {
        guard let device = videoInput?.device else { return }
        let duration = CMTime(seconds: shutterSpeed, preferredTimescale: 1_000_000)
        let iso = iso
        adjust(device) { $0.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil) }
    }

    /// Holds the white balance at `kelvin` and `tint`.
    func setWhiteBalance(kelvin: Float? = nil, tint: Float? = nil) {
        guard canBalance, let device = videoInput?.device else { return }
        if isAutoWhiteBalance {
            isAutoWhiteBalance = false
            self.kelvin = cameraData.kelvin > 0 ? cameraData.kelvin : 5600
            self.tint = 0
        }
        if let kelvin { self.kelvin = min(Self.kelvinRange.upperBound, max(Self.kelvinRange.lowerBound, kelvin)) }
        if let tint { self.tint = min(Self.tintRange.upperBound, max(Self.tintRange.lowerBound, tint)) }
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: self.kelvin, tint: self.tint)
        var gains = device.deviceWhiteBalanceGains(for: values)
        let top = device.maxWhiteBalanceGain
        gains.redGain = min(top, max(1, gains.redGain))
        gains.greenGain = min(top, max(1, gains.greenGain))
        gains.blueGain = min(top, max(1, gains.blueGain))
        adjust(device) { $0.setWhiteBalanceModeLocked(with: gains, completionHandler: nil) }
    }

    /// Holds the white balance where the camera had it, and back to automatic.
    /// Where white balance can't be set by hand (ZOOM), it's held where the camera has it instead.
    func toggleAutoWhiteBalance() {
        guard canBalance || canLockBalance, let device = videoInput?.device else { return }
        Haptics.detent()
        if isAutoWhiteBalance, canBalance {
            setWhiteBalance()
        } else if isAutoWhiteBalance {
            isAutoWhiteBalance = false
            kelvin = cameraData.kelvin > 0 ? cameraData.kelvin : kelvin
            tint = 0
            adjust(device) { $0.whiteBalanceMode = .locked }
        } else {
            isAutoWhiteBalance = true
            adjust(device) { $0.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
    }

    // MARK: Lens

    /// Learns this side's lenses and starts at 1×, everything automatic.
    private func readLenses() {
        guard let top = lenses.last, let widest = lenses.first else { return }
        let high = min(10, top.base * Double(top.device.maxAvailableVideoZoomFactor))
        zoomRange = widest.base...max(widest.base, high)
        let lensStarts: [Double] = lenses.flatMap { [$0.base] + $0.changes }.map { ($0 * 10).rounded() / 10 }
        let stops: [Double] = [0.5, 1, 2, 3, 5, 10]
        zoomMarks = Set(stops + lensStarts).filter { zoomRange.contains($0) }.sorted()
        focusDial = Self.autoFocusDial
        isAutoExposure = true
        isAutoWhiteBalance = true
        exposureBias = 0
        lensChanged()
        setZoom(1)
    }

    /// Zooms to `value` as shown (1 is the main camera), changing lens where the zoom passes
    /// one's start. Not while recording: then it zooms only within the lens in use.
    func setZoom(_ value: Double) {
        var shown = min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
        if !isRecording, let target = lens(for: shown), target.device != videoInput?.device { use(target) }
        guard let device = videoInput?.device, let lens = lenses.first(where: { $0.device == device }) else { return }
        shown = min(lens.base * Double(device.maxAvailableVideoZoomFactor), max(lens.base, shown))
        zoom = shown
        let factor = CGFloat(shown / lens.base)
        adjust(device) { $0.videoZoomFactor = factor }
    }

    /// The narrowest lens that reaches `shown`. A lens in use holds a little below its start,
    /// so a ring resting on 3× doesn't flicker between lenses.
    private func lens(for shown: Double) -> Lens? {
        let current = lenses.first { $0.device == videoInput?.device }
        if let current, shown < current.base, shown >= current.base * 0.97 { return current }
        return lenses.last { $0.base <= shown + 0.0001 } ?? lenses.first
    }

    /// Changes to another lens on the same side, keeping the settings taken by hand.
    private func use(_ lens: Lens) {
        guard let old = videoInput, let input = try? AVCaptureDeviceInput(device: lens.device) else { return }
        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        } else {
            session.addInput(old)
        }
        stabilize()
        session.commitConfiguration()
        lensChanged()
        Haptics.detent()
    }

    /// ZOOM or PRIME; the camera starts again at 1×, automatic.
    func setLensMode(_ mode: LensMode) {
        guard mode != lensMode, !isRecording, hasLensChoice, let old = videoInput else { return }
        let next = Self.lenses(at: position, mode: mode)
        guard let camera = (next.first { $0.base == 1 } ?? next.first)?.device,
            let input = try? AVCaptureDeviceInput(device: camera)
        else { return }
        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            lenses = next
            lensMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: Self.lensModeKey)
        } else {
            session.addInput(old)
        }
        stabilize()
        session.commitConfiguration()
        readLenses()
        Haptics.press()
    }

    private func stabilize() {
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
    }

    /// Turns the focus ring: past the near end into AF is automatic focus, otherwise the lens
    /// is held where the ring is.
    func turnFocus(to dial: Double) {
        focusDial = min(1, max(Self.autoFocusDial, dial))
        guard let device = videoInput?.device else { return }
        if isAutoFocus {
            adjust(device) { device in
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
        } else if canFocus {
            let lens = Float(max(0, focusDial))
            adjust(device) { $0.setFocusModeLocked(lensPosition: lens, completionHandler: nil) }
        }
    }

    /// AF to manual focus and back. Manual starts where automatic focus had the lens, so the
    /// picture doesn't jump.
    func toggleManualFocus() {
        guard let device = videoInput?.device, canFocus else { return }
        Haptics.detent()
        turnFocus(to: isAutoFocus ? Double(device.lensPosition) : Self.autoFocusDial)
    }

    /// Focuses (and exposes) on a point of the picture, in the preview layer's coordinates. On
    /// automatic focus it keeps following from there; on manual it focuses once and holds.
    func focus(atLayerPoint point: CGPoint) {
        guard let device = videoInput?.device, let layer = previewLayer, device.isFocusPointOfInterestSupported
        else { return }
        let target = layer.captureDevicePointConverted(fromLayerPoint: point)
        let manual = !isAutoFocus
        adjust(device) { device in
            device.focusPointOfInterest = target
            device.focusMode = manual ? .autoFocus : .continuousAutoFocus
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = target
                device.exposureMode = .continuousAutoExposure
            }
        }
        guard manual else { return }
        // Once it has focused, the ring shows where the lens went.
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !isAutoFocus, canFocus { focusDial = Double(device.lensPosition) }
        }
    }

    /// Lets go of the focus ring: it settles on AF or on the lens's nearest, not between them.
    func settleFocus() {
        if focusDial < 0 { turnFocus(to: isAutoFocus ? Self.autoFocusDial : 0) }
    }

    /// Photos become 1920-pixel still clips, so they're taken at the smallest size that still
    /// covers that, rather than at the full 12 or 48 megapixels: far less to process and save.
    private func choosePhotoSize(for device: AVCaptureDevice) {
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        let covering = sizes.filter { max($0.width, $0.height) >= Int32(StillVideoWriter.maxDimension) }
        photoSize = covering.min { $0.width * $0.height < $1.width * $1.height } ?? sizes.last
        if let photoSize { photoOutput.maxPhotoDimensions = photoSize }
    }

    private func adjust(_ device: AVCaptureDevice, _ change: (AVCaptureDevice) -> Void) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        change(device)
        device.unlockForConfiguration()
    }

    // MARK: Takes

    /// The shutter: starts or stops a video or sound take, or takes a photo.
    func shutter() {
        switch mode {
        case .video: isRecording ? stopRecording() : startVideo()
        case .photo: takePhoto()
        case .sound: isRecording ? stopRecording() : startSound()
        }
    }

    private func startVideo() {
        guard cameraAccess == .granted, hasCamera, !movieOutput.isRecording else { return }
        applyCaptureRotation(to: movieOutput.connection(with: .video))
        takeLook = look
        movieOutput.startRecording(to: Self.tempURL("mov"), recordingDelegate: delegate)
        began()
    }

    private func takePhoto() {
        guard cameraAccess == .granted, hasCamera else { return }
        applyCaptureRotation(to: photoOutput.connection(with: .video))
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .balanced
        if let size = photoSize { settings.maxPhotoDimensions = size }
        photoOutput.capturePhoto(with: settings, delegate: delegate)
        Haptics.press()
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            flash = false
        }
    }

    private func startSound() {
        guard micAccess == .granted else { return }
        if !sound.isRunning { sound.start() }
        do {
            try sound.startRecording(to: Self.tempURL("m4a"))
            began()
        } catch {
            onError("Couldn't start recording sound. \(error.localizedDescription)")
        }
    }

    private func began() {
        isRecording = true
        recordingStarted = .now
        Haptics.press()
    }

    private func stopRecording() {
        switch mode {
        case .video:
            if movieOutput.isRecording { movieOutput.stopRecording() }
        case .sound:
            if let url = sound.stopRecording() { onTake(.sound(url)) }
        case .photo:
            break
        }
        isRecording = false
        recordingStarted = nil
        Haptics.press()
    }

    fileprivate func finishedVideo(_ url: URL, error: Error?) {
        isRecording = false
        recordingStarted = nil
        // A take cut short (a call, the disk filling) still has what was recorded.
        let usable =
            error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        if usable {
            onTake(.video(url, takeLook))
        } else {
            try? FileManager.default.removeItem(at: url)
            onError("The take couldn't be saved. \(error?.localizedDescription ?? "")")
        }
    }

    fileprivate func received(_ reading: RGBHistogram) {
        histogram = reading
    }

    fileprivate func finishedPhoto(_ data: Data?, error: Error?) {
        if let data {
            onTake(.photo(data, look))
        } else {
            onError("The photo couldn't be taken. \(error?.localizedDescription ?? "")")
        }
    }

    // MARK: Helpers

    /// The back's combined camera (all its lenses behind one smooth zoom), if it has one.
    private static func combinedCamera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        guard position == .back else { return nil }
        let kinds: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        return kinds.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
    }

    /// The lenses on `position`, widest first, with where each starts on the zoom scale (1× is
    /// the main camera), read from the combined camera's switch-over points: for ZOOM the
    /// combined camera alone, for PRIME each lens as a camera of its own. The front has one.
    private static func lenses(at position: AVCaptureDevice.Position, mode: LensMode) -> [Lens] {
        if let combined = combinedCamera(at: position) {
            let rank: [AVCaptureDevice.DeviceType: Int] = [
                .builtInUltraWideCamera: 0, .builtInWideAngleCamera: 1, .builtInTelephotoCamera: 2,
            ]
            let parts = combined.constituentDevices.sorted { rank[$0.deviceType] ?? 9 < rank[$1.deviceType] ?? 9 }
            let starts = [1.0] + combined.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) }
            if parts.count == starts.count,
                let main = parts.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera })
            {
                let shown = starts.map { $0 / starts[main] }
                if mode == .zoom {
                    return [Lens(device: combined, base: shown[0], changes: Array(shown.dropFirst()))]
                }
                return parts.indices.map { Lens(device: parts[$0], base: shown[$0]) }
            }
        }
        guard let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            return []
        }
        return [Lens(device: wide, base: 1)]
    }

    private static func access(for media: AVMediaType) async -> Access {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media) ? .granted : .denied
        default: return .denied
        }
    }

    private static func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private static let frameRateKey = "record.frameRate"
    private static let lensModeKey = "record.lensMode"

    /// Back to the app's own sound setting: playback, as set at launch.
    static func restorePlayback() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }
}

/// Receives the finished movie files and photos and passes them to the rig on the main actor.
private final class CaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate,
    @unchecked Sendable
{
    weak var rig: CameraRig?

    func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak rig] in rig?.finishedVideo(outputFileURL, error: error) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor [weak rig] in rig?.finishedPhoto(data, error: error) }
    }
}

/// Takes the copy of each frame off the main thread: draws it through the look (when there is
/// one) into the live picture, and reads the histogram from every third frame, through the look
/// too, so it measures what's being shot.
private final class FrameTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var rig: CameraRig?

    var look: Look? {
        get { lock.withLock { lockedLook } }
        set { lock.withLock { lockedLook = newValue } }
    }
    var renderer: AVSampleBufferVideoRenderer? {
        get { lock.withLock { lockedRenderer } }
        set { lock.withLock { lockedRenderer = newValue } }
    }

    private let lock = NSLock()
    private var lockedLook: Look?
    private var lockedRenderer: AVSampleBufferVideoRenderer?
    private var frame = 0
    private var last: RGBHistogram?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard var pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let look, let renderer, let graded = draw(pixels, through: look) {
            show(graded, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), in: renderer)
            pixels = graded
        }
        frame += 1
        guard frame % 3 == 0, var reading = RGBHistogram(pixels) else { return }
        // A little of the last reading, so the scope moves smoothly rather than flickering.
        if let last { reading = reading.blended(with: last, keeping: 0.35) }
        last = reading
        Task { @MainActor [weak rig, reading] in rig?.received(reading) }
    }

    private func draw(_ pixels: CVPixelBuffer, through look: Look) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        if pool == nil || size != poolSize {
            poolSize = size
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let out = made else { return nil }
        context.render(LookLibrary.apply(look, to: CIImage(cvPixelBuffer: pixels)), to: out)
        return out
    }

    private func show(_ pixels: CVPixelBuffer, at time: CMTime, in renderer: AVSampleBufferVideoRenderer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample)
        guard let sample else { return }
        // Shown as it arrives rather than scheduled against a clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
