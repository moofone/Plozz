import CoreModels
import Foundation
import os
import MetadataKit
#if canImport(OSLog)
import OSLog
#endif

/// A channel as the logo service sees it.
public struct LiveTVLogoRequest: Equatable, Sendable {
    public let identity: LiveTVChannelLogoIdentity
    public let query: LiveTVTMDbChannelQuery
    public var key: LiveTVChannelLogoKey { identity.key }
    /// Whether TMDB may be matched automatically. Overrides apply to every channel.
    public let matchesAutomatically: Bool

    public init(identity: LiveTVChannelLogoIdentity, query: LiveTVTMDbChannelQuery, matchesAutomatically: Bool) {
        self.identity = identity
        self.query = query
        self.matchesAutomatically = matchesAutomatically
    }

    public init(channel: LiveTVPrototypeChannel) {
        let query = LiveTVTMDbChannelQuery(channel: channel)
        self.init(
            identity: LiveTVChannelLogoIdentity(channel: channel), query: Self.broadcasterQuery(for: query) ?? query,
            matchesAutomatically: channel.source == .iptv
        )
    }

    /// An event channel names no network and no league, only the service it streams on ("US| FLO VIP PPV"). Its logo is that
    /// service's, found by the normal resolver, so the query is the service's name in the channel's country. Events whose league is
    /// known keep their name: the league badge is looked up for them.
    static func broadcasterQuery(for query: LiveTVTMDbChannelQuery) -> LiveTVTMDbChannelQuery? {
        guard LiveTVChannelKind.isEvent(name: query.name, groups: query.groups),
              LiveTVSportsEventParser.parse(query.name, groups: query.groups) == nil,
              let broadcaster = LiveTVSportsBroadcaster.broadcaster(name: query.name, groups: query.groups) else { return nil }
        return LiveTVTMDbChannelQuery(
            name: broadcaster.displayName, groups: [], country: LiveTVTMDbLogoMatcher.country(for: query)
        )
    }
}

/// Which source the logo seam answers from, per channel, for the DEBUG `logoSeam` summary.
struct LiveTVLogoSeamCounts: Equatable, Sendable {
    var override = 0
    var tmdb = 0
    var wikidata = 0
    var xmltv = 0
    var text = 0
    var tmdbAccess = false

    var line: String {
        "LIVE_TV event=logoSeam tmdbAccess=\(tmdbAccess) override=\(override) tmdb=\(tmdb) wikidata=\(wikidata) xmltv=\(xmltv) text=\(text)"
    }
}

/// The DEBUG `logoSeam` summary line. It goes straight to the unified log at notice level, public, so `log show` sees it;
/// `HandoffDiagnostics` is off in a default build and swallowed it.
enum LiveTVLogoSeamLog {
    nonisolated(unsafe) static var sink: (@Sendable (String) -> Void) = { line in
        #if canImport(OSLog)
        Logger(subsystem: "com.plozz.app", category: "livetv").notice("PLZXHAND \(line, privacy: .public)")
        #endif
    }
    static func emit(_ line: String) { sink(line) }
}

/// One network from a search in the Change Logo sheet.
public struct LiveTVLogoNetworkResult: Identifiable, Equatable, Sendable {
    public let entry: TMDbNetworkEntry
    public var id: Int { entry.id }
}

