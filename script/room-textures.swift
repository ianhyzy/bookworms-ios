// Bakes the room's textures and stills: the walnut wall's grain (`WallGrain`) from `TableWood`,
// which `WalnutWall` draws; the paper ground's dither tile (`PaperDither`), which `PaperGround`
// draws; the soft shadow under paper props and covers (`SoftShadow`); and the empty desk under
// the lamp (`DeskStill`), which the Desk tab shows without books instead of its live scene. Run it
// from the repository root with `xcrun swift script/room-textures.swift` after changing a value
// below; the output is deterministic.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let assets = URL(filePath: "Bookworms/Assets.xcassets")

/// The side of the dither tile in pixels, at every scale.
let ditherSide = 128
/// The side of the grain tile in pixels. It draws at 1x, larger than the screen's pixels, since
/// the wall shows it only faintly.
let grainSide = 512
/// The grain's average color: the middle of the wall's gradient (`ShelfWallTop` to
/// `ShelfWallBottom`), so drawing it faintly over the wall leaves the wall's color as it was.
let grainMean: [Double] = [40, 29, 21]
/// How far the grain's lightness swings around its average, as a standard deviation in 8-bit
/// levels.
let grainSpread = 18.0

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Can't write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
}

/// Gray noise around mid-gray with a triangular distribution, from a fixed seed.
func dither() -> CGImage {
    var state: UInt64 = 0x5EED_B00C
    func next() -> Double {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
    var pixels = [UInt8](repeating: 0, count: ditherSide * ditherSide)
    for index in pixels.indices {
        pixels[index] = UInt8(((next() + next()) / 2 * 255).rounded())
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: ditherSide, height: ditherSide, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: ditherSide, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// The table's wood, downsampled, as lightness alone around `grainMean`, so it tints nothing.
func grain() -> CGImage {
    let source = CGImageSourceCreateWithURL(
        assets.appending(path: "TableWood.imageset/wood.jpg") as CFURL, nil)!
    let wood = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var gray = [UInt8](repeating: 0, count: grainSide * grainSide)
    let context = CGContext(
        data: &gray, width: grainSide, height: grainSide, bitsPerComponent: 8,
        bytesPerRow: grainSide, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.interpolationQuality = .high
    context.draw(wood, in: CGRect(x: 0, y: 0, width: grainSide, height: grainSide))
    let values = gray.map(Double.init)
    let mean = values.reduce(0, +) / Double(values.count)
    let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
        .squareRoot()
    var pixels = [UInt8](repeating: 0, count: grainSide * grainSide * 4)
    for (index, value) in values.enumerated() {
        let offset = (value - mean) / deviation * grainSpread
        for channel in 0..<3 {
            pixels[index * 4 + channel] = UInt8(
                max(0, min(255, (grainMean[channel] + offset).rounded())))
        }
        pixels[index * 4 + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: grainSide, height: grainSide, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: grainSide * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func writeJPEG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
}

/// The shadow image's side in points: a 48-point rectangle with 24 points of blur around it.
let shadowSide = 96

/// A soft black shadow around a 48-point rounded rectangle, at `scale` pixels per point. The
/// rectangle itself is drawn off the image, so only its shadow shows.
func softShadow(scale: Int) -> CGImage {
    let side = shadowSide * scale
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let unit = CGFloat(scale)
    context.setShadow(
        offset: CGSize(width: -CGFloat(side), height: 0), blur: 14 * unit,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    let rect = CGRect(
        x: 24 * unit + CGFloat(side), y: 24 * unit, width: 48 * unit, height: 48 * unit)
    context.addPath(
        CGPath(roundedRect: rect, cornerWidth: 4 * unit, cornerHeight: 4 * unit, transform: nil))
    context.fillPath()
    return context.makeImage()!
}

/// The still's size in pixels. It is marked 2x, so it draws 480 by 320 points at full size.
let stillWidth = 960
let stillHeight = 640
/// The table's lit color at the middle of the lamp's pool and at its edge, as the Desk scene
/// renders the wood under its 2,700 K lamp.
let deskLit: [Double] = [140, 72, 12]
let deskDim: [Double] = [88, 34, 2]
/// The wall's color halfway down the screen, which the still fades to at its edges, so it sits
/// on the Desk tab's plain wall without a seam: the middle of `ShelfWallTop` and
/// `ShelfWallBottom`, and of their High Contrast variants.
let deskWall: [Double] = [40, 29, 21]
let deskWallHigh: [Double] = [27, 20, 14]

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// The empty desk seen from above, as the Desk scene sees it: the table's wood, its grain running
/// up the screen, warm in the lamp's pool a little above the middle and darker toward the edges,
/// where it fades into `wall`.
func deskStill(wall: [Double]) -> CGImage {
    let source = CGImageSourceCreateWithURL(
        assets.appending(path: "TableWood.imageset/wood.jpg") as CFURL, nil)!
    let wood = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let tile = 640
    var gray = [UInt8](repeating: 0, count: tile * tile)
    let context = CGContext(
        data: &gray, width: tile, height: tile, bitsPerComponent: 8, bytesPerRow: tile,
        space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.interpolationQuality = .high
    context.draw(wood, in: CGRect(x: 0, y: 0, width: tile, height: tile))
    let values = gray.map(Double.init)
    let mean = values.reduce(0, +) / Double(values.count)
    let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
        .squareRoot()
    var pixels = [UInt8](repeating: 0, count: stillWidth * stillHeight * 4)
    for y in 0..<stillHeight {
        for x in 0..<stillWidth {
            let grain = (values[(y % tile) * tile + x % tile] - mean) / deviation
            let dx = (Double(x) + 0.5) / Double(stillWidth) * 2 - 1
            let dy = (Double(y) + 0.5) / Double(stillHeight) * 2 - 1
            let pool = (dx * dx + (dy + 0.1) * (dy + 0.1)).squareRoot()
            let light = 1 - smoothstep(0, 1.1, pool)
            // A rounded rectangle's distance, so the fade follows the still's edges.
            let edge = pow(pow(abs(dx), 4) + pow(abs(dy), 4), 0.25)
            let fade = smoothstep(0.62, 0.98, edge)
            for channel in 0..<3 {
                let lit = deskDim[channel] + (deskLit[channel] - deskDim[channel]) * light
                let wood = lit * (1 + 0.14 * grain)
                let value = wood + (wall[channel] - wood) * fade
                pixels[(y * stillWidth + x) * 4 + channel] = UInt8(
                    max(0, min(255, value.rounded())))
            }
            pixels[(y * stillWidth + x) * 4 + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: stillWidth, height: stillHeight, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: stillWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

writeJPEG(grain(), to: assets.appending(path: "WallGrain.imageset/grain.jpg"))
writeJPEG(deskStill(wall: deskWall), to: assets.appending(path: "DeskStill.imageset/desk.jpg"))
writeJPEG(
    deskStill(wall: deskWallHigh), to: assets.appending(path: "DeskStill.imageset/desk-high.jpg"))
for scale in [2, 3] {
    writePNG(
        softShadow(scale: scale),
        to: assets.appending(path: "SoftShadow.imageset/shadow@\(scale)x.png"))
}
for scale in [2, 3] {
    writePNG(dither(), to: assets.appending(path: "PaperDither.imageset/dither@\(scale)x.png"))
}
