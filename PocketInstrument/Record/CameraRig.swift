@preconcurrency import AVFoundation
import Observation
import UIKit

/// What a take on the Record page produced, still in a temporary file (or memory, for a photo)
/// until the project adopts it.
enum RecordedTake {
    case video(URL)
    case photo(Data)
    case sound(URL)
}

/// The Record page's camera and microphone. Video and photo go through one capture session
/// (the back or front camera plus the microphone); sound-only takes stop it and record the
/// microphone alone, so the mic is never held twice. Takes are recorded the way the phone is
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
    /// The microphone's level while recording sound, 0…1.
    private(set) var level: Float = 0
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
    /// The camera's lens can be set by hand, so the focus ring turns it (front cameras
    /// usually can't).
    private(set) var canFocus = false

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
    /// The zoom factor of the main camera on a camera with an ultra wide: 1× as shown.
    private var zoomBaseline: CGFloat = 1
    private var photoSize: CMVideoDimensions?
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private let delegate = CaptureDelegate()
    private let histogramTap = HistogramTap()

    init(mode: Mode) {
        self.mode = mode
        delegate.rig = self
        histogramTap.rig = self
    }

    // MARK: Start / stop

    /// Asks for what the mode needs and starts it.
    func start() async {
        micAccess = await Self.access(for: .audio)
        if mode != .sound { await startCamera() }
    }

    /// Stops everything and gives the app's sound back to playback.
    func stop() {
        if isRecording { stopRecording() }
        meterTask?.cancel()
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
            let session = session
            queue.async { if session.isRunning { session.stopRunning() } }
        } else if old == .sound {
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
        guard let camera = Self.camera(at: position), let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
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
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        // A copy of the picture for the histogram; the recording itself is untouched.
        frameOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frameOutput.alwaysDiscardsLateVideoFrames = true
        frameOutput.setSampleBufferDelegate(histogramTap, queue: frameQueue)
        if session.canAddOutput(frameOutput) {
            session.addOutput(frameOutput)
            // Some older phones can't afford it alongside the recording: go without.
            if session.hardwareCost > 1 { session.removeOutput(frameOutput) }
        }
        readLens()
        followRotation()
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
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotation = coordinator
        let key = \AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelPreview
        rotationObservation = coordinator.observe(key, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
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
        guard let camera = Self.camera(at: next), let input = try? AVCaptureDeviceInput(device: camera) else { return }
        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
            position = next
        } else {
            session.addInput(old)
        }
        if let connection = movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        session.commitConfiguration()
        readLens()
        followRotation()
        Haptics.detent()
    }

    // MARK: Lens

    /// Learns the new camera's zoom and focus and starts it at 1× and automatic focus.
    private func readLens() {
        guard let device = videoInput?.device else { return }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        zoomBaseline = hasUltraWide ? CGFloat(truncating: device.virtualDeviceSwitchOverVideoZoomFactors.first ?? 1) : 1
        let low = Double(device.minAvailableVideoZoomFactor / zoomBaseline)
        let high = Double(min(device.maxAvailableVideoZoomFactor, zoomBaseline * 10) / zoomBaseline)
        zoomRange = low...max(low, high)
        let lensChanges = device.virtualDeviceSwitchOverVideoZoomFactors.map {
            Double(truncating: $0) / Double(zoomBaseline)
        }
        zoomMarks = Set([0.5, 1, 2, 3, 5, 10] + lensChanges.map { ($0 * 10).rounded() / 10 })
            .filter { zoomRange.contains($0) }
            .sorted()
        canFocus = device.isLockingFocusWithCustomLensPositionSupported
        choosePhotoSize(for: device)
        setZoom(1)
        turnFocus(to: Self.autoFocusDial)
    }

    /// Zooms to `value` as shown (1 is the main camera).
    func setZoom(_ value: Double) {
        guard let device = videoInput?.device else { return }
        let shown = min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
        zoom = shown
        adjust(device) { $0.videoZoomFactor = CGFloat(shown) * self.zoomBaseline }
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
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audio.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: Self.tempURL("m4a"), settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw RecordError.couldNotStart }
            self.recorder = recorder
            began()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    // −50 dB and below reads as nothing.
                    self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            Self.restorePlayback()
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
            meterTask?.cancel()
            level = 0
            if let recorder {
                recorder.stop()
                self.recorder = nil
                onTake(.sound(recorder.url))
            }
            Self.restorePlayback()
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
            onTake(.video(url))
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
            onTake(.photo(data))
        } else {
            onError("The photo couldn't be taken. \(error?.localizedDescription ?? "")")
        }
    }

    // MARK: Helpers

    private enum RecordError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone didn't start." }
    }

    /// The back camera with all its lenses, so the zoom ring reaches the ultra wide and the
    /// telephoto; the front one as it is.
    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let kinds: [AVCaptureDevice.DeviceType] =
            position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        return kinds.lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: position) }.first
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

/// Reads the histogram from every third frame of the picture, off the main thread.
private final class HistogramTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var rig: CameraRig?
    private var frame = 0
    private var last: RGBHistogram?

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        frame += 1
        guard frame % 3 == 0, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
            var reading = RGBHistogram(pixels)
        else { return }
        // A little of the last reading, so the scope moves smoothly rather than flickering.
        if let last { reading = reading.blended(with: last, keeping: 0.35) }
        last = reading
        Task { @MainActor [weak rig, reading] in rig?.received(reading) }
    }
}