/// Picks and remembers the logo each Live TV channel is drawn with.
///
/// Precedence is the user's override, then the TMDB network match, then the provider's
/// own logo (which the caller falls back to when no URL is returned here). Matches and
/// network details are stored permanently, so each is requested from TMDB once. With
/// TMDB access disabled nothing is requested and matches are ignored; the user's own
/// overrides still apply.
public actor LiveTVChannelLogoService {
    public typealias AccessProvider = @Sendable () -> TMDbAccess

    /// Channels matched between two published updates.
    public static let batchSize = 100

    public nonisolated let store: LiveTVChannelLogoStore
    public nonisolated let directory: TMDbNetworkDirectory
    public nonisolated let wikidata: WikidataLogoDirectory
    private nonisolated let accessProvider: AccessProvider
    private let http: MetadataDiscoveryHTTPClient
    private let limiter = RateLimiter(requestsPerSecond: 10, burst: 5)
    private let breaker = ProviderCircuitBreaker()
    private var matcher: (refreshedAt: Date, value: LiveTVTMDbLogoMatcher)?
    private var wikidataMatchers: [String: (refreshedAt: Date, value: LiveTVWikidataLogoMatcher)] = [:]
    private var inFlightNetworks: [Int: Task<TMDbNetworkLogo?, Error>] = [:]
    private var lastAccess: TMDbAccess?
    private let measureGuideIcon: @Sendable (URL) async -> LiveTVLogoSize?
    /// Measured guide icons, kept for the session; `nil` records an icon that could not be measured.
    private var guideIconSizes: [URL: LiveTVLogoSize?] = [:]
    /// What the display seam may draw of the guide's XMLTV icons: measured crisp, and not rejected as a placeholder.
    private nonisolated let guideIconState = GuideIconState()

    private final class GuideIconState: @unchecked Sendable {
        private let lock = NSLock()
        private var crisp = Set<URL>()
        private var rejected = Set<URL>()
        func record(_ sizes: [URL: LiveTVLogoSize]) {
            lock.withLock { for (url, size) in sizes where LiveTVLogoQuality.isCrisp(size, for: .hero) { crisp.insert(url) } }
        }
        func reject(_ urls: Set<URL>) { lock.withLock { rejected = urls } }
        func isDrawable(_ url: URL) -> Bool { lock.withLock { crisp.contains(url) && !rejected.contains(url) } }
        var count: Int { lock.withLock { crisp.count } }
    }

    private let measureLogoColour: @Sendable (URL) async -> Bool?
    /// Which logo images are black/white/grey (`true`) or coloured (`false`), measured once per session.
    private nonisolated let colourState: ColourState

    private final class ColourState: @unchecked Sendable {
        private let store: LiveTVChannelLogoStore
        init(store: LiveTVChannelLogoStore) { self.store = store }
        /// Measured once per image URL, ever: the answer lives in the logo store (an in-memory read), so a relaunch measures nothing.
        func isMonochrome(_ url: URL) -> Bool? { store.isMonochrome(url) ?? nil }
        /// A failed measurement (network) is not kept: it is not tried again this session, and is tried again next one.
        func record(_ url: URL, _ value: Bool?) {
            guard let value else { lock.withLock { _ = failed.insert(url) }; return }
            store.recordMonochrome(value, for: url)
        }
        func wasAttempted(_ url: URL) -> Bool { store.isMonochrome(url) != nil || lock.withLock { failed.contains(url) } }
        private let lock = NSLock()
        private var failed = Set<URL>()
    }

    /// Logo images measured for colour per session; the first (priority-ordered) channels' logos are measured, the rest keep source order.
    static let maximumColourMeasurements = 150

    public init(
        store: LiveTVChannelLogoStore, directory: TMDbNetworkDirectory, wikidata: WikidataLogoDirectory,
        accessProvider: @escaping AccessProvider,
        http: MetadataDiscoveryHTTPClient = MetadataDiscoveryHTTPClient(),
        measureGuideIcon: @escaping @Sendable (URL) async -> LiveTVLogoSize? = { await LiveTVGuideIconMeasurer.measure($0) },
        measureLogoColour: @escaping @Sendable (URL) async -> Bool? = { await LiveTVLogoColourMeasurer.isMonochrome(at: $0) }
    ) {
        self.measureLogoColour = measureLogoColour
        self.colourState = ColourState(store: store)
        self.measureGuideIcon = measureGuideIcon
        self.store = store
        self.directory = directory
        self.wikidata = wikidata
        self.accessProvider = accessProvider
        self.http = http
    }

    /// The shared instance, created with ``configureShared(accessProvider:)`` at app start.
    /// Until then TMDB access is disabled, so nothing is requested.
    public static let shared = LiveTVChannelLogoService(
        store: LiveTVChannelLogoStore(fileURL: LiveTVChannelLogoStore.defaultFileURL()),
        directory: TMDbNetworkDirectory(fileURL: TMDbNetworkDirectory.defaultFileURL()),
        wikidata: WikidataLogoDirectory(fileURL: WikidataLogoDirectory.defaultFileURL()),
        accessProvider: { SharedAccess.current }
    )

    /// Sets how the shared service reads the current TMDB access (bundled token, the user's key, or a proxy).
    public static func configureShared(accessProvider: @escaping AccessProvider) {
        SharedAccess.set(accessProvider)
    }

    private final class SharedAccess: @unchecked Sendable {
        private static let box = SharedAccess()
        private let lock = NSLock()
        private var provider: AccessProvider = { .disabled }
        static var current: TMDbAccess { box.lock.withLock { box.provider }() }
        static func set(_ value: @escaping AccessProvider) { box.lock.withLock { box.provider = value } }
    }

    public nonisolated var isTMDbEnabled: Bool { accessProvider().isEnabled }

    // MARK: Reading choices

    /// The logo URL for `key` from stored choices, honouring the override and access state.
    public nonisolated func storedLogoURL(for identity: LiveTVChannelLogoIdentity) -> URL? {
        storedLogoURL(for: identity, tmdbEnabled: isTMDbEnabled)
    }

    /// Stored logo URLs for many channels; the TMDB access is read once.
    public nonisolated func storedLogoURLs(for identities: [LiveTVChannelLogoIdentity]) -> [LiveTVChannelLogoKey: URL] {
        let enabled = isTMDbEnabled
        var urls: [LiveTVChannelLogoKey: URL] = [:]
        for identity in identities {
            if let url = storedLogoURL(for: identity, tmdbEnabled: enabled) { urls[identity.key] = url }
        }
        return urls
    }

    private nonisolated func storedLogoURL(for identity: LiveTVChannelLogoIdentity, tmdbEnabled: Bool) -> URL? {
        storedLogoURL(for: identity.key, nameKey: identity.nameKey, tmdbEnabled: tmdbEnabled)
    }

    private nonisolated func storedLogoURL(
        for key: LiveTVChannelLogoKey, nameKey: String?, tmdbEnabled: Bool
    ) -> URL? {
        storedLogoCandidate(for: key, nameKey: nameKey, tmdbEnabled: tmdbEnabled)?.url
    }

    private nonisolated func storedLogoCandidate(
        for key: LiveTVChannelLogoKey, nameKey: String?, tmdbEnabled: Bool
    ) -> LiveTVLogoCandidate? {
        if let override = store.override(for: key) {
            switch override {
            case .url(let url): return LiveTVLogoCandidate(source: .override, url: url, size: nil)
            case .tmdbNetwork(let id):
                if let network = store.network(id: id), let url = network.logoURL {
                    registerNetworkLogo(url, network)
                    return LiveTVLogoCandidate(source: .override, url: url, size: nil)
                }
            }
        }
        var candidates: [LiveTVLogoCandidate] = []
        if tmdbEnabled, let candidate = tmdbCandidate(for: key, nameKey: nameKey) { candidates.append(candidate) }
        if case .logo(_, let file)? = store.wikidataMatch(for: key, nameKey: nameKey),
           let url = WikidataLogoDirectory.imageURL(file: file) {
            candidates.append(LiveTVLogoCandidate(source: .wikidata, url: url, size: Self.isVectorFile(file) ? .vector : nil))
        }
        var isNetwork = false
        if case .network? = store.match(for: key, nameKey: nameKey) { isNetwork = true }
        return LiveTVLogoQuality.choose(candidates, tmdbIsNetworkMatch: isNetwork, isMonochrome: { colourState.isMonochrome($0) })
    }

    private nonisolated func tmdbCandidate(for key: LiveTVChannelLogoKey, nameKey: String?) -> LiveTVLogoCandidate? {
        guard let match = store.match(for: key, nameKey: nameKey) else { return nil }
        switch match {
        case .network(let id, let path):
            guard let url = TMDbNetworkLogoClient.imageURL(filePath: path) else { return nil }
            registerNetworkLogo(url, store.network(id: id))
            return LiveTVLogoCandidate(source: .tmdb, url: url, size: Self.rasterSize(store.network(id: id)))
        case .show(_, let path):
            return TMDbNetworkLogoClient.imageURL(filePath: path).map { LiveTVLogoCandidate(source: .tmdb, url: $0, size: nil) }
        case .none: return nil
        }
    }

    /// Marks `url` as a network logo and lists the other files TMDB offers for the network, so the artwork never replaces it with the
    /// channel's name and may pick the variant that reads best per theme.
    private nonisolated func registerNetworkLogo(_ url: URL, _ network: TMDbNetworkLogo?) {
        let variants = network?.variantURLs ?? []
        let known = LiveTVNetworkLogoRegistry.shared.variants(for: url)
        if known == nil || known?.count != max(variants.count, 1) {
            LiveTVNetworkLogoRegistry.shared.register(defaultURL: url, variants: variants)
        }
    }

    private static func rasterSize(_ network: TMDbNetworkLogo?) -> LiveTVLogoSize? {
        guard let width = network?.pixelWidth, let height = network?.pixelHeight else { return nil }
        return .raster(width: width, height: height)
    }

    /// Commons renders an SVG at any width; any other file is measured by the evaluation only.
    static func isVectorFile(_ file: String) -> Bool { file.lowercased().hasSuffix(".svg") }

    /// A TMDB logo already measured below the size the panel draws, which a Wikidata logo of the same channel may beat.
    private nonisolated func tmdbLogoIsSoft(_ identity: LiveTVChannelLogoIdentity) -> Bool {
        guard case .network(let id, _)? = store.match(for: identity.key, nameKey: identity.nameKey),
              let size = Self.rasterSize(store.network(id: id)) else { return false }
        return !LiveTVLogoQuality.isCrisp(size, for: .hero)
    }

    /// A TMDB logo already measured black, white or grey, which a Wikidata logo of the same channel may beat by having colour.
    private nonisolated func tmdbLogoIsMonochrome(_ identity: LiveTVChannelLogoIdentity) -> Bool {
        guard let url = tmdbCandidate(for: identity.key, nameKey: identity.nameKey)?.url else { return false }
        return colourState.isMonochrome(url) == true
    }

    /// Prefers a colour logo over a black/white one. Measures the TMDB logos of `requests` (in order, at most
    /// ``maximumColourMeasurements`` images per session), matches Wikidata for channels whose TMDB logo is monochrome, measures
    /// those logos too, and publishes the URLs that changed.
    public func preferColourLogos(
        _ requests: [LiveTVLogoRequest], publish: @Sendable ([LiveTVChannelLogoKey: URL]) async -> Void
    ) async {
        let automatic = requests.filter { $0.matchesAutomatically && store.override(for: $0.key) == nil }
        guard !automatic.isEmpty, isTMDbEnabled else { return }
        let before = storedLogoURLs(for: automatic.map(\.identity))
        await measureColour(of: automatic.compactMap { tmdbCandidate(for: $0.key, nameKey: $0.identity.nameKey)?.url })
        let monochrome = automatic.filter { tmdbLogoIsMonochrome($0.identity) }
        guard !monochrome.isEmpty, !Task.isCancelled else { return }
        await matchWikidata(monochrome, tmdbEnabled: true, publish: { _ in })
        await measureColour(of: monochrome.compactMap { request in
            guard case .logo(_, let file)? = store.wikidataMatch(for: request.identity) else { return nil }
            return WikidataLogoDirectory.imageURL(file: file)
        })
        guard !Task.isCancelled else { return }
        let changed = storedLogoURLs(for: automatic.map(\.identity)).filter { before[$0.key] != $0.value }
        if !changed.isEmpty { await publish(changed) }
    }

    private func measureColour(of urls: [URL]) async {
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted && !colourState.wasAttempted(url) {
            if Task.isCancelled || colourMeasurements >= Self.maximumColourMeasurements { return }
            colourMeasurements += 1
            colourState.record(url, await measureLogoColour(url))
        }
    }

    private var colourMeasurements = 0

    /// The one answer to "what logo does Live TV draw for this channel": the user's override, else the TMDB match, else the
    /// Wikidata/Commons match, else the guide's XMLTV icon when it has been measured crisp and is not a placeholder, else `nil`
    /// (the channel's name is drawn as text). The playlist provider's own logo is never drawn. A Plozz channel keeps its own artwork.
    public nonisolated func displayedLogoURL(for channel: LiveTVPrototypeChannel) -> URL? {
        displayedLogo(for: channel)?.url
    }

    /// What ``displayedLogoURL(for:)`` answers and which source it came from; `nil` draws the channel's name.
    nonisolated func displayedLogo(for channel: LiveTVPrototypeChannel) -> LiveTVLogoCandidate? {
        displayedLogo(for: channel, tmdbEnabled: isTMDbEnabled)
    }

    /// ``displayedLogoURL(for:)`` for a loop over many channels: the caller reads ``isTMDbEnabled`` once (it reads the Keychain), never per channel.
    public nonisolated func displayedLogoURL(for channel: LiveTVPrototypeChannel, tmdbEnabled: Bool) -> URL? {
        displayedLogo(for: channel, tmdbEnabled: tmdbEnabled)?.url
    }

    nonisolated func displayedLogo(for channel: LiveTVPrototypeChannel, tmdbEnabled: Bool) -> LiveTVLogoCandidate? {
        if let stored = storedLogoCandidate(for: LiveTVChannelLogoKey(channel: channel), nameKey: nil, tmdbEnabled: tmdbEnabled) {
            return stored
        }
        if channel.source == .plozz { return channel.logoURL.map { LiveTVLogoCandidate(source: .curated, url: $0, size: nil) } }
        guard let icon = channel.guideLogoURL, guideIconState.isDrawable(icon) else { return nil }
        return LiveTVLogoCandidate(source: .xmltv, url: icon, size: nil)
    }

    /// How many of `channels` draw a logo from each source, and how many draw their name. Own artwork of Plozz channels is not counted.
    nonisolated func logoSeamCounts(for channels: [LiveTVPrototypeChannel]) -> LiveTVLogoSeamCounts {
        var counts = LiveTVLogoSeamCounts()
        let enabled = isTMDbEnabled
        counts.tmdbAccess = enabled
        for channel in channels where channel.source != .plozz && !channel.isSectionMarker {
            let candidate = displayedLogo(for: channel, tmdbEnabled: enabled)
            switch candidate?.source {
            case .override?: counts.override += 1
            case .tmdb?: counts.tmdb += 1
            case .wikidata?: counts.wikidata += 1
            case .xmltv?: counts.xmltv += 1
            case .curated?, nil: counts.text += 1
            }
        }
        return counts
    }

    /// How many guide icons are measured crisp; it changes when a drawable icon appears.
    public nonisolated var drawableGuideIconCount: Int { guideIconState.count }

    /// Guide icons shared by several unrelated channels (flags, brand images); they are never drawn.
    public nonisolated func rejectGuideIcons(_ urls: Set<URL>) { guideIconState.reject(urls) }

    /// The pixel size of each guide icon, downloading each one once per session, in order, until cancelled.
    /// An icon that cannot be measured is left out, so it is never drawn.
    /// A size is measured once per icon URL, ever: the answer is kept in the logo store, so a relaunch measures nothing.
    public func guideIconSizes(for urls: [URL]) async -> [URL: LiveTVLogoSize] {
        var sizes: [URL: LiveTVLogoSize] = [:]
        var measured: [URL: LiveTVLogoSize?] = [:]
        for url in urls {
            if Task.isCancelled { break }
            // Outer nil: never measured. `.some(nil)`: measured, and could not be measured.
            var cached: LiveTVLogoSize?? = guideIconSizes[url]
            if cached == nil { cached = store.iconSize(for: url) }
            if let known = cached {
                guideIconSizes[url] = .some(known)
                if let size = known { sizes[url] = size }
                continue
            }
            let size = await measureGuideIcon(url)
            if Task.isCancelled { break }
            guideIconSizes[url] = .some(size)
            measured[url] = .some(size)
            if let size { sizes[url] = size }
        }
        store.recordIconSizes(measured)
        guideIconState.record(sizes)
        return sizes
    }

    // MARK: Regional logo counts

    /// How many times the saved regional counts were read back and how many were computed and saved (tests, diagnostics).
    public nonisolated var regionalCountStats: (loaded: Int, saved: Int) { regionalStats.withLock { $0 } }
    private nonisolated let regionalStats = OSAllocatedUnfairLock(initialState: (loaded: 0, saved: 0))

    private struct RegionalCountsFile: Codable {
        var inputKey: UInt64
        var urls: [String]
        var counts: [Int]
    }

    /// The regional counts last saved for exactly these inputs, or `nil`. Only counts of two or more are kept: nothing else is read.
    public nonisolated func storedRegionalLogoCounts(inputKey: UInt64) -> [URL: Int]? {
        let url = store.sidecarURL(named: "regional-logo-counts.json")
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(RegionalCountsFile.self, from: data),
              file.inputKey == inputKey, file.urls.count == file.counts.count else { return nil }
        var counts: [URL: Int] = [:]
        for (text, count) in zip(file.urls, file.counts) { if let key = URL(string: text) { counts[key] = count } }
        regionalStats.withLock { $0.loaded += 1 }
        return counts
    }

    public nonisolated func saveRegionalLogoCounts(_ counts: [URL: Int], inputKey: UInt64) {
        let ordered = counts.sorted { $0.key.absoluteString < $1.key.absoluteString }
        let file = RegionalCountsFile(inputKey: inputKey, urls: ordered.map(\.key.absoluteString), counts: ordered.map(\.value))
        guard let data = try? JSONEncoder().encode(file) else { return }
        let url = store.sidecarURL(named: "regional-logo-counts.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: url, options: .atomic)) != nil { regionalStats.withLock { $0.saved += 1 } }
    }

    // MARK: What needs matching

    /// The channels whose matching inputs have no stored result: a new channel, a renamed one (its identity's name changed) or one
    /// whose last attempt was cleared by a refreshed TMDB catalogue. Matching is never repeated for the others, so a lineup that
    /// has not changed, and every launch, filter change, focus change or remote iCloud change, costs no matching at all. Reads the
    /// store only (no network, no parsing beyond the identities already derived), in the order given.
    public nonisolated func pendingRequests(_ requests: [LiveTVLogoRequest]) -> [LiveTVLogoRequest] {
        let tmdbEnabled = isTMDbEnabled
        return requests.filter { request in
            guard request.matchesAutomatically, !store.hasOverride(request.key) else { return false }
            let match = store.match(for: request.identity)
            if tmdbEnabled, match == nil { return true }
            if tmdbEnabled, let match, !Self.isNoMatch(match) { return false }
            let wikidataMatch = store.wikidataMatch(for: request.identity)
            if case .logo? = wikidataMatch { return false }
            // A league badge is stored once the league's list answers; until then the event is asked again.
            if Self.eventLeague(of: request.identity) != nil { return true }
            return wikidataMatch == nil && Self.hasWikidataList(request.query)
        }
    }

    private nonisolated static func eventLeague(of identity: LiveTVChannelLogoIdentity) -> LiveTVSportsLeague? {
        guard identity.nameKey.hasPrefix("event:") else { return nil }
        return LiveTVSportsLeague(rawValue: String(identity.nameKey.dropFirst("event:".count)))
    }

    private nonisolated static func hasWikidataList(_ query: LiveTVTMDbChannelQuery) -> Bool {
        LiveTVChannelKind.showLoopTitle(name: query.name, groups: query.groups) == nil
            && LiveTVTMDbLogoMatcher.country(for: query).map { WikidataLogoDirectory.countryItems[$0] != nil } == true
    }

    /// Lineup maintenance after a complete lineup fetch (see ``LiveTVChannelLogoStore/noteCompleteLineup(channelIDsBySource:iconURLs:)``).
    @discardableResult
    public nonisolated func noteCompleteLineup(channelIDsBySource: [String: Set<String>], iconURLs: Set<URL>) -> Int {
        store.noteCompleteLineup(channelIDsBySource: channelIDsBySource, iconURLs: iconURLs)
    }

    // MARK: Automatic matching

    /// Publishes stored choices at once, then matches the remaining channels in batches.
    /// `publish` receives only URLs that changed. Stops promptly when the task is cancelled.
    public func resolve(
        _ requests: [LiveTVLogoRequest],
        publish: @Sendable ([LiveTVChannelLogoKey: URL]) async -> Void
    ) async {
        let published = storedLogoURLs(for: requests.map(\.identity))
        if !published.isEmpty { await publish(published) }
        let access = accessProvider()
        noteAccess(access)
        guard !Task.isCancelled else { return }
        let automatic = requests.filter { $0.matchesAutomatically && store.override(for: $0.key) == nil }
        guard !automatic.isEmpty else { return }
        // The requests arrive in priority order (visible channels first). Each chunk runs TMDB, then Wikidata
        // for what TMDB left, so the first rows get logos in seconds rather than after a whole-catalog pass.
        var index = 0
        while index < automatic.count, !Task.isCancelled {
            let chunk = Array(automatic[index..<min(index + Self.batchSize, automatic.count)])
            index += Self.batchSize
            if access.isEnabled { await matchTMDb(chunk, access: access, publish: publish) }
            guard !Task.isCancelled else { return }
            await matchWikidata(chunk, tmdbEnabled: access.isEnabled, publish: publish)
            guard !Task.isCancelled else { return }
            await matchSportsLeagues(chunk, tmdbEnabled: access.isEnabled, publish: publish)
        }
    }

    /// A league-tagged event channel with no better logo gets its league's Wikidata badge. Nothing is
    /// stored when the lookup fails, so the glyph shows and the next run tries again.
    private func matchSportsLeagues(
        _ automatic: [LiveTVLogoRequest], tmdbEnabled: Bool,
        publish: @Sendable ([LiveTVChannelLogoKey: URL]) async -> Void
    ) async {
        var byLeague: [LiveTVSportsLeague: [LiveTVLogoRequest]] = [:]
        for request in automatic {
            if tmdbEnabled, let match = store.match(for: request.identity), !Self.isNoMatch(match) { continue }
            if case .logo? = store.wikidataMatch(for: request.identity) { continue }
            guard let event = LiveTVSportsEventParser.parse(request.query.name, groups: request.query.groups) else { continue }
            byLeague[event.league, default: []].append(request)
        }
        guard !byLeague.isEmpty else { return }
        let entries = await wikidata.items(byLeague.keys.map(\.wikidataItem))
        var updates: [LiveTVChannelLogoIdentity: LiveTVWikidataLogoMatch] = [:]
        var urls: [LiveTVChannelLogoKey: URL] = [:]
        for (league, requests) in byLeague {
            guard let entry = entries.first(where: { $0.qid == league.wikidataItem }),
                  let url = WikidataLogoDirectory.imageURL(file: entry.file) else { continue }
            for request in requests {
                updates[request.identity] = .logo(qid: entry.qid, file: entry.file)
                urls[request.key] = url
            }
        }
        store.recordWikidataMatches(updates)
        if !urls.isEmpty, !Task.isCancelled { await publish(urls) }
        for file in Set(updates.values.compactMap { if case .logo(_, let f) = $0 { f } else { nil } }).sorted() {
            if Task.isCancelled { return }
            _ = await wikidata.licence(forFile: file)
        }
    }

    private static func isNoMatch(_ match: LiveTVChannelLogoMatch) -> Bool {
        if case .none = match { return true }
        return false
    }

    private func matchTMDb(
        _ automatic: [LiveTVLogoRequest], access: TMDbAccess,
        publish: @Sendable ([LiveTVChannelLogoKey: URL]) async -> Void
    ) async {
        let client = TMDbNetworkLogoClient(access: access, http: http, limiter: limiter, breaker: breaker)
        // A refreshed network list is a reason to try unmatched channels again.
        if await directory.refreshIfNeeded() == .refreshed { store.clearNegativeMatches() }
        let networks = await directory.networks()
        guard !networks.isEmpty, let refreshedAt = await directory.refreshedAt() else { return }
        let matcher = self.matcher(for: networks, refreshedAt: refreshedAt)
        let stillPending = automatic.filter { store.match(for: $0.identity) == nil }

        var index = 0
        while index < stillPending.count, !Task.isCancelled {
            let batch = stillPending[index..<min(index + Self.batchSize, stillPending.count)]
            index += Self.batchSize
            var matches: [LiveTVChannelLogoIdentity: LiveTVChannelLogoMatch] = [:]
            var urls: [LiveTVChannelLogoKey: URL] = [:]
            for request in batch {
                if Task.isCancelled { break }
                guard let outcome = await outcome(for: request, matcher: matcher, client: client) else { continue }
                switch outcome {
                case .matched(let id, let path):
                    matches[request.identity] = .network(id: id, filePath: path)
                    if let url = TMDbNetworkLogoClient.imageURL(filePath: path) { urls[request.key] = url }
                case .matchedShow(let id, let path):
                    matches[request.identity] = .show(id: id, filePath: path)
                    if let url = TMDbNetworkLogoClient.imageURL(filePath: path) { urls[request.key] = url }
                case .unmatched:
                    matches[request.identity] = .none(directoryDate: refreshedAt)
                }
            }
            store.recordMatches(matches)
            if !urls.isEmpty, !Task.isCancelled { await publish(urls) }
        }
    }

    // MARK: Wikidata

    /// Matches channels that TMDB did not (or could not) cover against Wikidata's keyless logos.
    /// Channels in a country without a Wikidata list are left alone, since a name without a
    /// country cannot be told from another country's namesake.
    private func matchWikidata(
        _ automatic: [LiveTVLogoRequest], tmdbEnabled: Bool,
        publish: @Sendable ([LiveTVChannelLogoKey: URL]) async -> Void
    ) async {
        let pending = automatic.filter { request in
            if tmdbEnabled, let match = store.match(for: request.identity), !Self.isNoMatch(match), !tmdbLogoIsSoft(request.identity), !tmdbLogoIsMonochrome(request.identity) { return false }
            return LiveTVChannelKind.showLoopTitle(name: request.query.name, groups: request.query.groups) == nil
        }
        var byCountry: [String: [LiveTVLogoRequest]] = [:]
        for request in pending {
            guard let country = LiveTVTMDbLogoMatcher.country(for: request.query),
                  WikidataLogoDirectory.countryItems[country] != nil else { continue }
            byCountry[country, default: []].append(request)
        }
        var files = Set<String>()
        for country in byCountry.keys.sorted() {
            if Task.isCancelled { return }
            let entries = await wikidata.channels(country: country)
            guard !entries.isEmpty, let refreshedAt = await wikidata.refreshedAt(country: country) else { continue }
            let matcher = wikidataMatcher(country: country, entries: entries, refreshedAt: refreshedAt)
            var updates: [LiveTVChannelLogoIdentity: LiveTVWikidataLogoMatch] = [:]
            var urls: [LiveTVChannelLogoKey: URL] = [:]
            for request in byCountry[country] ?? [] {
                // A "no match" is final until the list is downloaded again.
                if case .none(let date)? = store.wikidataMatch(for: request.identity), LiveTVChannelLogoStore.isSameInstant(date, orLater: refreshedAt) { continue }
                if case .logo? = store.wikidataMatch(for: request.identity) { continue }
                if let entry = matcher.match(request.query, country: country) {
                    updates[request.identity] = .logo(qid: entry.qid, file: entry.file)
                    files.insert(entry.file)
                } else {
                    updates[request.identity] = .none(directoryDate: refreshedAt)
                }
            }
            store.recordWikidataMatches(updates)
            // What is drawn is the better of the TMDB and Wikidata logos, not necessarily Wikidata's.
            for request in byCountry[country] ?? [] {
                guard case .logo? = updates[request.identity], let url = storedLogoURL(for: request.identity) else { continue }
                urls[request.key] = url
            }
            if !urls.isEmpty, !Task.isCancelled { await publish(urls) }
        }
        // Each matched file's licence is read once and kept with the list.
        for file in files.sorted() {
            if Task.isCancelled { return }
            _ = await wikidata.licence(forFile: file)
        }
    }

    private func wikidataMatcher(
        country: String, entries: [WikidataLogoEntry], refreshedAt: Date
    ) -> LiveTVWikidataLogoMatcher {
        if let cached = wikidataMatchers[country], cached.refreshedAt == refreshedAt { return cached.value }
        let value = LiveTVWikidataLogoMatcher(entries: entries)
        wikidataMatchers[country] = (refreshedAt, value)
        return value
    }

    private enum Outcome {
        case matched(id: Int, filePath: String)
        case matchedShow(id: Int, filePath: String)
        case unmatched
    }

    /// `nil` when TMDB could not answer, so nothing is stored and the channel is retried later.
    private func outcome(
        for request: LiveTVLogoRequest, matcher: LiveTVTMDbLogoMatcher, client: TMDbNetworkLogoClient
    ) async -> Outcome? {
        if let title = LiveTVChannelKind.showLoopTitle(name: request.query.name, groups: request.query.groups) {
            // A 24/7 single-show channel shows the show's title logo; a failed lookup is retried, not stored.
            do {
                guard let logo = try await client.showLogo(forTitle: title) else { return .unmatched }
                return .matchedShow(id: logo.showID, filePath: logo.filePath)
            } catch {
                return nil
            }
        }
        let candidates = matcher.candidates(for: request.query)
        guard !candidates.isEmpty else { return .unmatched }
        var confirmed: [LiveTVTMDbCandidate] = []
        var countries: [Int: String?] = [:]
        var paths: [Int: String] = [:]
        for candidate in candidates {
            guard let logo = try? await networkLogo(id: candidate.networkID, client: client) else {
                return nil
            }
            guard !logo.name.isEmpty,
                  LiveTVTMDbLogoMatcher.normalized(logo.name) == LiveTVTMDbLogoMatcher.normalized(candidate.networkName),
                  let path = logo.filePath else { continue }
            confirmed.append(candidate)
            countries[candidate.networkID] = logo.originCountry
            paths[candidate.networkID] = path
        }
        guard let selected = LiveTVTMDbLogoMatcher.select(
            from: confirmed, originCountries: countries,
            channelCountry: LiveTVTMDbLogoMatcher.country(for: request.query)
        ), let path = paths[selected.networkID] else { return .unmatched }
        return .matched(id: selected.networkID, filePath: path)
    }

    private func matcher(for networks: [TMDbNetworkEntry], refreshedAt: Date) -> LiveTVTMDbLogoMatcher {
        if let matcher, matcher.refreshedAt == refreshedAt { return matcher.value }
        let value = LiveTVTMDbLogoMatcher(networks: networks)
        matcher = (refreshedAt, value)
        return value
    }

    private func noteAccess(_ access: TMDbAccess) {
        if let lastAccess, lastAccess != access {
            Task { await breaker.reset() }
        }
        lastAccess = access
        store.noteAccess(enabled: access.isEnabled)
    }

    // MARK: Network details

    /// Details and chosen logo for a network, requested at most once and then stored.
    private func networkLogo(id: Int, client: TMDbNetworkLogoClient) async throws -> TMDbNetworkLogo {
        if let stored = store.network(id: id), !(stored.name.isEmpty && stored.filePath != nil),
           !(stored.filePath != nil && stored.variantPaths == nil) { return stored }
        if let running = inFlightNetworks[id], let result = try await running.value { return result }
        let task = Task<TMDbNetworkLogo?, Error> {
            try await client.logo(forNetworkID: id)
        }
        inFlightNetworks[id] = task
        defer { inFlightNetworks[id] = nil }
        let logo = try await task.value ?? TMDbNetworkLogo(networkID: id, name: "", originCountry: nil, filePath: nil)
        store.recordNetwork(logo)
        return logo
    }

    // MARK: Override sheet

    /// Networks whose name contains the query. Searching needs no TMDB key, only the
    /// stored list, and refreshes it first when it is older than 30 days.
    public func searchNetworks(_ query: String, limit: Int = 20) async -> [LiveTVLogoNetworkResult] {
        await directory.search(query, limit: limit).map(LiveTVLogoNetworkResult.init(entry:))
    }

    /// Name, country and logo for a network shown in search results. `nil` when TMDB
    /// access is off or the request fails.
    public func networkLogo(id: Int) async -> TMDbNetworkLogo? {
        let access = accessProvider()
        guard access.isEnabled else { return store.network(id: id) }
        let client = TMDbNetworkLogoClient(access: access, http: http, limiter: limiter, breaker: breaker)
        return try? await networkLogo(id: id, client: client)
    }

    /// Stores a TMDB network as the channel's logo. `nil` when TMDB cannot supply one.
    public func chooseNetwork(id: Int, for key: LiveTVChannelLogoKey) async -> URL? {
        guard let logo = await networkLogo(id: id), let url = logo.logoURL,
              store.setOverride(.tmdbNetwork(id), for: key) else { return nil }
        return url
    }

    /// Stores an image URL as the channel's logo. `nil` when the URL is not acceptable.
    public nonisolated func chooseURL(_ text: String, for key: LiveTVChannelLogoKey) -> URL? {
        guard let url = LiveTVChannelLogoStore.validatedURL(text),
              store.setOverride(.url(url), for: key) else { return nil }
        return url
    }

    /// Removes the override. Returns the automatic logo's URL, if one is stored.
    public nonisolated func resetOverride(for identity: LiveTVChannelLogoIdentity) -> URL? {
        store.setOverride(nil, for: identity.key)
        return storedLogoURL(for: identity)
    }
}
