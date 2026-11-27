import AVFoundation
import CoreImage
import EditCore

/// Where each look plays on one video track of the composition, in composition time.
struct LookSpan {
    let timeRange: CMTimeRange
    let look: Look
}

/// The picture's one instruction when looks are in use: the usual layer instructions (their
/// framing transforms and opacity, top layer first), and where on each track a look plays.
final class LookInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [AVVideoCompositionLayerInstruction]
    let looks: [CMPersistentTrackID: [LookSpan]]

    init(
        timeRange: CMTimeRange, layers: [AVVideoCompositionLayerInstruction],
        looks: [CMPersistentTrackID: [LookSpan]]
    ) {
        self.timeRange = timeRange
        self.layers = layers
        self.looks = looks
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }

    func look(onTrack track: CMPersistentTrackID, at time: CMTime) -> Look? {
        looks[track]?.first { $0.timeRange.containsTime(time) }?.look
    }
}

/// Draws the picture itself when looks are in use, since layer instructions alone can't colour
/// a clip: each layer, bottom up, through its clip's look, then framed and faded exactly as its
/// layer instruction says, over black. Preview and export both use it, so they match.
final class LookCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private let queue = DispatchQueue(label: "cineslice.looks.compositor")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? LookInstruction,
                let output = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: NSError(domain: "CineSlice.Looks", code: -1))
                return
            }
            let size = request.renderContext.size
            let bounds = CGRect(origin: .zero, size: size)
            let time = request.compositionTime
            var picture = CIImage(color: .black).cropped(to: bounds)
            // Layer instructions run top first; draw from the bottom up.
            for layer in instruction.layers.reversed() {
                guard let frame = request.sourceFrame(byTrackID: layer.trackID) else { continue }
                var startOpacity: Float = 1
                var endOpacity: Float = 1
                var opacityRange = CMTimeRange.zero
                layer.getOpacityRamp(
                    for: time, startOpacity: &startOpacity, endOpacity: &endOpacity, timeRange: &opacityRange)
                guard startOpacity > 0 else { continue }
                var transform = CGAffineTransform.identity
                var endTransform = CGAffineTransform.identity
                var transformRange = CMTimeRange.zero
                layer.getTransformRamp(
                    for: time, start: &transform, end: &endTransform, timeRange: &transformRange)

                var image = CIImage(cvPixelBuffer: frame)
                image = LookLibrary.apply(instruction.look(onTrack: layer.trackID, at: time), to: image)
                let placed = Self.coreImageTransform(
                    transform, sourceHeight: image.extent.height, outputHeight: size.height)
                image = image.transformed(by: placed)
                if startOpacity < 1 {
                    let fade = CIVector(x: 0, y: 0, z: 0, w: CGFloat(startOpacity))
                    image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": fade])
                }
                picture = image.composited(over: picture)
            }
            context.render(picture.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
    }

    /// A layer instruction's transform works in pixels with y down; Core Image's y runs up. The
    /// same move, flipped in on the source's side and back out on the output's.
    static func coreImageTransform(_ transform: CGAffineTransform, sourceHeight: CGFloat, outputHeight: CGFloat)
        -> CGAffineTransform
    {
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outputHeight)
        return flipSource.concatenating(transform).concatenating(flipOutput)
    }
}
