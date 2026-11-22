import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One Wikidata item that has a logo on Wikimedia Commons.
public struct WikidataLogoEntry: Codable, Equatable, Hashable, Sendable {
    public let qid: String
    public let label: String
    public let altLabels: [String]
    /// The Commons file name, such as `CTV logo 2018.svg`.
    public let file: String

    public init(qid: String, label: String, altLabels: [String], file: String) {
        self.qid = qid
        self.label = label
        self.altLabels = altLabels
        self.file = file
    }
}

/// Keyless TV channel and league logos from Wikidata (CC0 data) and Wikimedia Commons.
///
/// One SPARQL query runs per country present in the user's channels. Each answer is stored permanently in Application Support, refreshed at most
/// every 30 days, and the last good copy is kept when a refresh fails. Requests share a pace of
/// one per five seconds; on HTTP 429 or 503 the call waits 60 s and retries once.
/// Wikimedia policy requires the descriptive User-Agent.
public actor WikidataLogoDirectory {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    public static let refreshInterval: TimeInterval = 30 * 24 * 60 * 60
    public static let requestSpacing: TimeInterval = 5
    public static let retryDelay: TimeInterval = 60
    static let version = 2
    static let maximumResponseBytes = 16 * 1_024 * 1_024
    static let endpoint = "https://query.wikidata.org/sparql"

    /// Wikidata items for the countries channels are matched in. A channel in any other country is not matched.
    public static let countryItems: [String: String] = ["CA": "Q16", "US": "Q30"]
    /// Instance-of values that count as a TV channel, network, station or broadcaster. Canada's query also takes their subclasses
    /// (`P279*`); the same query for the United States timed out on the public endpoint (HTTP 504, measured 2026-11-16).
    static let channelTypes = ["Q2001305", "Q141683", "Q1616075", "Q15265344", "Q1254874"]
    /// Width Commons renders a logo at: the largest logo drawn (the 351 pt channel panel at 4K, 702 px) rounded up, below Commons' 1,024 px cap.
    public static let renditionWidth = 704

    public static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Plozz/\(version) (https://github.com/brandomoore/Plozz)"
    }

    struct Group: Codable {
        var refreshedAt: Date
        var entries: [WikidataLogoEntry]
    }

    private struct Document: Codable {
        var version = WikidataLogoDirectory.version
        var groups: [String: Group] = [:]
        /// Commons licence text by file name, kept with each logo that was matched.
        var licences: [String: String] = [:]
        /// Commons artist credit (plain text) by file name, for the files whose licence asks for one.
        var artists: [String: String]? = [:]
    }

    private let fileURL: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var document = Document()
    private var loaded = false
    private var lastRequest: Date?
    private var refreshes: [String: Task<Void, Never>] = [:]

    public init(
        fileURL: URL,
        fetch: @escaping Fetch = WikidataLogoDirectory.fetchRequest,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.fileURL = fileURL
        self.fetch = fetch
        self.now = now
        self.sleep = sleep
    }

    /// `Application Support/Plozz/WikidataLogos/directory.json`.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Plozz", isDirectory: true)
            .appendingPathComponent("WikidataLogos", isDirectory: true)
            .appendingPathComponent("directory.json")
    }

    // MARK: Reading

    /// Logo-bearing channels of a country (`CA`, `US`), refreshed first when the stored list is
    /// older than 30 days. The stored copy is returned when the refresh fails.
    public func channels(country: String) async -> [WikidataLogoEntry] {
        guard let item = Self.countryItems[country] else { return [] }
        return await entries(group: "country:\(item)", query: Self.channelQuery(countryItem: item))
    }

    /// Logos for the given Wikidata items (the league badges), stored and refreshed like a country list.
    public func items(_ qids: [String]) async -> [WikidataLogoEntry] {
        let sorted = Array(Set(qids)).sorted()
        guard !sorted.isEmpty else { return [] }
        return await entries(group: "items:\(sorted.joined(separator: ","))", query: Self.itemQuery(qids: sorted))
    }

    /// Instance-of values that count as a sports team or club (searched with their subclasses).
    static let teamTypes = ["Q12973014", "Q847017"]

    /// Logo-bearing teams whose league (P118) is the given item, stored and refreshed like a country list.
    public func teams(league qid: String) async -> [WikidataLogoEntry] {
        await entries(group: "teams:\(qid)", query: Self.teamQuery(league: qid))
    }

    /// When the stored list for a country was downloaded.
    public func refreshedAt(country: String) -> Date? {
        loadIfNeeded()
        return Self.countryItems[country].flatMap { document.groups["country:\($0)"]?.refreshedAt }
    }

    /// The Commons licence text stored for a file, fetching it once when it is not stored yet.
    public func licence(forFile file: String) async -> String? {
        loadIfNeeded()
        if let stored = document.licences[file] { return stored.isEmpty ? nil : stored }
        guard let url = Self.licenceURL(file: file),
              let data = await request(URLRequest(url: url), accept: "application/json") else { return nil }
        let text = Self.parseLicence(data) ?? ""
        document.licences[file] = text
        if let artist = Self.parseArtist(data) { document.artists = (document.artists ?? [:]).merging([file: artist]) { _, new in new } }
        _ = write()
        return text.isEmpty ? nil : text
    }

    /// The credit line for a CC BY or CC BY-SA file: `Logo: <file> by <artist>, <licence>, <file page>`; `nil` when the licence asks for no credit
    /// or is not allowed. The licence is fetched first when it is not stored yet.
    public func credit(forFile file: String) async -> String? {
        guard let licence = await licence(forFile: file), Self.requiresCredit(licence: licence),
              let page = Self.filePageURL(file: file) else { return nil }
        let artist = document.artists?[file].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown author"
        return "Logo: \(file) by \(artist), \(licence), \(page.absoluteString)"
    }

    /// The licence when it is on the allow-list, else `nil` (the file is not used). Fetched once per file and stored.
    public func allowedLicence(forFile file: String) async -> String? {
        guard let text = await licence(forFile: file), Self.isAllowed(licence: text) else { return nil }
        return text
    }

    // MARK: Licences

    /// Public domain variants (`PD-textlogo`, `Public domain`, `PD-ineligible`…), CC0, CC BY and CC BY-SA. Anything else, or a missing licence,
    /// is not allowed. Matching is on the normalised short name: `CC BY-NC`, `CC BY-ND` and `GFDL` are rejected.
    public static func isAllowed(licence: String) -> Bool {
        let text = licence.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("public domain") || text.hasPrefix("pd-") || text == "pd" || text.hasPrefix("cc0") || text.hasPrefix("cc-zero") { return true }
        let tokens = text.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        guard tokens.first == "cc", tokens.count >= 2 else { return false }
        let rest = Array(tokens.dropFirst())
        guard rest.first == "by" else { return false }
        let terms = rest.dropFirst().prefix { Double($0) == nil }
        return terms.isEmpty || terms.elementsEqual(["sa"])
    }

    /// CC BY and CC BY-SA files must be credited; public domain and CC0 need no credit.
    public static func requiresCredit(licence: String) -> Bool {
        isAllowed(licence: licence) && licence.lowercased().replacingOccurrences(of: "-", with: " ").hasPrefix("cc by")
    }

    static func filePageURL(file: String) -> URL? {
        guard !file.contains("/"), !file.contains("?"), !file.contains("#"),
              let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/File:\(encoded)")
    }

    /// The artist from Commons' `extmetadata`, as plain text with the HTML removed.
    static func parseArtist(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        for case let page as [String: Any] in pages.values {
            let info = (page["imageinfo"] as? [[String: Any]])?.first
            if let html = ((info?["extmetadata"] as? [String: Any])?["Artist"] as? [String: Any])?["value"] as? String {
                let plain = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !plain.isEmpty { return plain }
            }
        }
        return nil
    }

    // MARK: Refresh

    private func entries(group key: String, query: String) async -> [WikidataLogoEntry] {
        loadIfNeeded()
        let stored = document.groups[key]
        if let stored, now().timeIntervalSince(stored.refreshedAt) < Self.refreshInterval { return stored.entries }
        if let running = refreshes[key] {
            await running.value
        } else {
            let task = Task { await self.refresh(group: key, query: query) }
            refreshes[key] = task
            await task.value
            refreshes[key] = nil
        }
        return document.groups[key]?.entries ?? stored?.entries ?? []
    }

    private func refresh(group key: String, query: String) async {
        guard var components = URLComponents(string: Self.endpoint) else { return }
        components.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url,
              let data = await request(URLRequest(url: url), accept: "application/sparql-results+json"),
              let entries = Self.parseEntries(data) else { return }
        // The refresh is also the licence recheck: the files of the replaced list are read again when next used, so a relicensed or
        // deleted file stops being drawn.
        if let old = document.groups[key] {
            for entry in old.entries {
                document.licences[entry.file] = nil
                document.artists?[entry.file] = nil
            }
        }
        document.groups[key] = Group(refreshedAt: now(), entries: entries)
        _ = write()
    }

    /// One paced request; `nil` when it failed. A 429 or 503 waits a minute and tries once more.
    private func request(_ original: URLRequest, accept: String) async -> Data? {
        var request = original
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        for attempt in 0..<2 {
            if Task.isCancelled { return nil }
            if let lastRequest {
                let wait = Self.requestSpacing - now().timeIntervalSince(lastRequest)
                if wait > 0 { await sleep(wait) }
            }
            lastRequest = now()
            guard let (data, status) = try? await fetch(request) else { return nil }
            if status == 429 || status == 503 {
                if attempt == 0 { await sleep(Self.retryDelay); continue }
                return nil
            }
            guard (200...299).contains(status), data.count <= Self.maximumResponseBytes else { return nil }
            return data
        }
        return nil
    }

    // MARK: Queries

    static func channelQuery(countryItem: String) -> String {
        let types = channelTypes.map { "wd:\($0)" }.joined(separator: " ")
        return """
        SELECT ?item ?itemLabel (SAMPLE(?logo) AS ?logoFile) (GROUP_CONCAT(DISTINCT ?alt; separator="|") AS ?alts) WHERE {
          VALUES ?type { \(types) }
          ?item \(countryItem == "Q16" ? "wdt:P31/wdt:P279*" : "wdt:P31") ?type ; wdt:P17 wd:\(countryItem) ; wdt:P154 ?logo .
          OPTIONAL { ?item rdfs:label|skos:altLabel ?alt . FILTER(LANG(?alt) IN ("fr", "en")) }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en,fr". }
        } GROUP BY ?item ?itemLabel
        """
    }

    public static func teamQuery(league qid: String) -> String {
        let types = teamTypes.map { "wd:\($0)" }.joined(separator: " ")
        return """
        SELECT ?item ?itemLabel (SAMPLE(?logo) AS ?logoFile) (GROUP_CONCAT(DISTINCT ?alt; separator="|") AS ?alts) WHERE {
          VALUES ?type { \(types) }
          ?item wdt:P31/wdt:P279* ?type ; wdt:P118 wd:\(qid) ; wdt:P154 ?logo .
          FILTER NOT EXISTS { ?item wdt:P576 ?dissolved }
          OPTIONAL { ?item skos:altLabel ?alt . FILTER(LANG(?alt) = "en") }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } GROUP BY ?item ?itemLabel
        """
    }

    static func itemQuery(qids: [String]) -> String {
        let values = qids.map { "wd:\($0)" }.joined(separator: " ")
        return """
        SELECT ?item ?itemLabel (SAMPLE(?logo) AS ?logoFile) (GROUP_CONCAT(DISTINCT ?alt; separator="|") AS ?alts) WHERE {
          VALUES ?item { \(values) }
          ?item wdt:P154 ?logo .
          OPTIONAL { ?item skos:altLabel ?alt . FILTER(LANG(?alt) = "en") }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } GROUP BY ?item ?itemLabel
        """
    }

    /// Entries from a SPARQL JSON answer. Items without an English label, or whose logo is not a
    /// Commons file, are skipped.
    static func parseEntries(_ data: Data) -> [WikidataLogoEntry]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else { return nil }
        func value(_ binding: [String: Any], _ name: String) -> String? {
            (binding[name] as? [String: Any])?["value"] as? String
        }
        var seen = Set<String>()
        var entries: [WikidataLogoEntry] = []
        for binding in bindings {
            guard let itemURL = value(binding, "item"), let qid = itemURL.split(separator: "/").last.map(String.init),
                  qid.hasPrefix("Q"), seen.insert(qid).inserted,
                  let label = value(binding, "itemLabel"), label != qid, !label.isEmpty,
                  let logo = value(binding, "logoFile"), let file = commonsFile(fromURL: logo) else { continue }
            let alts = (value(binding, "alts") ?? "").split(separator: "|").map(String.init).filter { !$0.isEmpty }
            entries.append(WikidataLogoEntry(qid: qid, label: label, altLabels: alts.sorted(), file: file))
        }
        return entries.sorted { $0.qid < $1.qid }
    }

    /// `Special:FilePath/<name>` URLs come back from P154; the file name is the last path component.
    static func commonsFile(fromURL text: String) -> String? {
        guard let url = URL(string: text), url.host?.hasSuffix("wikimedia.org") == true,
              url.path.contains("Special:FilePath/") else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// The URL the logo image is loaded from. Commons rasterises an SVG at the requested width.
    public static func imageURL(file: String, width: Int = renditionWidth) -> URL? {
        let width = min(max(width, 1), 1_024)
        guard !file.isEmpty, !file.contains("/"), !file.contains("?"), !file.contains("#"),
              let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=\(width)")
    }

    static func licenceURL(file: String) -> URL? {
        guard var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "titles", value: "File:\(file)"),
            URLQueryItem(name: "prop", value: "imageinfo"), URLQueryItem(name: "iiprop", value: "extmetadata"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components.url
    }

    /// The short licence name from Commons' `extmetadata`, such as "Public domain".
    static func parseLicence(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return nil }
        for case let page as [String: Any] in pages.values {
            let info = (page["imageinfo"] as? [[String: Any]])?.first
            let metadata = info?["extmetadata"] as? [String: Any]
            for name in ["LicenseShortName", "UsageTerms"] {
                if let text = (metadata?[name] as? [String: Any])?["value"] as? String, !text.isEmpty { return text }
            }
        }
        return nil
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

    private func write() -> Bool {
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

    /// SPARQL answers can take over 20 s (the NBA team list measured 22 s on 2026-11-16), longer than the shared metadata session
    /// allows a resource, so this directory has its own limits: 70 s per request, 90 s overall.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 70
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// The production transport.
    public static let fetchRequest: Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataDiscoveryHTTPError.invalidResponse }
        return (data, http.statusCode)
    }
}
