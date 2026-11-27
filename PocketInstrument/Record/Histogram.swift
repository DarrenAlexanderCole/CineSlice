import CoreVideo
import SwiftUI

/// How much of the picture sits at each level, darkest to brightest, for red, green and blue:
/// 64 bins each, scaled 0…1 to the tallest.
struct RGBHistogram: Equatable, Sendable {
    static let bins = 64

    var red: [Float]
    var green: [Float]
    var blue: [Float]

    init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Reads a BGRA frame, sampling a grid of about 300 pixels across it.
    init?(_ pixels: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let step = max(1, width / 300)
        let bins = Self.bins
        var counts = [UInt32](repeating: 0, count: bins * 3)
        counts.withUnsafeMutableBufferPointer { counts in
            for y in stride(from: 0, to: height, by: step) {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in stride(from: 0, to: width, by: step) {
                    let pixel = row + x * 4
                    // 256 levels into 64 bins.
                    counts[Int(pixel[2] >> 2)] += 1
                    counts[bins + Int(pixel[1] >> 2)] += 1
                    counts[bins * 2 + Int(pixel[0] >> 2)] += 1
                }
            }
        }
        // Scaled to the tallest bin, leaving out the two ends: crushed blacks and clipped
        // highlights pile up there and would flatten everything else.
        var peak: UInt32 = 1
        for channel in 0..<3 {
            for bin in 1..<(bins - 1) { peak = max(peak, counts[channel * bins + bin]) }
        }
        let scale = 1 / Float(peak)
        func channel(_ index: Int) -> [Float] {
            (0..<bins).map { min(1, Float(counts[index * bins + $0]) * scale) }
        }
        self.init(red: channel(0), green: channel(1), blue: channel(2))
    }

    /// This reading with a share of `previous` mixed back in.
    func blended(with previous: RGBHistogram, keeping share: Float) -> RGBHistogram {
        func mix(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 * (1 - share) + $1 * share } }
        return RGBHistogram(
            red: mix(red, previous.red), green: mix(green, previous.green), blue: mix(blue, previous.blue))
    }
}

/// The live picture's RGB histogram, in a small black scope: each channel a bright line over a
/// faint fill, mixing like light where they overlap, so where all three agree reads white.
struct HistogramScope: View {
    let histogram: RGBHistogram?

    private static let red = Color(hex: 0xFF5A4E)
    private static let green = Color(hex: 0x6BE06B)
    private static let blue = Color(hex: 0x4C8DFF)

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            context.blendMode = .plusLighter
            let channels = [(histogram.blue, Self.blue), (histogram.green, Self.green), (histogram.red, Self.red)]
            for (values, color) in channels {
                let line = Self.line(values, in: size)
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.28)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.8)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.aluminum.opacity(0.55), lineWidth: 1)
        )
    }

    private static func line(_ values: [Float], in size: CGSize) -> Path {
        Path { path in
            for (i, value) in values.enumerated() {
                let point = CGPoint(
                    x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height * (1 - CGFloat(value) * 0.96))
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
        }
    }
}
