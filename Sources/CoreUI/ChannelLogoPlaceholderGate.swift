import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Decides whether a downloaded provider logo is really a placeholder: a national flag, or one image
/// reused by channels of three or more different brands. Decisions are permanent; they are kept
/// with the image's fingerprint so each image is judged once.
///
/// Never used for a logo the user chose or one matched automatically.
public actor ChannelLogoPlaceholderGate {
    public static let minimumBrandKeys = 3
    /// Interior aHash bits that may differ from a flag reference (out of 36). Kept tight: a boxed logo with a
    /// centred mark hashes much like a tricolour.
    static let flagDistance = 2
    static let flagAspect = 1.2...2.2
    static let flagCoverage = 0.9

    public static let shared = ChannelLogoPlaceholderGate(
        indexURL: LiveTVLogoImageStore.defaultDirectory().appendingPathComponent("placeholder-index.json"),
        data: { await LiveTVLogoImageStore.shared.data(for: $0) }
    )

    private struct Fingerprint: Codable {
        var contentHash: String
        var isFlag: Bool
    }

    private struct Index: Codable {
        var version = 1
        var fingerprints: [String: Fingerprint] = [:]
        /// Brand keys seen with each image content, kept to the limit.
        var brands: [String: [String]] = [:]
    }

    private let indexURL: URL
    private let data: @Sendable (URL) async -> Data?
    private var index: Index
    private var savePending = false

    /// URLs already judged a placeholder, readable without awaiting so a recycled row never flashes one.
    private static let rejected = RejectedSet()

    public init(indexURL: URL, data: @escaping @Sendable (URL) async -> Data?) {
        self.indexURL = indexURL
        self.data = data
        if let stored = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode(Index.self, from: stored),
           decoded.version == 1 {
            index = decoded
        } else {
            index = Index()
        }
        for (key, fingerprint) in index.fingerprints where fingerprint.isFlag || (index.brands[fingerprint.contentHash]?.count ?? 0) >= Self.minimumBrandKeys {
            Self.rejected.insert(key)
        }
    }

    /// True when `url` was already judged a placeholder.
    public nonisolated static func isKnownPlaceholder(_ url: URL) -> Bool { rejected.contains(Self.key(url)) }

    /// Whether the image at `url`, drawn for a channel whose brand is `brandKey`, is a placeholder.
    /// A logo that cannot be loaded is not judged here; the caller's own failure path handles it.
    public func rejects(url: URL, brandKey: String) async -> Bool {
        let key = Self.key(url)
        var fingerprint = index.fingerprints[key]
        if fingerprint == nil {
            guard let bytes = await data(url) else { return false }
            let computed = Fingerprint(
                contentHash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                isFlag: Self.isFlag(bytes)
            )
            index.fingerprints[key] = computed
            fingerprint = computed
            scheduleSave()
        }
        guard let fingerprint else { return false }
        if !brandKey.isEmpty {
            var seen = index.brands[fingerprint.contentHash, default: []]
            if seen.count < Self.minimumBrandKeys, !seen.contains(brandKey) {
                seen.append(brandKey)
                index.brands[fingerprint.contentHash] = seen
                scheduleSave()
            }
        }
        let shared = (index.brands[fingerprint.contentHash]?.count ?? 0) >= Self.minimumBrandKeys
        let verdict = fingerprint.isFlag || shared
        if verdict { Self.rejected.insert(key) }
        return verdict
    }

    // MARK: Flags

    static func isFlag(_ bytes: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary),
              let fingerprint = LogoPerceptualHash.fingerprint(of: image) else { return false }
        return isFlag(fingerprint)
    }

    static func isFlag(_ fingerprint: LogoPerceptualHash.Fingerprint) -> Bool {
        guard fingerprint.coverage >= flagCoverage, flagAspect.contains(fingerprint.aspect) else { return false }
        return LogoFlagHashes.table.contains {
            LogoPerceptualHash.distance($0.hash, fingerprint.hash) <= flagDistance
        }
    }

    // MARK: Storage

    private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.save()
        }
    }

    private func save() {
        savePending = false
        do {
            try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        } catch {
            return
        }
    }

    private final class RejectedSet: @unchecked Sendable {
        private let lock = NSLock()
        private var keys = Set<String>()
        func insert(_ key: String) { lock.withLock { _ = keys.insert(key) } }
        func contains(_ key: String) -> Bool { lock.withLock { keys.contains(key) } }
    }
}
