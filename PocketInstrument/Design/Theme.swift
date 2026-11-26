import SwiftUI
import UIKit

/// Design tokens from CLAUDE.md ("Approved visual design").
/// Phase 0/1 uses them plainly; the photographic-instrument polish comes later.
enum Theme {
    static let obsidian = Color(hex: 0x151816)
    static let instrument = Color(hex: 0x30372F)
    static let olive = Color(hex: 0x56623B)
    static let signal = Color(hex: 0xD0DB65)
    static let aluminum = Color(hex: 0xBFC1B4)
    static let ivory = Color(hex: 0xECE9DD)

    /// Vintage accent for name plates and rivets only.
    static let brass = Color(hex: 0xB59A62)
    /// Vintage accent: the sage enamel of an old table viewer, for the library's machine.
    static let enamel = Color(hex: 0x8A9774)

    /// LIGHTBOX, the landscape editing table: film lit from below on an ivory light box.
    /// The light box's glowing surface, a warmer ivory.
    static let lightTable = Color(hex: 0xF4EEDC)
    /// The amber of lit film base, for film-strip edges and perforations.
    static let filmAmber = Color(hex: 0xB8541A)
    /// Sage acetate, for sound-only clips.
    static let acetate = Color(hex: 0x9CC98A)
    /// Waveform ink on acetate.
    static let acetateInk = Color(hex: 0x2E7D3A)
    /// LIGHTBOX: sounds on the lanes under the music, in a cooler acetate, and their ink.
    static let soundGlass = Color(hex: 0x9CC4CB)
    static let soundInk = Color(hex: 0x245F6B)
    /// The playhead: orange-red, the one warm line on the table.
    static let playhead = Color(hex: 0xF0502A)

    static let label = ivory
    static let secondaryLabel = aluminum.opacity(0.85)
    static let hairline = ivory.opacity(0.14)

    static let cornerRadius: CGFloat = 12
    static let minTouch: CGFloat = 44

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small uppercase technical label.
    static let caption = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

extension Theme {
    /// A small tile of fine, seeded noise, tiled over metal and enamel for a cast, tactile surface.
    /// Made once; mid-grey so it can lighten and darken through `.overlay` blending.
    static let grain: UIImage = {
        let side = 96
        var state: UInt32 = 0x9E37_79B9
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            pixels[i] = UInt8(truncatingIfNeeded: 96 + Int(state % 64))
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }()
}

/// The grain tiled across a surface.
struct Grain: View {
    var opacity: Double = 0.35

    var body: some View {
        Image(uiImage: Theme.grain)
            .resizable(resizingMode: .tile)
            .blendMode(.softLight)
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

/// Lightweight haptics (UIKit feedback generators). Core Haptics detents come in Phase 4.
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func press() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func detent() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
