import AVFoundation
import CoreVideo
import EditCore
import UIKit

/// Generates short test clips on-device so the editor can be exercised in the
/// Simulator (which has no sample videos). Each clip has a different shape —
/// landscape, portrait, square — and burns in its name, timecode and frame
/// number, which makes trim points and 9:16 framing easy to verify by eye.
enum DemoMediaGenerator {
    struct Spec {
        let label: String
        let size: CGSize
        let seconds: Int
        let hue: CGFloat
    }

    static let specs: [Spec] = [
        Spec(label: "A · LANDSCAPE", size: CGSize(width: 1280, height: 720), seconds: 6, hue: 0.08),
        Spec(label: "B · PORTRAIT", size: CGSize(width: 720, height: 1280), seconds: 5, hue: 0.55),
        Spec(label: "C · SQUARE", size: CGSize(width: 960, height: 960), seconds: 4, hue: 0.28),
    ]

    /// Creates the demo files and imports them into the project's media folder.
    static func makeDemoSources(store: ProjectStore, projectID: UUID) async throws -> [SourceAsset] {
        var sources: [SourceAsset] = []
        for spec in specs {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            try await writeClip(spec, to: temp)
            var source = try await MediaImporter.adopt(
                tempURL: temp, originalName: "\(spec.label).mov",
                store: store, projectID: projectID)
            source.originalFilename = spec.label
            sources.append(source)
        }
        return sources
    }

    static func writeClip(_ spec: Spec, to url: URL) async throws {
        let fps: Int32 = 30
        let width = Int(spec.size.width)
        let height = Int(spec.size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.failed("Couldn't start demo writer")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = spec.seconds * Int(fps)
        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.failed("No pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ExportError.failed("No pixel buffer") }
            draw(spec, frame: frame, fps: Int(fps), into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ExportError.failed("Demo clip didn't finish")
        }
    }

    private static func draw(_ spec: Spec, frame: Int, fps: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        // Flip to UIKit coordinates for text drawing.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let size = CGSize(width: w, height: h)
        let t = CGFloat(frame) / CGFloat(fps)
        UIColor(hue: spec.hue, saturation: 0.45, brightness: 0.35 + 0.1 * sin(t * 2), alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        // Frame-safe guides: outer border and centre cross, to check fill/fit cropping.
        UIColor(white: 1, alpha: 0.35).setStroke()
        let border = UIBezierPath(rect: CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
        border.lineWidth = 6
        border.stroke()
        let cross = UIBezierPath()
        cross.move(to: CGPoint(x: size.width / 2 - 40, y: size.height / 2))
        cross.addLine(to: CGPoint(x: size.width / 2 + 40, y: size.height / 2))
        cross.move(to: CGPoint(x: size.width / 2, y: size.height / 2 - 40))
        cross.addLine(to: CGPoint(x: size.width / 2, y: size.height / 2 + 40))
        cross.lineWidth = 3
        cross.stroke()

        // A bar that sweeps across once per second, so motion and speed are visible.
        let phase = CGFloat(frame % fps) / CGFloat(fps)
        UIColor(red: 0.82, green: 0.86, blue: 0.40, alpha: 1).setFill()
        UIRectFill(CGRect(x: phase * (size.width - 60), y: size.height * 0.72, width: 60, height: 24))

        let seconds = frame / fps
        let lines = [
            spec.label,
            String(format: "%02d:%02d:%02d", seconds / 60, seconds % 60, frame % fps),
            "F \(frame)",
        ]
        let fontSize = min(size.width, size.height) / 9
        var y = size.height * 0.3
        for (i, line) in lines.enumerated() {
            let font =
                i == 0
                ? UIFont.systemFont(ofSize: fontSize * 0.55, weight: .semibold)
                : UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let text = line as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: y), withAttributes: attrs)
            y += textSize.height + 8
        }
    }

    // MARK: Click track

    /// A 30 s, 120 BPM metronome in 4/4 with an accented downbeat, so music sync can be
    /// tested without a real song. Beats land every 0.5 s (15 frames at 30 fps), so the
    /// demo clips' whole-second cuts sit exactly on clicks.
    static func makeClickTrack(store: ProjectStore, projectID: UUID) async throws -> AudioTrack {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try writeClickTrack(to: temp)
        return try await MediaImporter.adoptAudio(
            tempURL: temp, originalName: "Demo click 120 BPM", store: store, projectID: projectID)
    }

    static let clickBPM = 120.0
    static let clickSeconds = 30.0

    static func writeClickTrack(to url: URL, sampleRate: Double = 44_100) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw ExportError.failed("No audio format")
        }
        let frameCount = AVAudioFrameCount(sampleRate * clickSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let samples = buffer.floatChannelData?[0]
        else { throw ExportError.failed("No audio buffer") }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) { samples[i] = 0 }

        let beatSamples = Int(sampleRate * 60 / clickBPM)
        let clickLength = Int(sampleRate * 0.04)
        var beat = 0
        while beat * beatSamples < Int(frameCount) {
            // Downbeat: higher and louder, so bars are easy to see in the waveform and hear.
            let isDownbeat = beat % 4 == 0
            let pitch = isDownbeat ? 1_600.0 : 1_000.0
            let gain: Float = isDownbeat ? 0.9 : 0.45
            let start = beat * beatSamples
            for n in 0..<min(clickLength, Int(frameCount) - start) {
                let t = Double(n) / sampleRate
                samples[start + n] = gain * Float(sin(2 * .pi * pitch * t) * exp(-t * 120))
            }
            beat += 1
        }

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
