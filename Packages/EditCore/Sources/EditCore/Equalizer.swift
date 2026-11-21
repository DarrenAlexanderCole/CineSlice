import Foundation

/// The master EQ: one set of filters on the whole mix (clip sound and music), in preview and
/// export. A low cut for wind and rumble, a low shelf, one sweepable mid band and a high shelf.
public struct MasterEQ: Codable, Hashable, Sendable {
    /// Off keeps the settings but plays the mix untouched, to compare.
    public var isOn: Bool
    /// The low cut's corner (Hz). At `lowCutRange.lowerBound` it's out.
    public var lowCut: Double
    /// The low shelf's gain (dB), below `lowShelfFrequency`.
    public var lowGain: Double
    /// The mid band's centre (Hz).
    public var midFrequency: Double
    /// The mid band's gain (dB).
    public var midGain: Double
    /// The mid band's width (octaves).
    public var midWidth: Double
    /// The high shelf's gain (dB), above `highShelfFrequency`.
    public var highGain: Double

    public static let lowCutRange: ClosedRange<Double> = 20...300
    public static let gainRange: ClosedRange<Double> = -12...12
    public static let midFrequencyRange: ClosedRange<Double> = 100...10_000
    public static let midWidthRange: ClosedRange<Double> = 0.2...3
    public static let lowShelfFrequency = 120.0
    public static let highShelfFrequency = 8_000.0

    public static let flat = MasterEQ(
        isOn: true, lowCut: lowCutRange.lowerBound, lowGain: 0, midFrequency: 1_000, midGain: 0, midWidth: 1,
        highGain: 0)

    public init(
        isOn: Bool, lowCut: Double, lowGain: Double, midFrequency: Double, midGain: Double, midWidth: Double,
        highGain: Double
    ) {
        self.isOn = isOn
        self.lowCut = lowCut.clamped(to: Self.lowCutRange)
        self.lowGain = lowGain.clamped(to: Self.gainRange)
        self.midFrequency = midFrequency.clamped(to: Self.midFrequencyRange)
        self.midGain = midGain.clamped(to: Self.gainRange)
        self.midWidth = midWidth.clamped(to: Self.midWidthRange)
        self.highGain = highGain.clamped(to: Self.gainRange)
    }

    /// Whether it changes the sound at all.
    public var isActive: Bool { isOn && !filters(sampleRate: 44_100).isEmpty }

    /// The filters to run in order, at `sampleRate`; bands that do nothing are left out.
    public func filters(sampleRate: Double) -> [Biquad] {
        var filters: [Biquad] = []
        if lowCut > Self.lowCutRange.lowerBound { filters.append(.highPass(lowCut, sampleRate: sampleRate)) }
        if lowGain != 0 { filters.append(.lowShelf(Self.lowShelfFrequency, gain: lowGain, sampleRate: sampleRate)) }
        if midGain != 0 {
            filters.append(.peak(midFrequency, gain: midGain, octaves: midWidth, sampleRate: sampleRate))
        }
        if highGain != 0 {
            filters.append(.highShelf(Self.highShelfFrequency, gain: highGain, sampleRate: sampleRate))
        }
        return filters
    }

    /// How much louder or quieter (dB) it makes `frequency`, for drawing its curve.
    public func response(at frequency: Double, sampleRate: Double = 44_100) -> Double {
        filters(sampleRate: sampleRate).reduce(0) { $0 + $1.response(at: frequency, sampleRate: sampleRate) }
    }
}

/// One second-order filter, normalised so a0 is 1: y = b0·x + b1·x₋₁ + b2·x₋₂ − a1·y₋₁ − a2·y₋₂.
/// The shapes are Robert Bristow-Johnson's "Audio EQ Cookbook" ones.
public struct Biquad: Hashable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    /// A 12 dB/octave cut below `frequency`.
    public static func highPass(_ frequency: Double, sampleRate: Double) -> Biquad {
        let (cosw, alpha) = Self.shape(frequency, q: 1 / 2.0.squareRoot(), sampleRate: sampleRate)
        return Biquad(
            b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2, a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
    }

    public static func lowShelf(_ frequency: Double, gain: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let (cosw, alpha) = Self.shape(frequency, q: 1 / 2.0.squareRoot(), sampleRate: sampleRate)
        let root = 2 * a.squareRoot() * alpha
        return Biquad(
            b0: a * ((a + 1) - (a - 1) * cosw + root), b1: 2 * a * ((a - 1) - (a + 1) * cosw),
            b2: a * ((a + 1) - (a - 1) * cosw - root), a0: (a + 1) + (a - 1) * cosw + root,
            a1: -2 * ((a - 1) + (a + 1) * cosw), a2: (a + 1) + (a - 1) * cosw - root)
    }

    public static func highShelf(_ frequency: Double, gain: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let (cosw, alpha) = Self.shape(frequency, q: 1 / 2.0.squareRoot(), sampleRate: sampleRate)
        let root = 2 * a.squareRoot() * alpha
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cosw + root), b1: -2 * a * ((a - 1) + (a + 1) * cosw),
            b2: a * ((a + 1) + (a - 1) * cosw - root), a0: (a + 1) - (a - 1) * cosw + root,
            a1: 2 * ((a - 1) - (a + 1) * cosw), a2: (a + 1) - (a - 1) * cosw - root)
    }

    /// A bell `octaves` wide round `frequency`.
    public static func peak(_ frequency: Double, gain: Double, octaves: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) * sinh(log(2) / 2 * octaves * w / sin(w))
        let cosw = cos(w)
        return Biquad(
            b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
    }

    private static func shape(_ frequency: Double, q: Double, sampleRate: Double) -> (cos: Double, alpha: Double) {
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        return (cos(w), sin(w) / (2 * q))
    }

    /// Its gain (dB) at `frequency`.
    public func response(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        // |B(e^jw)|² / |A(e^jw)|², with z⁻¹ = e^-jw.
        func power(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return re * re + im * im
        }
        return 10 * log10(power(b0, b1, b2) / power(1, a1, a2))
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
