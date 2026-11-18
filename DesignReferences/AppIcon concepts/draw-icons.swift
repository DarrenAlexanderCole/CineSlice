import AppKit
import CoreGraphics

// Draws CineSlice app-icon concepts at 1024×1024 (iOS rounds the corners itself).

let S: CGFloat = 1024
let signal = CGColor(red: 0xD0 / 255, green: 0xDB / 255, blue: 0x65 / 255, alpha: 1)
let ivory = CGColor(red: 0xEC / 255, green: 0xE9 / 255, blue: 0xDD / 255, alpha: 1)
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255,
        alpha: a)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint, in path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat, in path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Seeded grain and horizontal brushing over a region.
func texture(_ ctx: CGContext, in path: CGPath, brushed: Bool, strength: CGFloat = 1) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    var state: UInt32 = 0x9E37_79B9
    func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return CGFloat(state % 1000) / 1000
    }
    if brushed {
        var y: CGFloat = 0
        while y < S {
            let v = next()
            ctx.setFillColor(v > 0.5 ? CGColor(gray: 1, alpha: (v - 0.5) * 0.12 * strength) : CGColor(gray: 0, alpha: (0.5 - v) * 0.14 * strength))
            ctx.fill(CGRect(x: 0, y: y, width: S, height: 1.2))
            y += 1.5
        }
    }
    for _ in 0..<26000 {
        let x = next() * S
        let y = next() * S
        let v = next()
        ctx.setFillColor(v > 0.5 ? CGColor(gray: 1, alpha: 0.05 * strength) : CGColor(gray: 0, alpha: 0.07 * strength))
        ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
    }
    ctx.restoreGState()
}

func screw(_ ctx: CGContext, at p: CGPoint, r: CGFloat, angle: CGFloat) {
    let disc = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
    ctx.fillEllipse(in: CGRect(x: p.x - r - 2, y: p.y - r - 4, width: 2 * r + 4, height: 2 * r + 4))
    linear(ctx, [hex(0xF2F0E6), hex(0xA9AB9F), hex(0x6E7066)], from: CGPoint(x: p.x, y: p.y + r), to: CGPoint(x: p.x, y: p.y - r), in: disc)
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.rotate(by: angle)
    ctx.setFillColor(CGColor(gray: 0, alpha: 0.65))
    ctx.fill(CGRect(x: -r * 0.75, y: -r * 0.13, width: r * 1.5, height: r * 0.26))
    ctx.restoreGState()
}

func rounded(_ r: CGRect, _ c: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil) }

/// A strip of 35mm-style film between two points, with sprocket holes, `width` across.
func filmStrip(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat, frameTint: CGColor) {
    let dx = b.x - a.x, dy = b.y - a.y
    let length = hypot(dx, dy)
    ctx.saveGState()
    ctx.translateBy(x: a.x, y: a.y)
    ctx.rotate(by: atan2(dy, dx))
    let body = CGRect(x: 0, y: -width / 2, width: length, height: width)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.6))
    ctx.setFillColor(hex(0x1A140C))
    ctx.fill(body)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Frames.
    let frameH = width * 0.62
    let frameW = frameH * 0.78
    var x: CGFloat = width * 0.12
    while x + frameW < length {
        let frame = CGRect(x: x, y: -frameH / 2, width: frameW, height: frameH)
        linear(ctx, [frameTint, hex(0x3A2A14)], from: CGPoint(x: x, y: frameH / 2), to: CGPoint(x: x, y: -frameH / 2), in: rounded(frame, 6))
        x += frameW + width * 0.08
    }
    // Sprockets.
    let hole = width * 0.07
    var s: CGFloat = hole
    while s < length - hole {
        for y in [width / 2 - hole * 1.6, -width / 2 + hole * 0.6] {
            ctx.setFillColor(hex(0xE8DCC0, 0.85))
            ctx.addPath(rounded(CGRect(x: s, y: y, width: hole * 1.3, height: hole), 3))
            ctx.fillPath()
        }
        s += hole * 2.6
    }
    ctx.restoreGState()
}

