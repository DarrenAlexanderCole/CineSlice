import CoreImage
import EditCore
import Foundation
import UIKit
import simd

/// A 3D LUT ready for Core Image: its edge size and RGBA float data, red changing fastest.
struct LookCube: Sendable {
    let size: Int
    let data: Data
}

/// The looks the app knows: its own, drawn as LUTs from a few colour rules, and `.cube` files
/// the user imported, kept in Application Support/Looks so every project can use them. Looks are
/// applied in the gamma-encoded picture (sRGB), as creative LUTs expect.
enum LookLibrary {
    /// The app's own looks.
    static let builtIns: [Look] = BuiltIn.allCases.map(\.look)

    /// The app's own looks in the menu's sections: cinema stocks and grades, photographic
    /// colour films, and black and white.
    static let builtInGroups: [(title: String, looks: [Look])] = BuiltIn.Group.allCases.map { group in
        (group.title, BuiltIn.allCases.filter { $0.group == group }.map(\.look))
    }

    /// The `.cube` looks imported so far, by name.
    static func imported() -> [Look] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .map { Look(id: "cube:\($0.lastPathComponent)", name: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Copies a `.cube` file into the library once it reads as a 3D LUT, and returns its look.
    static func importCube(from url: URL) throws -> Look {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try parseCube(text)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).cube").path) {
            name = "\(base) \(n)"
            n += 1
        }
        let destination = folder.appendingPathComponent("\(name).cube")
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return Look(id: "cube:\(destination.lastPathComponent)", name: name)
    }

    /// The LUT for a look, or nil when its file has gone. Built once, then kept.
    static func cube(for look: Look) -> LookCube? {
        cache.cube(for: look.id) {
            if look.id.hasPrefix("builtin:"), let builtIn = BuiltIn(rawValue: String(look.id.dropFirst(8))) {
                return builtIn.cube()
            }
            if look.id.hasPrefix("cube:") {
                let file = folder.appendingPathComponent(String(look.id.dropFirst(5)))
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return try? parseCube(text)
            }
            return nil
        }
    }

