import CoreGraphics
import CoreModels
import Foundation
import ImageIO

/// Decides whether a logo image is monochrome (black, white or grey) so a colour logo can be preferred over it.
///
/// One bounded download per image (10 s, 8 MB), decoded at a reduced size. Anything that cannot be decoded (an unrendered SVG) is
/// unknown, never monochrome.
public enum LiveTVLogoColourMeasurer {
    static let maximumBytes = 8_000_000
    static let sampleSide = 96

    public static func isMonochrome(at url: URL) async -> Bool? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count <= maximumBytes else { return nil }
        return isMonochrome(data: data)
    }

    static func isMonochrome(data: Data) -> Bool? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: sampleSide
              ] as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var index = 0
        while index < bytes.count {
            let alpha = Int(bytes[index + 3])
            if alpha > 0, alpha < 255 {
                for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha)) }
            }
            index += 4
        }
        return LogoColourProfile(straightRGBA: bytes)?.isMonochrome
    }
}