func render(_ name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    draw(gc.cgContext)
    gc.flushGraphics()
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let full = CGPath(rect: CGRect(x: 0, y: 0, width: S, height: S), transform: nil)

// A: the Moviola. Sage enamel viewer, black hood, a lit 9:16 screen with film being sliced on it.
render("A-Moviola") { ctx in
    linear(ctx, [hex(0x2B3123), hex(0x14170F)], from: CGPoint(x: 0, y: S), to: .zero, in: full)
    texture(ctx, in: full, brushed: false)
    let body = rounded(CGRect(x: 150, y: 70, width: 724, height: 860), 120)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 50, color: CGColor(gray: 0, alpha: 0.7))
    ctx.addPath(body)
    ctx.setFillColor(hex(0x8A9774))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, [hex(0xA7B68B), hex(0x8A9774), hex(0x56623B)], from: CGPoint(x: 0, y: 930), to: CGPoint(x: 0, y: 70), in: body)
    texture(ctx, in: body, brushed: false, strength: 1.4)
    // Hood and screen.
    let hood = rounded(CGRect(x: 230, y: 250, width: 564, height: 610), 70)
    linear(ctx, [hex(0x0B0C09), hex(0x22261D)], from: CGPoint(x: 0, y: 860), to: CGPoint(x: 0, y: 250), in: hood)
    let screenRect = CGRect(x: 342, y: 300, width: 340, height: 500)
    let screen = rounded(screenRect, 24)
    radial(ctx, [hex(0xFFF6D8), hex(0xE6DDBB), hex(0x9C9578)], center: CGPoint(x: 512, y: 560), radius: 340, in: screen)
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    filmStrip(ctx, from: CGPoint(x: 512, y: 840), to: CGPoint(x: 512, y: 250), width: 210, frameTint: hex(0xC98A3A))
    ctx.restoreGState()
    // The slice: a lit diagonal cut across the screen.
    ctx.saveGState()
    ctx.addPath(screen)
    ctx.clip()
    ctx.setShadow(offset: .zero, blur: 30, color: signal)
    ctx.setStrokeColor(signal)
    ctx.setLineWidth(16)
    ctx.move(to: CGPoint(x: 300, y: 470))
    ctx.addLine(to: CGPoint(x: 720, y: 640))
    ctx.strokePath()
    ctx.restoreGState()
    // Knobs under the hood.
    for x: CGFloat in [300, 724] {
        let knob = CGPath(ellipseIn: CGRect(x: x - 58, y: 120, width: 116, height: 116), transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(knob)
        ctx.setFillColor(hex(0x1C1F1C))
        ctx.fillPath()
        ctx.restoreGState()
        radial(ctx, [hex(0xD9DBCF), hex(0x9A9D90), hex(0x55584E)], center: CGPoint(x: x - 15, y: 195), radius: 80, in: knob)
    }
    screw(ctx, at: CGPoint(x: 512, y: 180), r: 22, angle: 0.5)
    screw(ctx, at: CGPoint(x: 205, y: 870), r: 18, angle: 0.3)
    screw(ctx, at: CGPoint(x: 819, y: 870), r: 18, angle: -0.6)
}

// B: the splicer. Brushed aluminum block, a strip of film across it, a blade coming down through it.
render("B-Splicer") { ctx in
    linear(ctx, [hex(0x3B4430), hex(0x1A1E15)], from: CGPoint(x: 0, y: S), to: .zero, in: full)
    texture(ctx, in: full, brushed: true)
    // The block.
    let block = rounded(CGRect(x: 90, y: 250, width: 844, height: 420), 60)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 50, color: CGColor(gray: 0, alpha: 0.75))
    ctx.addPath(block)
    ctx.setFillColor(hex(0xA9AC9E))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, [hex(0xF0EEE4), hex(0xBFC1B4), hex(0x7E8173)], from: CGPoint(x: 0, y: 670), to: CGPoint(x: 0, y: 250), in: block)
    texture(ctx, in: block, brushed: true, strength: 2)
    // Film across, cut in two.
    filmStrip(ctx, from: CGPoint(x: -40, y: 470), to: CGPoint(x: 492, y: 470), width: 220, frameTint: hex(0xC98A3A))
    filmStrip(ctx, from: CGPoint(x: 532, y: 470), to: CGPoint(x: 1064, y: 470), width: 220, frameTint: hex(0xC98A3A))
    // The blade: a steel wedge on a handle, its edge lit Signal at the cut.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 18, height: -18), blur: 30, color: CGColor(gray: 0, alpha: 0.6))
    let blade = CGMutablePath()
    blade.move(to: CGPoint(x: 470, y: 330))
    blade.addLine(to: CGPoint(x: 560, y: 330))
    blade.addLine(to: CGPoint(x: 640, y: 900))
    blade.addLine(to: CGPoint(x: 420, y: 900))
    blade.closeSubpath()
    ctx.addPath(blade)
    ctx.setFillColor(hex(0x6E7066))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, [hex(0x5C5F55), hex(0xE8E8E0), hex(0x8A8D82)], from: CGPoint(x: 420, y: 0), to: CGPoint(x: 640, y: 0), in: blade)
    let handle = rounded(CGRect(x: 380, y: 860, width: 300, height: 90), 45)
    linear(ctx, [hex(0x2A2D26), hex(0x101210)], from: CGPoint(x: 0, y: 950), to: CGPoint(x: 0, y: 860), in: handle)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: signal)
    ctx.setStrokeColor(signal)
    ctx.setLineWidth(12)
    ctx.move(to: CGPoint(x: 470, y: 330))
    ctx.addLine(to: CGPoint(x: 560, y: 330))
    ctx.strokePath()
    ctx.restoreGState()
    for p in [CGPoint(x: 150, y: 310), CGPoint(x: 874, y: 310), CGPoint(x: 150, y: 610), CGPoint(x: 874, y: 610)] {
        screw(ctx, at: p, r: 22, angle: p.x / 300)
    }
}

