import Foundation
import ImageIO

/// Measures a guide (XMLTV) icon's pixel size, so only a crisp one is drawn.
///
/// One bounded download per icon (10 s, 4 MB), decoded for its size only. An SVG is a vector.
public enum LiveTVGuideIconMeasurer {
    static let maximumBytes = 4_000_000

    public static func measure(_ url: URL) async -> LiveTVLogoSize? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count <= maximumBytes else { return nil }
        return size(of: data, mimeType: response.mimeType, pathExtension: url.pathExtension)
    }

    static func size(of data: Data, mimeType: String?, pathExtension: String) -> LiveTVLogoSize? {
        if mimeType == "image/svg+xml" || pathExtension.lowercased() == "svg" { return .vector }
        if data.prefix(512).range(of: Data("<svg".utf8)) != nil { return .vector }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return .raster(width: width, height: height)
    }
}
