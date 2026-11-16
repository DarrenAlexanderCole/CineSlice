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