    /// `image` through `look`, mixed with the clean picture by its intensity. Unchanged without
    /// a look, or when its LUT can't be found.
    static func apply(_ look: Look?, to image: CIImage) -> CIImage {
        guard let look, look.intensity > 0, let cube = cube(for: look),
            let filter = CIFilter(name: "CIColorCubeWithColorSpace")
        else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(cube.size, forKey: "inputCubeDimension")
        filter.setValue(cube.data, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
        guard let graded = filter.outputImage else { return image }
        guard look.intensity < 1, let mix = CIFilter(name: "CIDissolveTransition") else {
            return graded.cropped(to: image.extent)
        }
        mix.setValue(image, forKey: kCIInputImageKey)
        mix.setValue(graded, forKey: kCIInputTargetImageKey)
        mix.setValue(look.intensity, forKey: kCIInputTimeKey)
        return (mix.outputImage ?? graded).cropped(to: image.extent)
    }

    /// A still (a thumbnail) through `look`.
    static func apply(_ look: Look, to image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let graded = apply(look, to: CIImage(cgImage: cg))
        guard let out = stillContext.createCGImage(graded, from: graded.extent) else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    private static let stillContext = CIContext()

    // MARK: .cube files

    enum CubeError: LocalizedError {
        case notA3DLUT
        case badData

        var errorDescription: String? {
            switch self {
            case .notA3DLUT: "That isn't a 3D LUT. Looks need a .cube file with LUT_3D_SIZE."
            case .badData: "That .cube file's colour table is incomplete or unreadable."
            }
        }
    }

    /// Reads a `.cube` file's 3D LUT, scaling from its DOMAIN_MIN/MAX to 0…1.
    static func parseCube(_ text: String) throws -> LookCube {
        var size = 0
        var low: [Float] = [0, 0, 0]
        var high: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            switch parts.first?.uppercased() {
            case "TITLE": continue
            case "LUT_1D_SIZE": throw CubeError.notA3DLUT
            case "LUT_3D_SIZE":
                size = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                values.reserveCapacity(size * size * size * 4)
            case "DOMAIN_MIN": low = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX": high = parts.dropFirst().compactMap { Float($0) }
            default:
                let rgb = parts.compactMap { Float($0) }
                guard rgb.count == 3 else { continue }
                for c in 0..<3 {
                    let span = high.count == 3 && low.count == 3 ? high[c] - low[c] : 1
                    values.append(span > 0 ? (rgb[c] - (low.count == 3 ? low[c] : 0)) / span : rgb[c])
                }
                values.append(1)
            }
        }
        guard (2...128).contains(size) else { throw CubeError.notA3DLUT }
        guard values.count == size * size * size * 4 else { throw CubeError.badData }
        return LookCube(size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Looks", isDirectory: true)
    }()

    private static let cache = CubeCache()
}

/// Built LUTs by look, shared by the camera, the player and export, which run on their own
/// threads.
private final class CubeCache: @unchecked Sendable {
    private var cubes: [String: LookCube] = [:]
    private let lock = NSLock()

    func cube(for id: String, make: () -> LookCube?) -> LookCube? {
        lock.lock()
        if let hit = cubes[id] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let made = make() else { return nil }
        lock.lock()
        cubes[id] = made
        lock.unlock()
        return made
    }
}

// MARK: - The app's own looks

/// Each look is a rule from a colour to a colour, in the gamma-encoded picture, drawn into a
/// 33-point LUT. The film looks are after the character of well-loved stocks and cameras (their
/// curves, their casts, which colours they push and which they hold back), named for what they
/// do rather than for whose film they recall. A LUT can't add grain or halation; they're colour
/// only.
private enum BuiltIn: String, CaseIterable {
    // The first six were the original set: their ids are stored on takes, so they stay.
    case koda, blockbuster, bleach, noir, seventies, night
    case tungsten500, wetzlar, chrome, velvet, reportage, pastel, portrait, gold
    case silver, push, redFilter, wetzlarMono, sepia

    enum Group: CaseIterable {
        case cinema, colourFilm, blackAndWhite

        var title: String {
            switch self {
            case .cinema: "Cinema"
            case .colourFilm: "Colour film"
            case .blackAndWhite: "Black & white"
            }
        }
    }

    var look: Look { Look(id: "builtin:\(rawValue)", name: title) }

    var group: Group {
        switch self {
        case .koda, .tungsten500, .blockbuster, .bleach, .night: .cinema
        case .wetzlar, .chrome, .velvet, .reportage, .pastel, .portrait, .gold, .seventies: .colourFilm
        case .noir, .silver, .push, .redFilter, .wetzlarMono, .sepia: .blackAndWhite
        }
    }

    var title: String {
        switch self {
        case .koda: "KODA 250"
        case .blockbuster: "TEAL & AMBER"
        case .bleach: "BLEACH"
        case .noir: "NOIR"
        case .seventies: "FADE 70"
        case .night: "DAY FOR NIGHT"
        case .tungsten500: "CINE 500T"
        case .wetzlar: "WETZLAR"
        case .chrome: "E-6 CHROME"
        case .velvet: "VELVET 50"
        case .reportage: "REPORTAGE"
        case .pastel: "PASTEL 400"
        case .portrait: "PORTRAIT 400"
        case .gold: "GOLD 200"
        case .silver: "SILVER 100"
        case .push: "PUSH 1600"
        case .redFilter: "RED FILTER"
        case .wetzlarMono: "WETZLAR MONO"
        case .sepia: "SEPIA"
        }
    }

    func cube() -> LookCube {
        let size = 33
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let step = Float(size - 1)
                    let out = grade(SIMD3(Float(r) / step, Float(g) / step, Float(b) / step))
                    let c = simd_clamp(out, SIMD3(repeating: 0), SIMD3(repeating: 1))
                    values += [c.x, c.y, c.z, 1]
                }
            }
        }
        return LookCube(size: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private func grade(_ c: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .koda:
            // Film warmth: a gentle S-curve, lifted blacks, warm highlights, softer colour.
            var c = Self.contrast(c, 0.35)
            c = 0.04 + c * 0.94
            let l = Self.luma(c)
            c += SIMD3(0.035, 0.008, -0.045) * l
            return Self.saturation(c, 0.88)
        case .blockbuster:
            // Teal shadows, amber highlights, punchy.
            var c = Self.contrast(c, 0.3)
            let l = Self.luma(c)
            c += SIMD3(-0.04, 0.01, 0.06) * (1 - l) + SIMD3(0.06, 0.015, -0.06) * l
            return Self.saturation(c, 1.12)
        case .bleach:
            // Bleach bypass: half the colour, hard contrast.
            return Self.saturation(Self.contrast(c, 0.6), 0.45)
        case .noir:
            let l = Self.luma(Self.contrast(c, 0.7))
            return SIMD3(repeating: 0.02 + l * 0.97)
        case .seventies:
            // Faded print: milky blacks, low contrast, yellowed, colour fading.
            var c = 0.08 + c * 0.84
            c += SIMD3(0.03, 0.02, -0.04)
            return Self.saturation(c, 0.78)
        case .night:
            // Day for night: darker, blue and nearly colourless.
            let c = Self.saturation(Self.contrast(c, 0.2), 0.35) * 0.62
            return c * SIMD3(0.72, 0.86, 1.18)
        case .tungsten500:
            // Fast tungsten cine negative, printed: soft contrast with a long shoulder, cyan-teal
            // in the shadows, warm and a little rosy in the highlights, colour held back.
            var c = Self.shoulder(0.025 + Self.contrast(c, 0.22) * 0.96, 0.75)
            let l = Self.luma(c)
            c += SIMD3(-0.03, 0.006, 0.028) * (1 - l) * (1 - l) + SIMD3(0.045, 0.012, -0.025) * l * l
            return Self.saturation(c, 0.9)
        case .wetzlar:
            // The rangefinder rendering: deep, rich shadows, strong but smooth contrast, warm
            // middle tones, reds and oranges full, greens a touch quieter.
            var c = Self.shoulder(Self.power(Self.contrast(c, 0.42), 1.08), 0.85)
            let l = Self.luma(c)
            c += SIMD3(0.02, 0.006, -0.016) * (4 * l * (1 - l))
            c.x += Self.redness(c) * 0.06
            c = Self.saturation(c, 1.06)
            return c - SIMD3(0.01, -0.004, 0.012) * Self.greenness(c)
        case .chrome:
            // Classic E-6 slide: clean, crisp, high contrast, cool-neutral whites, deep clear
            // blues and true skin.
            var c = Self.contrast(c, 0.5)
            c = simd_max(SIMD3(repeating: 0), (c - 0.015) / 0.985)
            let blue = Self.blueness(c)
            c += SIMD3(-0.03, 0.005, 0.08) * blue
            let l = Self.luma(c)
            c += SIMD3(-0.012, 0, 0.018) * l * l
            return Self.saturation(c, 1.12)
        case .velvet:
            // The fine-grain landscape slide: intense colour, deep greens, magenta-leaning reds,
            // dense shadows.
            var c = Self.power(Self.contrast(c, 0.55), 1.12)
            let green = Self.greenness(c)
            c += SIMD3(-0.04, 0.05, -0.02) * green
            c.z += Self.redness(c) * 0.06
            return Self.saturation(c, 1.38)
        case .reportage:
            // The documentary chrome: colour muted, hard shadows, soft highlights, skies pulled
            // towards cyan, reds held down.
            var c = Self.shoulder(Self.power(Self.contrast(c, 0.4), 1.14), 0.7)
            let blue = Self.blueness(c)
            c.y += blue * 0.07
            c.x -= Self.redness(c) * 0.05
            c += SIMD3(0.008, 0.008, -0.01)
            return Self.saturation(c, 0.7)
        case .pastel:
            // The airy portrait negative, rated over: lifted, bright and pastel, mint in the
            // shadows, greens turning cool.
            var c = Self.contrast(Self.power(0.06 + c * 0.92, 0.88), 0.12)
            let l = Self.luma(c)
            c += SIMD3(-0.016, 0.018, 0.01) * (1 - l)
            c.z += Self.greenness(c) * 0.08
            return Self.saturation(c, 0.78)
        case .portrait:
            // The professional portrait negative: low contrast, wide latitude, warm and kind to
            // skin, natural colour.
            var c = Self.shoulder(0.03 + Self.contrast(c, 0.18) * 0.95, 0.7)
            let l = Self.luma(c)
            c += SIMD3(0.02, 0.008, -0.014) * l
            c.x += Self.redness(c) * 0.03
            return Self.saturation(c, 0.92)
        case .gold:
            // The everyday consumer film: sunny, golden, saturated, a bit of punch.
            var c = Self.contrast(c, 0.3)
            let l = Self.luma(c)
            c += SIMD3(0.04, 0.022, -0.05) * (0.4 + 0.6 * l)
            return Self.saturation(c, 1.15)
        case .silver:
            // Smooth fine-grain black and white: neutral, gentle S, clean whites.
            let l = Self.contrast(SIMD3(repeating: Self.mix(c, 0.3, 0.59, 0.11)), 0.4).x
            return SIMD3(repeating: 0.012 + l * 0.98)
        case .push:
            // Fast black and white pushed two stops: hard, gritty contrast, crushed blacks.
            let l = Self.mix(c, 0.36, 0.54, 0.1)
            let hard = Self.contrast(Self.contrast(SIMD3(repeating: l), 1), 0.6).x
            return SIMD3(repeating: max(0, min(1, (hard - 0.03) * 1.06)))
        case .redFilter:
            // Black and white through a red filter: blue skies go dark, skin goes pale.
            let l = Self.mix(c, 0.72, 0.28, 0)
            return SIMD3(repeating: Self.contrast(SIMD3(repeating: l), 0.45).x)
        case .wetzlarMono:
            // The monochrome rangefinder: a long, smooth scale with deep blacks and soft,
            // detailed highlights.
            let l = Self.mix(c, 0.27, 0.62, 0.11)
            let curved = Self.shoulder(Self.power(SIMD3(repeating: l), 1.1), 0.8)
            return Self.contrast(curved, 0.22)
        case .sepia:
            // Black and white, toned warm brown in the middle tones, the whites kept clean.
            let l = Self.contrast(SIMD3(repeating: Self.mix(c, 0.3, 0.59, 0.11)), 0.35).x
            let tone = SIMD3<Float>(0.07, 0.02, -0.07) * (4 * l * (1 - l))
            return SIMD3(repeating: 0.02 + l * 0.96) + tone
        }
    }

