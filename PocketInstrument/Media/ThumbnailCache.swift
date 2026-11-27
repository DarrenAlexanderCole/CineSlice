import AVFoundation
import EditCore
import SwiftUI
import UIKit

/// Small in-memory cache of video frames for clip tiles and filmstrips.
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private var images: [String: UIImage] = [:]
    private var order: [String] = []
    private let limit = 300

    func image(url: URL, at time: CMTime, maxPixel: CGFloat = 200) async -> UIImage? {
        let key = "\(url.lastPathComponent)#\(time.value)/\(time.timescale)#\(Int(maxPixel))"
        if let hit = images[key] { return hit }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let tolerance = CMTime(value: 1, timescale: 15)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let cg = try? await generator.image(at: time).image else { return nil }
        let image = UIImage(cgImage: cg)
        images[key] = image
        order.append(key)
        if order.count > limit {
            let drop = order.removeFirst()
            images[drop] = nil
        }
        return image
    }
}

/// A frame from a video file, loaded asynchronously, through its look when it has one.
struct VideoFrameView: View {
    let url: URL?
    let time: CMTime
    var maxPixel: CGFloat = 200
    var look: Look?

    @State private var image: UIImage?

    private var lookKey: String { look.map { "#\($0.id)@\($0.intensity)" } ?? "" }

    var body: some View {
        ZStack {
            Theme.instrument
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if url == nil {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.aluminum)
                    .accessibilityLabel("Media missing")
            }
        }
        .clipped()
        .task(id: "\(url?.lastPathComponent ?? "-")\(time.value)/\(time.timescale)\(lookKey)") {
            guard let url else {
                image = nil
                return
            }
            let frame = await ThumbnailCache.shared.image(url: url, at: time, maxPixel: maxPixel)
            if let frame, let look {
                image = await Task.detached { LookLibrary.apply(look, to: frame) }.value
            } else {
                image = frame
            }
        }
    }
}
