import AppKit
import Foundation

nonisolated struct ArtworkRGB: Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

nonisolated enum ArtworkAccent {
    static let fallback = ArtworkRGB(
        red: 0,
        green: 129.0 / 255.0,
        blue: 251.0 / 255.0
    )

    static func dominantRGB(from data: Data?) -> ArtworkRGB {
        guard let data,
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            return fallback
        }

        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var weightTotal = 0.0
        let sampleWidth = min(bitmap.pixelsWide, 24)
        let sampleHeight = min(bitmap.pixelsHigh, 24)

        for sampleY in 0..<sampleHeight {
            for sampleX in 0..<sampleWidth {
                let x = sampleX * bitmap.pixelsWide / sampleWidth
                let y = sampleY * bitmap.pixelsHigh / sampleHeight
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }

                let red = Double(color.redComponent)
                let green = Double(color.greenComponent)
                let blue = Double(color.blueComponent)
                let brightness = (red + green + blue) / 3
                let saturation = max(red, green, blue) - min(red, green, blue)
                guard brightness > 0.06, brightness < 0.96 else { continue }

                let weight = 1 + saturation * 2
                redTotal += red * weight
                greenTotal += green * weight
                blueTotal += blue * weight
                weightTotal += weight
            }
        }

        guard weightTotal > 0 else { return fallback }
        return ArtworkRGB(
            red: redTotal / weightTotal,
            green: greenTotal / weightTotal,
            blue: blueTotal / weightTotal
        )
    }
}
