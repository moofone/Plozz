import CoreGraphics
import Foundation

/// An 8×8 average hash of a logo, taken after its transparent margin is trimmed. Tolerant of scale,
/// compression and small colour shifts; used only to recognise national-flag placeholder images.
enum LogoPerceptualHash {
    /// Alpha above which a pixel counts as part of the picture when trimming.
    static let visibleAlpha = 32
    static let sampleSide = 256
    /// Share of each side ignored after trimming, so an emoji flag's soft edge or a compressed border
    /// does not move the hash.
    static let edgeInset = 0.08

    /// The hash plus what is needed to tell a flag (a full, wide, opaque rectangle) from a logo on transparency.
    struct Fingerprint: Equatable {
        let hash: UInt64
        /// Share of the trimmed area that is opaque; 1 for a JPEG or a flattened flag.
        let coverage: Double
        /// Width over height of the trimmed area.
        let aspect: Double
    }

    /// 64 bits, one per cell of the 8×8 grey image: set when the cell is brighter than the mean.
    static func average(of image: CGImage) -> UInt64? { fingerprint(of: image)?.hash }

    static func fingerprint(of image: CGImage) -> Fingerprint? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(sampleSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let small: CGImage? = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        guard let small else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1, visible = 0
        for y in 0..<height {
            for x in 0..<width where Int(bytes[(y * width + x) * 4 + 3]) > visibleAlpha {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                visible += 1
            }
        }
        guard maxX >= minX, maxY >= minY,
              let trimmed = small.cropping(to: Self.inset(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)))
        else { return nil }
        var grey = [UInt8](repeating: 0, count: 64)
        let drawn: Bool = grey.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            context.interpolationQuality = .high
            context.draw(trimmed, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard drawn else { return nil }
        let mean = grey.reduce(0) { $0 + Int($1) } / 64
        var hash: UInt64 = 0
        for (index, value) in grey.enumerated() where Int(value) > mean { hash |= 1 << UInt64(index) }
        let boxWidth = Double(maxX - minX + 1), boxHeight = Double(maxY - minY + 1)
        return Fingerprint(hash: hash, coverage: Double(visible) / (boxWidth * boxHeight), aspect: boxWidth / boxHeight)
    }

    /// Bits of the 6×6 interior; the outer ring of cells is where soft edges and corners differ.
    static let interiorMask: UInt64 = {
        var mask: UInt64 = 0
        for row in 1...6 { for column in 1...6 { mask |= 1 << UInt64(row * 8 + column) } }
        return mask
    }()

    private static func inset(_ rect: CGRect) -> CGRect {
        let dx = (rect.width * edgeInset).rounded(), dy = (rect.height * edgeInset).rounded()
        guard rect.width > dx * 2 + 2, rect.height > dy * 2 + 2 else { return rect }
        return rect.insetBy(dx: dx, dy: dy)
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { ((a ^ b) & interiorMask).nonzeroBitCount }
}
