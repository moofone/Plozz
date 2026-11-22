import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One TV network from TMDB's keyless daily ID export.
public struct TMDbNetworkEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// The list of TMDB TV networks, kept on disk and searched locally.
///
/// The list comes from TMDB's public `tv_network_ids_MM_DD_YYYY.json.gz` export, which
/// needs no API key. It is stored in Application Support (not Caches) so the system
/// never purges it, refreshed at most every ``refreshInterval`` and on demand when a
/// search runs against an older copy. A failed refresh keeps the last good copy.
public actor TMDbNetworkDirectory {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    public enum Refresh: Equatable, Sendable {
        /// The stored list is recent enough; nothing was fetched.
        case current
        case refreshed
        /// Nothing usable was downloaded; any stored list is unchanged.
        case failed
    }

    /// The list is refreshed when it is older than this.
    public static let refreshInterval: TimeInterval = 30 * 24 * 60 * 60
    /// An export is published daily; today's may not exist yet, so earlier days are tried.
    public static let lookbackDays = 7
    static let version = 1
    static let maximumCompressedBytes = 8 * 1_024 * 1_024
    static let maximumExpandedBytes = 32 * 1_024 * 1_024

    private struct Document: Codable {
        let version: Int
        let exportDate: Date
        let refreshedAt: Date
        let networks: [TMDbNetworkEntry]
    }

    private let fileURL: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var document: Document?
    private var loaded = false
    private var refreshTask: Task<Refresh, Never>?

    public init(
        fileURL: URL,
        fetch: @escaping Fetch = TMDbNetworkDirectory.fetchExport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.fetch = fetch
        self.now = now
    }

    /// `Application Support/Plozz/TMDbNetworks/directory.json`.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Plozz", isDirectory: true)
            .appendingPathComponent("TMDbNetworks", isDirectory: true)
            .appendingPathComponent("directory.json")
    }

    /// When the stored list was last downloaded; `nil` when there is none.
    public func refreshedAt() -> Date? {
        loadIfNeeded()
        return document?.refreshedAt
    }

    /// The date of the export the stored list came from.
    public func exportDate() -> Date? {
        loadIfNeeded()
        return document?.exportDate
    }

    public func networks() -> [TMDbNetworkEntry] {
        loadIfNeeded()
        return document?.networks ?? []
    }

    public func isStale() -> Bool {
        loadIfNeeded()
        guard let document else { return true }
        return now().timeIntervalSince(document.refreshedAt) >= Self.refreshInterval
    }

    /// Downloads a fresh list when there is none or the stored one is older than
    /// ``refreshInterval``. `force` skips that check.
    @discardableResult
    public func refreshIfNeeded(force: Bool = false) async -> Refresh {
        loadIfNeeded()
        if let refreshTask { return await refreshTask.value }
        guard force || isStale() else { return .current }
        let task = Task { await self.download() }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Networks whose name contains every word of `query`, best first. Runs a refresh
    /// first when the stored list is older than ``refreshInterval``.
    public func search(_ query: String, limit: Int = 30, refreshingStaleList: Bool = true) async -> [TMDbNetworkEntry] {
        loadIfNeeded()
        if refreshingStaleList, isStale() { await refreshIfNeeded() }
        return Self.rank(networks(), matching: query, limit: limit)
    }

    static func rank(_ networks: [TMDbNetworkEntry], matching query: String, limit: Int) -> [TMDbNetworkEntry] {
        let words = Self.searchWords(query)
        guard !words.isEmpty, limit > 0 else { return [] }
        let joined = words.joined(separator: " ")
        var scored: [(score: Int, entry: TMDbNetworkEntry)] = []
        for entry in networks {
            let name = Self.searchWords(entry.name).joined(separator: " ")
            guard words.allSatisfy({ name.contains($0) }) else { continue }
            let score = name == joined ? 0 : name.hasPrefix(joined) ? 1 : 2
            scored.append((score, entry))
        }
        scored.sort {
            ($0.score, $0.entry.name.count, $0.entry.name, $0.entry.id)
                < ($1.score, $1.entry.name.count, $1.entry.name, $1.entry.id)
        }
        return scored.prefix(limit).map(\.entry)
    }

    private static func searchWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: Download

    private func download() async -> Refresh {
        let today = now()
        for offset in 0...Self.lookbackDays {
            guard !Task.isCancelled else { return .failed }
            let day = today.addingTimeInterval(-Double(offset) * 86_400)
            guard let url = Self.exportURL(for: day) else { continue }
            let data: Data
            do {
                data = try await fetch(url)
            } catch MetadataDiscoveryHTTPError.status(let code, _) where code == 403 || code == 404 {
                continue
            } catch {
                return .failed
            }
            guard let networks = Self.parse(compressed: data), !networks.isEmpty else { continue }
            let updated = Document(
                version: Self.version, exportDate: Self.utcMidnight(day), refreshedAt: today, networks: networks
            )
            guard write(updated) else { return .failed }
            document = updated
            return .refreshed
        }
        return .failed
    }

    static func exportURL(for date: Date) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let stamp = String(format: "%02d_%02d_%04d", month, day, year)
        return URL(string: "https://files.tmdb.org/p/exports/tv_network_ids_\(stamp).json.gz")
    }

    private static func utcMidnight(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
    }

    /// The gzip'd export is one JSON object (`{"id":…,"name":"…"}`) per line.
    static func parse(compressed: Data) -> [TMDbNetworkEntry]? {
        guard compressed.count <= maximumCompressedBytes,
              let expanded = GzipDecoder.inflate(compressed, maximumBytes: maximumExpandedBytes) else { return nil }
        let decoder = JSONDecoder()
        var seen = Set<Int>()
        var networks: [TMDbNetworkEntry] = []
        for line in expanded.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(TMDbNetworkEntry.self, from: Data(line)),
                  !entry.name.isEmpty, seen.insert(entry.id).inserted else { continue }
            networks.append(entry)
        }
        return networks
    }

    // MARK: Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Document.self, from: data),
              stored.version == Self.version else { return }
        document = stored
    }

    private func write(_ document: Document) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(document).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The production transport: one GET on the shared metadata session.
    public static let fetchExport: Fetch = { url in
        var request = URLRequest(url: url)
        request.setValue(MetadataHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await MetadataHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataDiscoveryHTTPError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw MetadataDiscoveryHTTPError.status(http.statusCode, retryAfter: nil)
        }
        return data
    }
}
