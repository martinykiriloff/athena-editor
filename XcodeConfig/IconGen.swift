// IconGen.swift — draws the Athena app icon at 1024pt and writes a PNG.
// Run: swift IconGen.swift <variant> <out.png>

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry helpers

/// Apple's app-icon body is a superellipse, not a circular-arc rounded rect —
/// the corners flow into the sides instead of meeting them at a tangent break.
func squircle(in rect: CGRect, n: CGFloat = 5.0, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY

    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0)
    )!
}

/// Fills `path` with a top-to-bottom linear gradient across its bounding box.
func fill(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGFloat, CGColor)], angle: CGFloat = 90) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBoxOfPath
    let rad = angle * .pi / 180
    let dx = cos(rad), dy = sin(rad)
    let r = max(box.width, box.height)
    let start = CGPoint(x: box.midX - dx * r / 2, y: box.midY + dy * r / 2)
    let end = CGPoint(x: box.midX + dx * r / 2, y: box.midY - dy * r / 2)
    ctx.drawLinearGradient(gradient(stops), start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: - Canvas

let S: CGFloat = 1024
/// Apple's grid: an 824pt body centred on a 1024pt canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Design space is 1000×1000 with y pointing down (SVG-style), mapped onto the
/// icon body — far easier to reason about when hand-authoring paths.
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: body.minX + x / 1000 * body.width,
            y: body.maxY - y / 1000 * body.height)
}

// MARK: - Helmet

/// The mark is drawn in the 1000-space above, then scaled down and centred so
/// it keeps Apple's optical margin instead of running to the body's edges.
let markScale: CGFloat = 0.74
let markShiftY: CGFloat = 26

func M(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    P(500 + (x - 500) * markScale, 500 + (y - 500 + markShiftY) * markScale)
}

/// Front-facing Corinthian helmet, drawn as a logo rather than an
/// illustration: flat planes, hard angles, no interior detail. Symmetry is
/// deliberate — a centred mark sits better in a Dock than an off-axis profile,
/// and the silhouette still resolves at 16pt.
func helmetPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: M(500, 168))
    // Dome, right side.
    p.addCurve(to: M(742, 452), control1: M(650, 168), control2: M(742, 292))
    // Straightish temple down to the cheek.
    p.addCurve(to: M(716, 640), control1: M(742, 546), control2: M(736, 590))
    // Cheek piece tapering to a point.
    p.addCurve(to: M(590, 818), control1: M(694, 716), control2: M(646, 780))
    // Inner edge of the cheek, rising back up.
    p.addCurve(to: M(556, 648), control1: M(560, 766), control2: M(556, 716))
    // Chin gap.
    p.addCurve(to: M(444, 648), control1: M(522, 614), control2: M(478, 614))
    // Left half, mirrored.
    p.addCurve(to: M(410, 818), control1: M(444, 716), control2: M(440, 766))
    p.addCurve(to: M(284, 640), control1: M(354, 780), control2: M(306, 716))
    p.addCurve(to: M(258, 452), control1: M(264, 590), control2: M(258, 546))
    p.addCurve(to: M(500, 168), control1: M(258, 292), control2: M(350, 168))
    p.closeSubpath()
    return p
}

/// One eye opening — a slot raked down towards the nose, which is what gives a
/// Corinthian helmet its glare. `sign` is -1 for the left eye.
func eyePath(sign: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: M(500 + sign * 88,  470))
    p.addCurve(to: M(500 + sign * 206, 432), control1: M(500 + sign * 140, 446), control2: M(500 + sign * 176, 430))
    p.addCurve(to: M(500 + sign * 216, 512), control1: M(500 + sign * 226, 434), control2: M(500 + sign * 226, 480))
    p.addCurve(to: M(500 + sign * 104, 556), control1: M(500 + sign * 204, 552), control2: M(500 + sign * 156, 556))
    p.addCurve(to: M(500 + sign * 88,  470), control1: M(500 + sign * 84,  556), control2: M(500 + sign * 76, 504))
    p.closeSubpath()
    return p
}

/// The nose guard doubles as a text caret — the one nod to what the app is.
func nosePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: M(500, 742))
    p.addCurve(to: M(462, 660), control1: M(478, 742), control2: M(462, 712))
    p.addLine(to: M(468, 430))
    p.addLine(to: M(532, 430))
    p.addLine(to: M(538, 660))
    p.addCurve(to: M(500, 742), control1: M(538, 712), control2: M(522, 742))
    p.closeSubpath()
    return p
}

/// The plume, overlapping the dome so the union stays solid. On its own that
/// merges the two into one blob — `separatorPath` below carves the dividing
/// line back in, which is how a crest reads on a real hoplite mark.
func crestPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: M(188, 424))
    p.addCurve(to: M(500, 78),  control1: M(206, 232), control2: M(328, 78))
    p.addCurve(to: M(812, 424), control1: M(672, 78),  control2: M(794, 232))
    p.addCurve(to: M(742, 408), control1: M(792, 414), control2: M(768, 408))
    p.addCurve(to: M(500, 300), control1: M(672, 348), control2: M(592, 300))
    p.addCurve(to: M(258, 408), control1: M(408, 300), control2: M(328, 348))
    p.addCurve(to: M(188, 424), control1: M(232, 408), control2: M(208, 414))
    p.closeSubpath()
    return p
}