// C: the gate. A machined gate plate with a lit 9:16 aperture, the picture sliced diagonally.
render("C-Gate") { ctx in
    linear(ctx, [hex(0x2B3123), hex(0x111410)], from: CGPoint(x: 0, y: S), to: .zero, in: full)
    let plate = rounded(CGRect(x: 110, y: 110, width: 804, height: 804), 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: CGColor(gray: 0, alpha: 0.75))
    ctx.addPath(plate)
    ctx.setFillColor(hex(0x9EA391))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, [hex(0xD6D9CA), hex(0x9EA391), hex(0x5F6456)], from: CGPoint(x: 0, y: 914), to: CGPoint(x: 0, y: 110), in: plate)
    texture(ctx, in: plate, brushed: true, strength: 2)
    // The bevelled aperture.
    let ap = CGRect(x: 512 - 175, y: 512 - 300, width: 350, height: 600)
    let bevel = rounded(ap.insetBy(dx: -26, dy: -26), 40)
    linear(ctx, [hex(0x2A2D25), hex(0x5A5E52), hex(0xEDEBE0)], from: CGPoint(x: 0, y: ap.maxY + 26), to: CGPoint(x: 0, y: ap.minY - 26), in: bevel)
    let aperture = rounded(ap, 18)
    radial(ctx, [hex(0x3A4A2E), hex(0x1C2416), hex(0x0A0C08)], center: CGPoint(x: 512, y: 560), radius: 420, in: aperture)
    // The picture, cut on a diagonal: the two halves slightly apart, the cut lit.
    ctx.saveGState()
    ctx.addPath(aperture)
    ctx.clip()
    let cutA = CGPoint(x: ap.minX - 40, y: 420), cutB = CGPoint(x: ap.maxX + 40, y: 620)
    let upper = CGMutablePath()
    upper.move(to: CGPoint(x: ap.minX - 50, y: ap.maxY + 50))
    upper.addLine(to: CGPoint(x: ap.maxX + 50, y: ap.maxY + 50))
    upper.addLine(to: CGPoint(x: cutB.x, y: cutB.y + 14))
    upper.addLine(to: CGPoint(x: cutA.x, y: cutA.y + 14))
    upper.closeSubpath()
    radial(ctx, [hex(0xF6E9C2), hex(0xD69A4A), hex(0x6B4320)], center: CGPoint(x: 470, y: 760), radius: 360, in: upper)
    let lower = CGMutablePath()
    lower.move(to: CGPoint(x: cutA.x, y: cutA.y - 14))
    lower.addLine(to: CGPoint(x: cutB.x, y: cutB.y - 14))
    lower.addLine(to: CGPoint(x: ap.maxX + 50, y: ap.minY - 50))
    lower.addLine(to: CGPoint(x: ap.minX - 50, y: ap.minY - 50))
    lower.closeSubpath()
    radial(ctx, [hex(0xB9C4A0), hex(0x56623B), hex(0x1E2416)], center: CGPoint(x: 560, y: 320), radius: 360, in: lower)
    ctx.setShadow(offset: .zero, blur: 30, color: signal)
    ctx.setStrokeColor(signal)
    ctx.setLineWidth(10)
    ctx.move(to: cutA)
    ctx.addLine(to: cutB)
    ctx.strokePath()
    ctx.restoreGState()
    // Corner brackets in the aperture.
    ctx.setStrokeColor(signal)
    ctx.setLineWidth(8)
    ctx.setLineCap(.round)
    for (c, sx, sy) in [(CGPoint(x: ap.minX + 30, y: ap.maxY - 30), 1.0, -1.0), (CGPoint(x: ap.maxX - 30, y: ap.maxY - 30), -1.0, -1.0), (CGPoint(x: ap.minX + 30, y: ap.minY + 30), 1.0, 1.0), (CGPoint(x: ap.maxX - 30, y: ap.minY + 30), -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: c.x + 50 * sx, y: c.y))
        ctx.addLine(to: c)
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 50 * sy))
        ctx.strokePath()
    }
    for p in [CGPoint(x: 215, y: 470), CGPoint(x: 215, y: 554), CGPoint(x: 809, y: 470), CGPoint(x: 809, y: 554)] {
        screw(ctx, at: p, r: 24, angle: p.y / 200)
    }
}

