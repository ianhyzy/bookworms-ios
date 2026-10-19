// Bakes the paper ground's dither tile (`PaperDither`), which `PaperGround` draws. Run it from
// the repository root with `xcrun swift script/paper-dither.swift` after changing a value
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

writeJPEG(grain(), to: assets.appending(path: "WallGrain.imageset/grain.jpg"))
for scale in [2, 3] {
    writePNG(dither(), to: assets.appending(path: "PaperDither.imageset/dither@\(scale)x.png"))
}
