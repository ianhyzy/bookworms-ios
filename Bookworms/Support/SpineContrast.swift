import Foundation

/// APCA (SAPC-4 / 0.1.9 constants) lightness contrast and an OKLab lightness nudge that moves a
/// failing pair to the target without discarding the cover's tint.
enum SpineContrast {
    /// Signed Lc: positive for dark text on light, negative for light text on dark.
    static func apca(text: ColorValue, background: ColorValue) -> Double {
        func y(_ c: ColorValue) -> Double {
            func lin(_ v: Int) -> Double { pow(Double(v) / 255, 2.4) }
            let value = 0.2126729 * lin(c.red) + 0.7151522 * lin(c.green) + 0.0721750 * lin(c.blue)
            return value < 0.022 ? value + pow(0.022 - value, 1.414) : value
        }
        let yt = y(text)
        let yb = y(background)
        if yb > yt {
            let s = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
            return s < 0.1 ? 0 : (s - 0.027) * 100
        } else {
            let s = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
            return s > -0.1 ? 0 : (s + 0.027) * 100
        }
    }

    // OKLab (Björn Ottosson), sRGB in and out with gamut clamping.
    struct Lab {
        var l: Double
        var a: Double
        var b: Double
    }
    static func lab(_ c: ColorValue) -> Lab {
        func lin(_ v: Int) -> Double {
            let x = Double(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.red)
        let g = lin(c.green)
        let b = lin(c.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(
            l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
    static func color(_ lab: Lab) -> ColorValue {
        let l = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let b = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        func srgb(_ x: Double) -> Int {
            let c = max(0, min(1, x))
            let v = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            return Int((v * 255).rounded())
        }
        return ColorValue(red: srgb(r), green: srgb(g), blue: srgb(b))
    }

    /// Returns a pair whose absolute APCA contrast reaches `minimumLc` when possible.
    ///
    /// The ink keeps its proposed polarity: dark ink moves toward black and light ink toward
    /// white. If the ink reaches that extreme without passing, the cloth moves away from it,
    /// lightening under dark ink and darkening under light ink. Chroma eases toward zero near the
    /// lightness extremes so the result stays in gamut. If neither side passes, the result is the
    /// extreme ink on the original cloth.
    static func resolve(foreground: ColorValue, background: ColorValue, minimumLc: Double)
        -> (foreground: ColorValue, background: ColorValue)
    {
        let before = apca(text: foreground, background: background)
        guard abs(before) < minimumLc else { return (foreground, background) }
        // APCA reports 0 for near-equal luminance; then the cloth's lightness picks the polarity.
        let darkInk = before == 0 ? lab(background).l >= 0.5 : before > 0
        func stepped(_ start: Lab, toward target: Double, passes: (ColorValue) -> Bool)
            -> ColorValue?
        {
            var current = start
            for _ in 0..<24 {
                current.l += (target - current.l) * 0.18
                let chroma = max(0.15, 1 - abs(current.l - 0.5) * 1.6)
                let candidate = color(Lab(l: current.l, a: start.a * chroma, b: start.b * chroma))
                if passes(candidate) { return candidate }
            }
            return nil
        }
        if let ink = stepped(
            lab(foreground), toward: darkInk ? 0 : 1,
            passes: { abs(apca(text: $0, background: background)) >= minimumLc })
        {
            return (ink, background)
        }
        let extreme =
            darkInk
            ? ColorValue(red: 0, green: 0, blue: 0) : ColorValue(red: 255, green: 255, blue: 255)
        if let cloth = stepped(
            lab(background), toward: darkInk ? 1 : 0,
            passes: { abs(apca(text: extreme, background: $0)) >= minimumLc })
        {
            return (extreme, cloth)
        }
        return (extreme, background)
    }
}