// MARK: - Worn metal

/// A seeded random source, so every render is identical.
struct Rand {
    var state: UInt32
    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return CGFloat(state % 100_000) / 100_000
    }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

/// Hand-brushed metal: thousands of horizontal streaks of uneven length and strength, a broad
/// sheen across the grain, fine scratches, and grime pooled toward `grimeEdges`.
func wornMetal(_ ctx: CGContext, in path: CGPath, seed: UInt32, sheenAngle: CGFloat = 0.35) {
    var r = Rand(state: seed)
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // Streaks.
    for _ in 0..<9000 {
        let y = r.range(box.minY, box.maxY)
        let x = r.range(box.minX - 200, box.maxX)
        let len = r.range(40, 520)
        let light = r.next() > 0.45
        let a = r.range(0.015, light ? 0.09 : 0.11)
        ctx.setFillColor(light ? CGColor(gray: 1, alpha: a) : CGColor(gray: 0, alpha: a))
        ctx.fill(CGRect(x: x, y: y, width: len, height: r.range(0.5, 1.6)))
    }
    // A broad anisotropic sheen: brushed metal throws a soft band of light across its grain.
    ctx.saveGState()
    ctx.translateBy(x: box.midX, y: box.midY)
    ctx.rotate(by: sheenAngle)
    let band = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(band, start: CGPoint(x: 0, y: -260), end: CGPoint(x: 0, y: 120), options: [])
    ctx.restoreGState()
    // Scratches: short, at odd angles, each with a lit edge and a dark one.
    for _ in 0..<140 {
        let p = CGPoint(x: r.range(box.minX, box.maxX), y: r.range(box.minY, box.maxY))
        let ang = r.range(-0.6, 0.6) + (r.next() > 0.8 ? 1.4 : 0)
        let len = r.range(14, 90)
        let q = CGPoint(x: p.x + cos(ang) * len, y: p.y + sin(ang) * len)
        ctx.setLineWidth(r.range(0.6, 1.4))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: r.range(0.08, 0.22)))
        ctx.move(to: p)
        ctx.addLine(to: q)
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: r.range(0.06, 0.14)))
        ctx.move(to: CGPoint(x: p.x, y: p.y - 1.2))
        ctx.addLine(to: CGPoint(x: q.x, y: q.y - 1.2))
        ctx.strokePath()
    }
    // Pitting and dust.
    for _ in 0..<5000 {
        let s = r.range(1, 3.2)
        ctx.setFillColor(CGColor(gray: r.next() > 0.6 ? 1 : 0, alpha: r.range(0.03, 0.1)))
        ctx.fillEllipse(in: CGRect(x: r.range(box.minX, box.maxX), y: r.range(box.minY, box.maxY), width: s, height: s))
    }
    // Grime toward the edges and corners, where hands and polish don't reach.
    let grime = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0x2A2414, 0), hex(0x2A2414, 0.0), hex(0x231E10, 0.6)] as CFArray, locations: [0, 0.62, 1])!
    ctx.drawRadialGradient(
        grime, startCenter: CGPoint(x: box.midX, y: box.midY + 40), startRadius: 0,
        endCenter: CGPoint(x: box.midX, y: box.midY), endRadius: box.width * 0.72, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

/// The rim of a worn plate: a dark lip, and a soft polish where hands rub it, brightest at the
/// top and fading round the sides.
func wornEdge(_ ctx: CGContext, _ path: CGPath, seed: UInt32) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(6)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.4))
    ctx.strokePath()
    ctx.addPath(path.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    let polish = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0.3)] as CFArray,
        locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(
        polish, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
    ctx.restoreGState()
}