    private static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// Grey from the channels in these amounts, as a filter on black-and-white film would.
    private static func mix(_ c: SIMD3<Float>, _ r: Float, _ g: Float, _ b: Float) -> Float {
        r * c.x + g * c.y + b * c.z
    }

    private static func saturation(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        let l = SIMD3(repeating: luma(c))
        return l + (c - l) * amount
    }

    /// Towards a smooth S-curve round the middle grey, by `amount` (0…1).
    private static func contrast(_ c: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
        let x = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let s = x * x * (3 - 2 * x)
        return x + (s - x) * amount
    }

    /// A gamma: above 1 deepens the shadows and middle, below 1 opens them up.
    private static func power(_ c: SIMD3<Float>, _ gamma: Float) -> SIMD3<Float> {
        let x = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD3(pow(x.x, gamma), pow(x.y, gamma), pow(x.z, gamma))
    }

    /// Highlights above `knee` rolled off gently, so white prints a little short of paper white
    /// rather than clipping hard.
    private static func shoulder(_ c: SIMD3<Float>, _ knee: Float) -> SIMD3<Float> {
        func roll(_ x: Float) -> Float {
            guard x > knee else { return x }
            let room = 1 - knee
            let over = (x - knee) / room
            return knee + room * (over - 0.175 * over * over)
        }
        let x = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD3(roll(x.x), roll(x.y), roll(x.z))
    }

    /// How much more red than green or blue a colour is.
    private static func redness(_ c: SIMD3<Float>) -> Float { max(0, c.x - max(c.y, c.z)) }
    private static func greenness(_ c: SIMD3<Float>) -> Float { max(0, c.y - max(c.x, c.z)) }
    private static func blueness(_ c: SIMD3<Float>) -> Float { max(0, c.z - max(c.x, c.y)) }
}
