import CryptoKit
import Foundation
import ImageIO

/// Permanent on-disk storage for Live TV channel logo bytes.
///
/// A logo is downloaded once and then read from here, whether it came from TMDB, a URL
/// the user entered or the provider. Files live in Application Support, which the
/// system does not purge, named by a SHA-256 of the URL. Nothing is removed until the
/// total passes ``capacityBytes``; then the least recently used files go first. Requests
/// for one URL that overlap share a single download.
public actor LiveTVLogoImageStore {
    public typealias Download = @Sendable (URL) async throws -> (Data, URLResponse)

    public static let defaultCapacityBytes = 200 * 1_024 * 1_024
    /// A single logo larger than this is not stored.
    public static let maximumFileBytes = 12 * 1_024 * 1_024

    /// The shared store, downloading through the artwork session.
    public static let shared = LiveTVLogoImageStore(
        directory: LiveTVLogoImageStore.defaultDirectory(), capacityBytes: defaultCapacityBytes
    )

    private let directory: URL
    private let capacityBytes: Int
    private let download: Download
    private let now: @Sendable () -> Date
    private var inFlight: [String: Task<Data?, Never>] = [:]
    /// Bytes of stored logos, read from the directory once (on the first store) and then kept current, so storing a file never
    /// lists the directory unless the total passes capacity.
    private var totalBytes: Int?
    /// How many times the whole directory was listed and statted; the O(N) bound is tested through this.
    public private(set) var directoryScanCount = 0

    public init(
        directory: URL,
        capacityBytes: Int = LiveTVLogoImageStore.defaultCapacityBytes,
        download: @escaping Download = { try await ArtworkSession.data(from: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.capacityBytes = capacityBytes
        self.download = download
        self.now = now
    }

    /// `Application Support/Plozz/LiveTVLogoImages`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Plozz", isDirectory: true)
            .appendingPathComponent("LiveTVLogoImages", isDirectory: true)
    }

    /// The logo's bytes from disk, or from one download that is then kept.
    /// `nil` when the download fails or is not an image; nothing is stored then.
    public func data(for url: URL) async -> Data? {
        let name = Self.fileName(for: url)
        let file = directory.appendingPathComponent(name)
        if let stored = try? Data(contentsOf: file) {
            touch(file)
            return stored
        }
        if let running = inFlight[name] { return await running.value }
        let download = download
        let persists = Self.isStorable(url)
        let task = Task<Data?, Never> {
            guard let (data, response) = try? await download(url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            guard Self.isImage(data) else { return nil }
            return data
        }
        inFlight[name] = task
        let result = await task.value
        inFlight[name] = nil
        if let result, persists, result.count <= Self.maximumFileBytes { store(result, at: file) }
        return result
    }

    /// Total bytes of stored logos.
    public func storedBytes() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".logo"
    }

    /// Only plain web URLs are kept; app-internal authenticated references never reach the disk.
    private static func isStorable(_ url: URL) -> Bool {
        url.scheme == "https" || url.scheme == "http"
    }

    private static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    // MARK: Disk

    private struct Entry {
        let url: URL
        let size: Int
        let used: Date
    }

    private func entries() -> [Entry] {
        directoryScanCount += 1
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return [] }
        return urls.filter { $0.pathExtension == "logo" }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0, used: values.contentModificationDate ?? .distantPast)
        }
    }

    private func store(_ data: Data, at file: URL) {
        if totalBytes == nil { totalBytes = entries().reduce(0) { $0 + $1.size } }
        let replaced = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            touch(file)
        } catch {
            return
        }
        totalBytes = (totalBytes ?? 0) - replaced + data.count
        evictIfOverCapacity(keeping: file)
    }

    /// The modification date records when a file was last used.
    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
    }

    /// Lists the directory only when the running total passes capacity, then removes least recently used files down to 90% of
    /// capacity, so the next evictions are a tenth of capacity apart rather than one per stored file.
    private func evictIfOverCapacity(keeping file: URL) {
        guard let running = totalBytes, running > capacityBytes else { return }
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        let target = capacityBytes / 10 * 9
        all.sort { ($0.used, $0.url.lastPathComponent) < ($1.used, $1.url.lastPathComponent) }
        for entry in all where total > target && entry.url != file {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
        totalBytes = total
    }
}