/// A hairline carved along the skull's own outline. Where the crest sits on
/// top of the dome this becomes the division between them; everywhere else it
/// only erodes the silhouette edge by a few points, which is invisible.
func separatorPath() -> CGPath {
    helmetPath().copy(
        strokingWithWidth: 17, lineCap: .round, lineJoin: .round, miterLimit: 10
    )
}

// MARK: - Palettes

struct Palette {
    let name: String
    let background: [(CGFloat, CGColor)]
    let mark: [(CGFloat, CGColor)]
    let rim: CGColor
}

let palettes: [String: Palette] = [
    "bronze": Palette(
        name: "bronze",
        background: [(0, rgb(46, 52, 74)), (0.55, rgb(28, 31, 46)), (1, rgb(17, 18, 28))],
        mark: [(0, rgb(255, 226, 158)), (0.5, rgb(232, 176, 84)), (1, rgb(198, 130, 48))],
        rim: rgb(255, 255, 255, 0.16)
    ),
    "violet": Palette(
        name: "violet",
        background: [(0, rgb(124, 92, 255)), (0.55, rgb(88, 60, 214)), (1, rgb(52, 30, 148))],
        mark: [(0, rgb(255, 255, 255)), (1, rgb(224, 228, 255))],
        rim: rgb(255, 255, 255, 0.28)
    ),
    "olive": Palette(
        name: "olive",
        background: [(0, rgb(238, 240, 235)), (0.5, rgb(222, 226, 218)), (1, rgb(198, 205, 194))],
        mark: [(0, rgb(52, 74, 62)), (1, rgb(24, 40, 33))],
        rim: rgb(255, 255, 255, 0.7)
    ),
]

// MARK: - Render

/// `simplify` drops the hairline between crest and skull. Below roughly 64px
/// that line is thinner than a pixel and only turns to mud — the crest merging
/// into the dome is the correct reading at that size.
func render(palette: Palette, simplify: Bool = false) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let shape = squircle(in: body)

    // Contact shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0, 0, 0, 0.34))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    // Body.
    fill(ctx, shape, palette.background)

    // Top-left sheen, so the surface reads as lit rather than flat.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let sheen = gradient([(0, rgb(255, 255, 255, 0.20)), (1, rgb(255, 255, 255, 0))])
    ctx.drawRadialGradient(
        sheen,
        startCenter: CGPoint(x: body.minX + 180, y: body.maxY - 120), startRadius: 0,
        endCenter: CGPoint(x: body.minX + 180, y: body.maxY - 120), endRadius: 760,
        options: []
    )
    ctx.restoreGState()

    // Inner rim light along the top edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(palette.rim)
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Compose the mark with boolean ops rather than one even-odd path: the
    // crest has to *union* with the dome (so they read as one object) while
    // the eyes and nose guard have to be *subtracted* from it. Even-odd
    // cancels every overlap alike and cannot express both.
    var silhouette = crestPath().union(helmetPath())
    if !simplify { silhouette = silhouette.subtracting(separatorPath()) }
    let mark = silhouette
        .subtracting(eyePath(sign: 1))
        .subtracting(eyePath(sign: -1))
        .subtracting(nosePath())

    // Ground the mark against the background.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.32))
    ctx.beginPath()
    ctx.addPath(mark)
    ctx.setFillColor(rgb(0, 0, 0, 0.9))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.beginPath()
    ctx.addPath(mark)
    ctx.clip()
    let box = mark.boundingBoxOfPath
    ctx.drawLinearGradient(
        gradient(palette.mark),
        start: CGPoint(x: box.midX, y: box.maxY),
        end: CGPoint(x: box.midX, y: box.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Entry point

let args = CommandLine.arguments
let variant = args.count > 1 ? args[1] : "bronze"
let output = args.count > 2 ? args[2] : "icon.png"

guard let palette = palettes[variant] else {
    FileHandle.standardError.write("unknown variant \(variant)\n".data(using: .utf8)!)
    exit(1)
}

func png(_ image: CGImage, size: Int) -> Data? {
    guard size != Int(S) else {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: S, height: S)
        return rep.representation(using: .png, properties: [:])
    }
    // Downsample from the 1024 master so every size shares identical geometry
    // and gets a properly filtered edge.
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: scaled)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

if output.hasSuffix(".iconset") {
    try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let detailed = render(palette: palette, simplify: false)
    let simple   = render(palette: palette, simplify: true)

    // name → (pixels, whether the hairline survives at that size)
    let entries: [(String, Int, Bool)] = [
        ("icon_16x16",      16,   false), ("icon_16x16@2x",   32,   false),
        ("icon_32x32",      32,   false), ("icon_32x32@2x",   64,   false),
        ("icon_128x128",    128,  true),  ("icon_128x128@2x", 256,  true),
        ("icon_256x256",    256,  true),  ("icon_256x256@2x", 512,  true),
        ("icon_512x512",    512,  true),  ("icon_512x512@2x", 1024, true),
    ]
    for (name, px, detail) in entries {
        guard let data = png(detail ? detailed : simple, size: px) else { exit(1) }
        try data.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
    }
    print("wrote \(output) (\(entries.count) images)")
} else {
    guard let data = png(render(palette: palette), size: Int(S)) else { exit(1) }
    try data.write(to: URL(fileURLWithPath: output))
    print("wrote \(output)")
}
