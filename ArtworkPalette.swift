import AppKit
import SwiftUI

/// A colour lifted from the album artwork.
struct PaletteColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// Pulls a small palette out of the cover art so the app can take on the colour
/// of whatever is playing.
///
/// Main-actor rather than an actor: the extraction draws the image into a bitmap,
/// and AppKit drawing belongs on the main thread. The work is a 32×32 downsample,
/// so it costs almost nothing; the network fetch suspends as normal.
@MainActor
final class PaletteProvider {

    static let shared = PaletteProvider()

    private var cache: [String: [PaletteColor]] = [:]

    func palette(for track: SpotifyTrack) async -> [PaletteColor] {
        let key = track.trackID
        if let hit = cache[key] { return hit }
        guard let url = track.artworkURL else { return [] }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return [] }

        let colours = Self.extract(from: image)
        cache[key] = colours
        return colours
    }

    // MARK: - Extraction

    private static func extract(from image: NSImage) -> [PaletteColor] {
        let side = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return [] }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // Strict first: vivid pixels give the truest read of a colourful cover.
        var found = rank(rep, side: side, minBrightness: 0.14, minSaturation: 0.16)

        // Dark or near-monochrome covers fail that pass almost entirely — Discovery
        // left 13 usable pixels out of 1024. Relax and let `vivid` lift what's there
        // rather than reporting a palette built from noise.
        if found.count < 2 {
            found = rank(rep, side: side, minBrightness: 0.04, minSaturation: 0.04)
        }
        guard let dominant = found.first else { return [] }

        // A single-hue cover still needs three fields, or the background is flat.
        while found.count < 3 {
            found.append(shifted(dominant,
                                 byHue: 0.07 * Double(found.count),
                                 brightness: 1 - 0.12 * Double(found.count)))
        }
        return Array(found.prefix(3))
    }

    /// Buckets the pixels passing the thresholds, ranked by how much of the cover
    /// they cover, keeping only hues far enough apart to look like separate fields.
    private static func rank(_ rep: NSBitmapImageRep, side: Int,
                             minBrightness: Double, minSaturation: Double) -> [PaletteColor] {
        var buckets: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]

        for y in 0..<side {
            for x in 0..<side {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Double(pixel.redComponent)
                let g = Double(pixel.greenComponent)
                let b = Double(pixel.blueComponent)

                let high = max(r, g, b), low = min(r, g, b)
                let saturation = high > 0 ? (high - low) / high : 0
                guard high > minBrightness, saturation > minSaturation else { continue }

                let key = (Int(r * 7) << 6) | (Int(g * 7) << 3) | Int(b * 7)
                var entry = buckets[key] ?? (0, 0, 0, 0)
                entry.count += 1
                entry.r += r; entry.g += g; entry.b += b
                buckets[key] = entry
            }
        }

        // Ignore buckets too small to represent the cover rather than JPEG noise.
        let ranked = buckets.values
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
            .map { vivid($0.r / Double($0.count), $0.g / Double($0.count), $0.b / Double($0.count)) }

        var chosen: [PaletteColor] = []
        for candidate in ranked where chosen.allSatisfy({ hueDistance($0, candidate) > 0.06 }) {
            chosen.append(candidate)
            if chosen.count == 3 { break }
        }
        return chosen
    }

    /// Derives a companion colour from the dominant one, for covers that only
    /// really contain a single hue.
    private static func shifted(_ base: PaletteColor, byHue delta: Double,
                                brightness scale: Double) -> PaletteColor {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        NSColor(srgbRed: base.red, green: base.green, blue: base.blue, alpha: 1)
            .getHue(&h, saturation: &s, brightness: &v, alpha: &a)

        let rotated = NSColor(hue: CGFloat((Double(h) + delta).truncatingRemainder(dividingBy: 1)),
                              saturation: s,
                              brightness: min(1, max(0.35, v * CGFloat(scale))),
                              alpha: 1)
        guard let srgb = rotated.usingColorSpace(.sRGB) else { return base }
        return PaletteColor(red: Double(srgb.redComponent),
                            green: Double(srgb.greenComponent),
                            blue: Double(srgb.blueComponent))
    }

    /// Pushes the sample toward something that reads as a glow rather than a smudge.
    private static func vivid(_ r: Double, _ g: Double, _ b: Double) -> PaletteColor {
        let base = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &v, alpha: &a)

        let lifted = NSColor(hue: h,
                             saturation: min(1, s * 1.2 + 0.18),
                             brightness: min(1, max(0.62, v * 1.2)),
                             alpha: 1)
        guard let srgb = lifted.usingColorSpace(.sRGB) else {
            return PaletteColor(red: r, green: g, blue: b)
        }
        return PaletteColor(red: Double(srgb.redComponent),
                            green: Double(srgb.greenComponent),
                            blue: Double(srgb.blueComponent))
    }

    private static func hueDistance(_ lhs: PaletteColor, _ rhs: PaletteColor) -> Double {
        func hue(_ c: PaletteColor) -> CGFloat {
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
                .getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            return h
        }
        let raw = abs(Double(hue(lhs) - hue(rhs)))
        return min(raw, 1 - raw)   // hue wraps
    }
}

extension Array where Element == PaletteColor {
    /// Dominant cover colour, falling back to the house amber when there's no
    /// artwork or nothing usable came out of it.
    var accent: Color { first?.color ?? Theme.sung }

    /// A second colour for gradients; repeats the accent on single-hue covers.
    var secondary: Color { count > 1 ? self[1].color : accent }

    /// How hard the accent may tint a panel, scaled down for bright covers.
    ///
    /// A flat opacity looks fine on a deep blue sleeve and destroys the dim
    /// secondary text on a yellow one — measured, a bright accent at 0.30 drops
    /// `Theme.upcoming` to 1.5:1, against 3.5:1 on the untinted panel. Scaling by
    /// luminance holds every cover near 3:1 instead.
    var tintStrength: Double {
        guard let base = first else { return 0 }
        let luminance = 0.2126 * base.red + 0.7152 * base.green + 0.0722 * base.blue
        return 0.20 * (1 - Swift.min(0.8, luminance))
    }
}
