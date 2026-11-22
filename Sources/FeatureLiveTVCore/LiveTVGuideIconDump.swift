#if DEBUG
import Foundation
import ImageIO

/// Debug check for provider XMLTV channel icons, off unless launched with
/// `-PlozzDumpGuideIcons 1`. After a guide publication it writes
/// `<tmp>/guide-icons/summary.json` (hosts only, never full URLs) and, for up to
/// `sampleLimit` matched CA|/US| channels, downloads the guide and playlist logos side by side.
enum LiveTVGuideIconDump {
    static let launchArgument = "PlozzDumpGuideIcons"
    static let sampleLimit = 20
    private static let maximumImageBytes = 5 * 1_024 * 1_024
    @MainActor private static var lastSignature: Int?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: launchArgument) }

    struct Summary: Codable, Equatable {
        var guideChannelCount: Int
        var guideChannelsWithIcon: Int
        var iconHostCounts: [String: Int]
        var matchedChannelsGainingIcon: Int
        /// Guide icon URL equals the playlist logo URL (no download needed to know).
        var gainedIconsSameURLAsPlaylistLogo: Int
        var samples: [Sample]

        struct Sample: Codable, Equatable {
            var channel: String
            var guide: ImageInfo?
            var playlist: ImageInfo?
            var bytesIdentical: Bool?
        }

        struct ImageInfo: Codable, Equatable {
            var file: String
            var pixelWidth: Int?
            var pixelHeight: Int?
            var format: String?
            var hasAlpha: Bool?
        }
    }

    @MainActor
    static func record(
        guides: [LiveTVGuideImport], playlistChannels: [LiveTVPrototypeChannel],
        publishedChannels: [LiveTVPrototypeChannel]
    ) {
        guard isEnabled else { return }
        let original = Dictionary(playlistChannels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let gained = publishedChannels.filter { $0.guideLogoURL != nil && original[$0.id]?.guideLogoURL == nil }
        var hosts: [String: Int] = [:]
        for url in guides.flatMap({ $0.guideIcons.values }) { hosts[url.host ?? "(none)", default: 0] += 1 }
        let base = Summary(
            guideChannelCount: guides.reduce(0) { $0 + $1.guideChannelCount },
            guideChannelsWithIcon: guides.reduce(0) { $0 + $1.guideIcons.count },
            iconHostCounts: hosts,
            matchedChannelsGainingIcon: gained.count,
            gainedIconsSameURLAsPlaylistLogo: gained.filter { $0.guideLogoURL == $0.logoURL }.count,
            samples: []
        )
        var hasher = Hasher()
        hasher.combine(base.guideChannelCount)
        hasher.combine(base.guideChannelsWithIcon)
        hasher.combine(base.matchedChannelsGainingIcon)
        let signature = hasher.finalize()
        guard signature != lastSignature else { return }
        lastSignature = signature
        let samples = gained.filter { channel in
            guard channel.logoURL != nil else { return false }
            let name = channel.name.trimmingCharacters(in: .whitespaces).uppercased()
            let groups = (channel.groups ?? [channel.category]).map { $0.uppercased() }
            return ["CA|", "US|"].contains { prefix in
                name.hasPrefix(prefix) || groups.contains { $0.hasPrefix(prefix) }
            }
        }.prefix(sampleLimit).map { ($0.name, $0.guideLogoURL, $0.logoURL) }
        Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guide-icons", isDirectory: true)
            do {
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var rows: [Summary.Sample] = []
                for (index, sample) in samples.enumerated() {
                    let base = String(format: "%02d-", index + 1) + safeFileName(sample.0)
                    async let guide = fetch(sample.1, name: base + ".guide", into: directory)
                    async let playlist = fetch(sample.2, name: base + ".playlist", into: directory)
                    let (guideResult, playlistResult) = await (guide, playlist)
                    rows.append(.init(
                        channel: sample.0, guide: guideResult?.info, playlist: playlistResult?.info,
                        bytesIdentical: guideResult.flatMap { guide in
                            playlistResult.map { $0.data == guide.data }
                        }
                    ))
                }
                var summary = base
                summary.samples = rows
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(summary).write(
                    to: directory.appendingPathComponent("summary.json"), options: .atomic
                )
            } catch {
                // Debug aid only: a failed dump must never affect the guide.
            }
        }
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(cleaned.prefix(48))
    }

    private static func fetch(
        _ url: URL?, name: String, into directory: URL
    ) async -> (info: Summary.ImageInfo, data: Data)? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count <= maximumImageBytes else { return nil }
        var info = Summary.ImageInfo(file: "")
        var fileExtension = "bin"
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            if let type = CGImageSourceGetType(source) as String? {
                info.format = type
                fileExtension = type.split(separator: ".").last.map(String.init) ?? "bin"
                if fileExtension == "jpeg" { fileExtension = "jpg" }
            }
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                info.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
                info.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
                info.hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool
            }
        }
        info.file = "\(name).\(fileExtension)"
        guard (try? data.write(to: directory.appendingPathComponent(info.file))) != nil else { return nil }
        return (info, data)
    }
}
#endif
