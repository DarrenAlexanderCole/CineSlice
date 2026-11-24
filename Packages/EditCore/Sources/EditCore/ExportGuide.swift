import Foundation

// MARK: - Presets

/// A one-tap starting point for the export: resolution, picture shape and frame rate, with the
/// bitrate left on auto. The codec, sound and feed cut stay as they were.
public struct ExportPreset: Hashable, Identifiable, Sendable {
    public let name: String
    public let detail: String
    public let resolution: Int
    public let landscape: Bool
    public let frameRate: Int

    public var id: String { name }

    public static let all: [ExportPreset] = [
        ExportPreset(
            name: "1080p · 9:16", detail: "Reels, Stories, TikTok, Shorts.", resolution: 1080, landscape: false,
            frameRate: 30),
        ExportPreset(
            name: "4K · 9:16", detail: "Vertical master to keep. Apps shrink it to 1080p.", resolution: 2160,
            landscape: false, frameRate: 30),
        ExportPreset(
            name: "1080p · 16:9", detail: "YouTube, TV, laptops.", resolution: 1080, landscape: true, frameRate: 30),
        ExportPreset(
            name: "4K · 16:9", detail: "Horizontal master for YouTube 4K or big screens.", resolution: 2160,
            landscape: true, frameRate: 30),
    ]

    /// `settings` with this preset applied.
    public func applied(to settings: ExportSettings) -> ExportSettings {
        var s = settings.oriented(landscape: landscape)
        s.resolution = resolution
        s.frameRate = frameRate
        s.videoBitrate = nil
        s.keyframeInterval = 2
        return s
    }

    /// Whether `settings` are this preset as it was applied (a later tweak un-lights it).
    public func matches(_ settings: ExportSettings) -> Bool {
        applied(to: settings) == settings
    }
}

// MARK: - Guide

/// How much picture detail a bitrate keeps at a resolution and frame rate.
public enum ExportQuality: Int, Comparable, CaseIterable, Sendable {
    case low, fair, good, high, max

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .low: return "Low"
        case .fair: return "Fair"
        case .good: return "Good"
        case .high: return "High"
        case .max: return "Max"
        }
    }

    public var advice: String {
        switch self {
        case .low: return "Blocky in motion and dark areas. Only for quick previews."
        case .fair: return "Fine on a phone screen. Fast movement and grain will smear."
        case .good: return "Clean for social posts. Apps re-compress to about this anyway."
        case .high: return "Holds up on big screens and when you edit it again later."
        case .max: return "Close to camera originals. Big files with little visible gain."
        }
    }
}

extension ExportSettings {
    /// Pixels encoded per second.
    public var pixelRate: Double { Double(outputWidth * outputHeight) * Double(frameRate) }

    /// HEVC needs about two thirds of H.264's bits for the same picture.
    public var codecEfficiency: Double { codec == .hevc ? 0.65 : 1 }

    /// The automatic bitrate: High quality, i.e. 0.2 bits per pixel in H.264 terms (≈12 Mbps for
    /// 1080p30, ≈50 Mbps for 4K30), rounded to 0.5 Mbps.
    public var autoVideoBitrate: Int {
        let bits = pixelRate * 0.2 * codecEfficiency
        let rounded = Int((bits / 500_000).rounded()) * 500_000
        return min(max(rounded, Self.videoBitrateRange.lowerBound), Self.videoBitrateRange.upperBound)
    }

    /// The bitrate the encoder is given.
    public var effectiveVideoBitrate: Int { videoBitrate ?? autoVideoBitrate }

    /// Bits per pixel, in H.264 terms so HEVC compares fairly.
    public var bitsPerPixel: Double { Double(effectiveVideoBitrate) / max(pixelRate, 1) / codecEfficiency }

    public var quality: ExportQuality {
        switch bitsPerPixel {
        case ..<0.05: return .low
        case ..<0.1: return .fair
        case ..<0.16: return .good
        case ..<0.3: return .high
        default: return .max
        }
    }

    /// The file's expected size: picture plus sound (when there is any) plus ~1% for the container.
    public func estimatedBytes(seconds: Double, hasSound: Bool) -> Int {
        let bits = Double(effectiveVideoBitrate + (hasSound ? audioBitrate : 0)) * seconds * 1.01
        return Int(bits / 8)
    }
}