/// Soft patches of patina: old fingerprints and oxidation, blurred, never crisp.
func patina(_ ctx: CGContext, in path: CGPath, seed: UInt32) {
    var r = Rand(state: seed)
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    for _ in 0..<12 {
        let c = CGPoint(x: r.range(box.minX, box.maxX), y: r.range(box.minY, box.maxY))
        let radius = r.range(60, 190)
        let blob = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: (r.next() > 0.35 ? [hex(0x3B3218, r.range(0.35, 0.55)), hex(0x3B3218, 0)] : [hex(0xFFFFF0, r.range(0.2, 0.32)), hex(0xFFFFF0, 0)]) as CFArray, locations: [0, 1])!
        ctx.saveGState()
        // Squashed along the grain, the way a rub or a fingerprint spreads.
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1.6, y: 0.7)
        ctx.drawRadialGradient(blob, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func wornScrew(_ ctx: CGContext, at p: CGPoint, r: CGFloat, angle: CGFloat, seed: UInt32) {
    // A dark ring of old oil round the head.
    ctx.saveGState()
    let ring = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [hex(0x1C170C, 0.55), hex(0x1C170C, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(ring, startCenter: p, startRadius: r, endCenter: p, endRadius: r * 1.9, options: [])
    ctx.restoreGState()
    screw(ctx, at: p, r: r, angle: angle)
    let head = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil)
    var rr = Rand(state: seed)
    ctx.saveGState()
    ctx.addPath(head)
    ctx.clip()
    // Burrs on the slot and tarnish.
    for _ in 0..<60 {
        ctx.setFillColor(CGColor(gray: rr.next() > 0.5 ? 1 : 0, alpha: rr.range(0.05, 0.2)))
        ctx.fillEllipse(in: CGRect(x: rr.range(p.x - r, p.x + r), y: rr.range(p.y - r, p.y + r), width: 2, height: 2))
    }
    ctx.setFillColor(hex(0x5A4A22, 0.18))
    ctx.fill(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: r))
    ctx.restoreGState()
}

/// Film grain over a picture.
func filmGrain(_ ctx: CGContext, in path: CGPath, seed: UInt32) {
    var r = Rand(state: seed)
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    for _ in 0..<14000 {
        let s = r.range(1, 2.6)
        ctx.setFillColor(CGColor(gray: r.next() > 0.5 ? 1 : 0, alpha: r.range(0.04, 0.12)))
        ctx.fill(CGRect(x: r.range(box.minX, box.maxX), y: r.range(box.minY, box.maxY), width: s, height: s))
    }
    ctx.restoreGState()
}

// C2: the gate, worn. Same composition as C, in old hand-brushed metal.
render("C2-Gate-worn") { ctx in
    // Backdrop: a dark, grimy olive bench.
    linear(ctx, [hex(0x2E3425), hex(0x15180F)], from: CGPoint(x: 0, y: S), to: .zero, in: full)
    var bg = Rand(state: 77)
    for _ in 0..<20000 {
        ctx.setFillColor(CGColor(gray: bg.next() > 0.5 ? 1 : 0, alpha: bg.range(0.02, 0.06)))
        ctx.fill(CGRect(x: bg.range(0, S), y: bg.range(0, S), width: 2, height: 2))
    }
    let plate = rounded(CGRect(x: 104, y: 104, width: 816, height: 816), 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 50, color: CGColor(gray: 0, alpha: 0.8))
    ctx.addPath(plate)
    ctx.setFillColor(hex(0x8E927F))
    ctx.fillPath()
    ctx.restoreGState()
    // Warmer, duller aluminum than C: old metal has a little yellow in it.
    linear(ctx, [hex(0xC9C8B4), hex(0x9C9D88), hex(0x6B6C5A)], from: CGPoint(x: 0, y: 920), to: CGPoint(x: 0, y: 104), in: plate)
    wornMetal(ctx, in: plate, seed: 4242)
    patina(ctx, in: plate, seed: 8)
    wornEdge(ctx, plate, seed: 99)

    // The aperture's bevel, its chamfer brushed across the other way and rubbed bright.
    let ap = CGRect(x: 512 - 175, y: 512 - 300, width: 350, height: 600)
    let bevel = rounded(ap.insetBy(dx: -30, dy: -30), 42)
    linear(ctx, [hex(0x1E1F18), hex(0x4E5044), hex(0xD6D3C0)], from: CGPoint(x: 0, y: ap.maxY + 30), to: CGPoint(x: 0, y: ap.minY - 30), in: bevel)
    // Clip to the bevel first, then brush it across the other way.
    ctx.saveGState()
    ctx.addPath(bevel)
    ctx.clip()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: .pi / 2)
    ctx.translateBy(x: -512, y: -512)
    wornMetal(ctx, in: CGPath(rect: CGRect(x: 0, y: 0, width: S, height: S), transform: nil), seed: 777, sheenAngle: -0.4)
    ctx.restoreGState()
    wornEdge(ctx, bevel, seed: 5)

    // The picture: warm and cool halves of a frame, cut on the diagonal, with grain and a soft
    // halation round the lit cut.
    let aperture = rounded(ap, 16)
    radial(ctx, [hex(0x2E3A24), hex(0x12160D)], center: CGPoint(x: 512, y: 560), radius: 420, in: aperture)
    ctx.saveGState()
    ctx.addPath(aperture)
    ctx.clip()
    let cutA = CGPoint(x: ap.minX - 40, y: 420), cutB = CGPoint(x: ap.maxX + 40, y: 620)
    let upper = CGMutablePath()
    upper.move(to: CGPoint(x: ap.minX - 50, y: ap.maxY + 50))
    upper.addLine(to: CGPoint(x: ap.maxX + 50, y: ap.maxY + 50))
    upper.addLine(to: CGPoint(x: cutB.x, y: cutB.y + 12))
    upper.addLine(to: CGPoint(x: cutA.x, y: cutA.y + 12))
    upper.closeSubpath()
    radial(ctx, [hex(0xEFD9A6), hex(0xC0843E), hex(0x5A3818)], center: CGPoint(x: 470, y: 760), radius: 380, in: upper)
    let lower = CGMutablePath()
    lower.move(to: CGPoint(x: cutA.x, y: cutA.y - 12))
    lower.addLine(to: CGPoint(x: cutB.x, y: cutB.y - 12))
    lower.addLine(to: CGPoint(x: ap.maxX + 50, y: ap.minY - 50))
    lower.addLine(to: CGPoint(x: ap.minX - 50, y: ap.minY - 50))
    lower.closeSubpath()
    radial(ctx, [hex(0xA9B48E), hex(0x4E5A35), hex(0x181D11)], center: CGPoint(x: 560, y: 330), radius: 380, in: lower)
    filmGrain(ctx, in: aperture, seed: 31)
    // Vignette, like a lamp behind ground glass.
    let vig = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.5)] as CFArray, locations: [0.45, 1])!
    ctx.drawRadialGradient(vig, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 400, options: [.drawsAfterEndLocation])
    ctx.setShadow(offset: .zero, blur: 40, color: signal)
    ctx.setStrokeColor(signal)
    ctx.setLineWidth(9)
    ctx.move(to: cutA)
    ctx.addLine(to: cutB)
    ctx.strokePath()
    ctx.restoreGState()
    // Corner marks, a little dimmer than C: painted on, not glowing.
    ctx.setStrokeColor(hex(0xD0DB65, 0.85))
    ctx.setLineWidth(7)
    ctx.setLineCap(.round)
    for (c, sx, sy) in [(CGPoint(x: ap.minX + 30, y: ap.maxY - 30), 1.0, -1.0), (CGPoint(x: ap.maxX - 30, y: ap.maxY - 30), -1.0, -1.0), (CGPoint(x: ap.minX + 30, y: ap.minY + 30), 1.0, 1.0), (CGPoint(x: ap.maxX - 30, y: ap.minY + 30), -1.0, 1.0)] {
        ctx.move(to: CGPoint(x: c.x + 46 * sx, y: c.y))
        ctx.addLine(to: c)
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 46 * sy))
        ctx.strokePath()
    }
    // Grime in the aperture's inner corner, where the bevel meets the picture.
    ctx.saveGState()
    ctx.addPath(aperture)
    ctx.setLineWidth(10)
    ctx.setStrokeColor(hex(0x0E0B05, 0.55))
    ctx.strokePath()
    ctx.restoreGState()
    var i: UInt32 = 0
    for p in [CGPoint(x: 212, y: 466), CGPoint(x: 212, y: 558), CGPoint(x: 812, y: 466), CGPoint(x: 812, y: 558)] {
        i += 1
        wornScrew(ctx, at: p, r: 25, angle: p.y / 190 + CGFloat(i), seed: 300 + i)
    }
}
