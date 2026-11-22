import Foundation

/// How colourful a logo image is, from straight-alpha RGBA pixels. Shared by the Live TV logo source choice (prefer a colour logo
/// over a black or white one) and the guide's legibility treatment (only colourless dark ink is redrawn light).
public struct LogoColourProfile: Equatable, Sendable {
    /// Only pixels above this alpha (0–255) are counted.
    public static let opaqueAlpha = 128
    /// A pixel whose strongest and weakest channels differ by more than this (0–255) is coloured.
    public static let colourChroma = 40.0
    /// An image where fewer than this share of counted pixels are coloured is monochrome (black, white or grey).
    public static let monochromeShare = 0.05
    /// Every Nth pixel is sampled.
    public static let samplePixelStride = 4

    /// Mean Rec. 709 luminance (0–255) of the counted pixels.
    public let meanLuminance: Double
    /// Share (0–1) of counted pixels that are coloured.
    public let colouredShare: Double

    public var isMonochrome: Bool { colouredShare < Self.monochromeShare }

    /// `nil` when no sampled pixel is opaque enough to count.
    public init?(straightRGBA bytes: [UInt8]) {
        var luminance = 0.0
        var coloured = 0
        var count = 0
        var index = 0
        let step = Self.samplePixelStride * 4
        while index + 3 < bytes.count {
            if Int(bytes[index + 3]) > Self.opaqueAlpha {
                let red = Double(bytes[index]), green = Double(bytes[index + 1]), blue = Double(bytes[index + 2])
                luminance += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                if max(red, green, blue) - min(red, green, blue) > Self.colourChroma { coloured += 1 }
                count += 1
            }
            index += step
        }
        guard count > 0 else { return nil }
        meanLuminance = luminance / Double(count)
        colouredShare = Double(coloured) / Double(count)
    }
}
