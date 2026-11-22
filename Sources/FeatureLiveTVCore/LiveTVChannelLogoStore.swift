import Foundation
import MetadataKit

/// Identifies a channel for logo purposes: the playlist or server source it came from
/// plus its channel ID. Shared by every profile on the device.
public struct LiveTVChannelLogoKey: Hashable, Codable, Sendable {
    public let sourceID: String
    public let channelID: String

    public init(sourceID: String, channelID: String) {
        self.sourceID = sourceID
        self.channelID = channelID
    }

    public init(channel: LiveTVPrototypeChannel) {
        self.init(sourceID: channel.playlistSourceID ?? channel.source.rawValue, channelID: channel.id)
    }
}

/// A channel and the name it was matched under. A stored match applies only while the name
/// is unchanged, so a provider that renumbers or renames channels cannot hand one channel
/// another's logo.
public struct LiveTVChannelLogoIdentity: Hashable, Codable, Sendable {
    public let key: LiveTVChannelLogoKey
    public let nameKey: String

    public init(key: LiveTVChannelLogoKey, nameKey: String) {
        self.key = key
        self.nameKey = nameKey
    }

    public init(channel: LiveTVPrototypeChannel) {
        self.init(key: LiveTVChannelLogoKey(channel: channel), nameKey: Self.nameKey(for: channel))
    }

    /// What a stored match is valid for. A provider rewrites an event channel's title for every event ("US ESPN+ 056 Western
    /// Carolina vs Cincinnati Nov 18 5:00pm ET"), but its logo is its league's or its broadcaster's, so an event channel is
    /// identified by that (`event:nba`, `event:espn+`). Its stored match then survives the next event instead of being
    /// matched, written and synced again for each one.
    static func nameKey(for channel: LiveTVPrototypeChannel) -> String {
        let groups = channel.groups ?? []
        if LiveTVChannelKind.isEvent(name: channel.name, groups: groups) {
            if let event = LiveTVSportsEventParser.parse(channel.name, groups: groups) { return "event:\(event.league.rawValue)" }
            if let broadcaster = LiveTVSportsBroadcaster.broadcaster(name: channel.name, groups: groups) {
                return "event:" + LiveTVTMDbLogoMatcher.normalized(broadcaster.displayName)
            }
        }
        return LiveTVTMDbLogoMatcher.normalized(LiveTVTMDbLogoMatcher.primaryKey(channel.name))
    }
}

/// A logo the user picked for a channel.
public enum LiveTVChannelLogoOverride: Codable, Equatable, Sendable {
    case tmdbNetwork(Int)
    case url(URL)
}

/// The stored outcome of automatic matching.
public enum LiveTVChannelLogoMatch: Codable, Equatable, Sendable {
    /// A TMDB network and its chosen logo path.
    case network(id: Int, filePath: String)
    /// A TMDB show's title logo, for a 24/7 single-show channel.
    case show(id: Int, filePath: String)
    /// Nothing matched; `directoryDate` is the network list the attempt used.
    case none(directoryDate: Date)
}

/// The stored outcome of matching a channel against Wikidata's keyless logos.
public enum LiveTVWikidataLogoMatch: Codable, Equatable, Sendable {
    /// A Wikidata item and the Commons file that is its logo.
    case logo(qid: String, file: String)
    /// Nothing matched; `directoryDate` is when the list the attempt used was downloaded.
    case none(directoryDate: Date)
}

/// Persistent logo choices, in Application Support.
///
/// Holds the user's overrides, the automatic matches (including "no match" results) and
/// the TMDB network details those matches came from, so nothing is looked up twice. The
/// file is versioned and written atomically. It is not profile-scoped.
public final class LiveTVChannelLogoStore: @unchecked Sendable {
    /// URLs longer than this are rejected.
    public static let maximumURLLength = 4_096
    /// Version 2 is one compact row per channel; version 1 (separate lists, a key repeated in each) is still read.
    static let version = 2

    private struct OverrideRecord: Codable {
        let key: LiveTVChannelLogoKey
        let value: LiveTVChannelLogoOverride
    }

    private struct MatchRecord: Codable {
        let key: LiveTVChannelLogoKey
        let nameKey: String
        let value: LiveTVChannelLogoMatch
    }

    private struct StoredMatch: Equatable {
        let nameKey: String
        let value: LiveTVChannelLogoMatch
    }

    private struct WikidataMatchRecord: Codable {
        let key: LiveTVChannelLogoKey
        let nameKey: String
        let value: LiveTVWikidataLogoMatch
    }

    private struct StoredWikidataMatch: Equatable {
        let nameKey: String
        let value: LiveTVWikidataLogoMatch
    }

    private struct ModifiedRecord: Codable {
        let key: LiveTVChannelLogoKey
        let at: Int64
    }

    private struct Document: Codable {
        var version = LiveTVChannelLogoStore.version
        var overrides: [OverrideRecord] = []
        var matches: [MatchRecord] = []
        var networks: [TMDbNetworkLogo] = []
        var accessWasEnabled = false
        /// When each channel's choice last changed, in milliseconds. Decides which device wins in iCloud.
        var modified: [ModifiedRecord]? = nil
        var wikidataMatches: [WikidataMatchRecord]? = nil
    }

    /// Everything stored for one channel, flat so that a 55,000-channel store decodes in a fraction of the time the nested form takes.
    private struct Row: Codable {
        var s: Int
        var c: String
        var m: Int64?
        var o: LiveTVChannelLogoOverride?
        var n: String?
        /// 0 network, 1 show, 2 none.
        var k: Int?
        var i: Int?
        var p: String?
        var d: Double?
        var wn: String?
        /// 0 logo, 1 none.
        var wk: Int?
        var wq: String?
        var wf: String?
        var wd: Double?
        /// The day (since 1970) a complete lineup last listed the channel; decides when its records may be dropped.
        var l: Int?
    }

    /// What was measured of one image URL: a guide icon's pixel size and/or a logo's colour. Measured once, kept for good.
    private struct ImageRow: Codable {
        var u: String
        /// Pixel width; -1 for a vector, 0 for an icon that could not be measured. Absent when the size was never measured.
        var w: Int?
        var h: Int?
        /// 0 colour, 1 black/white/grey, 2 could not be measured. Absent when the colour was never measured.
        var c: Int?
        var l: Int?
    }

    private struct ImageMeasure: Equatable {
        var size: StoredIconSize?
        var colour: Int8?
        var lastSeen: Int?
    }

    private enum StoredIconSize: Equatable {
        case vector
        case raster(width: Int, height: Int)
        case unmeasurable
    }

    private struct CompactDocument: Codable {
        var version = LiveTVChannelLogoStore.version
        var sources: [String] = []
        var rows: [Row] = []
        var networks: [TMDbNetworkLogo] = []
        var accessWasEnabled = false
        var images: [ImageRow]? = nil
    }

    private struct Snapshot {
        var overrides: [LiveTVChannelLogoKey: LiveTVChannelLogoOverride]
        var matches: [LiveTVChannelLogoKey: StoredMatch]
        var wikidata: [LiveTVChannelLogoKey: StoredWikidataMatch]
        var modified: [LiveTVChannelLogoKey: Int64]
        var lastSeen: [LiveTVChannelLogoKey: Int]
        var images: [URL: ImageMeasure]
        var networks: [TMDbNetworkLogo]
        var accessWasEnabled: Bool

        func encoded() throws -> Data {
            var sourceIndex: [String: Int] = [:]
            var rows: [Int: [Row]] = [:]
            var document = CompactDocument(accessWasEnabled: accessWasEnabled)
            func index(_ key: LiveTVChannelLogoKey) -> Int {
                if let known = sourceIndex[key.sourceID] { return known }
                document.sources.append(key.sourceID)
                sourceIndex[key.sourceID] = document.sources.count - 1
                return document.sources.count - 1
            }
            var byKey: [LiveTVChannelLogoKey: Row] = [:]
            byKey.reserveCapacity(matches.count)
            func row(_ key: LiveTVChannelLogoKey) -> Row { byKey[key] ?? Row(s: index(key), c: key.channelID, m: modified[key], l: lastSeen[key]) }
            for (key, value) in overrides { var r = row(key); r.o = value; byKey[key] = r }
            for (key, stored) in matches {
                var r = row(key)
                r.n = stored.nameKey
                switch stored.value {
                case .network(let id, let path): r.k = 0; r.i = id; r.p = path
                case .show(let id, let path): r.k = 1; r.i = id; r.p = path
                case .none(let date): r.k = 2; r.d = date.timeIntervalSince1970
                }
                byKey[key] = r
            }
            for (key, stored) in wikidata {
                var r = row(key)
                r.wn = stored.nameKey
                switch stored.value {
                case .logo(let qid, let file): r.wk = 0; r.wq = qid; r.wf = file
                case .none(let date): r.wk = 1; r.wd = date.timeIntervalSince1970
                }
                byKey[key] = r
            }
            for r in byKey.values { rows[r.s, default: []].append(r) }
            document.rows = rows.keys.sorted().flatMap { source in
                (rows[source] ?? []).sorted { $0.c < $1.c }
            }
            document.networks = networks.sorted { $0.networkID < $1.networkID }
            document.images = images.map { url, measure in
                var row = ImageRow(u: url.absoluteString, l: measure.lastSeen)
                switch measure.size {
                case .vector?: row.w = -1; row.h = 0
                case .raster(let width, let height)?: row.w = width; row.h = height
                case .unmeasurable?: row.w = 0; row.h = 0
                case nil: break
                }
                row.c = measure.colour.map(Int.init)
                return row
            }.sorted { $0.u < $1.u }
            return try JSONEncoder().encode(document)
        }
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var overrides: [LiveTVChannelLogoKey: LiveTVChannelLogoOverride] = [:]
    private var matches: [LiveTVChannelLogoKey: StoredMatch] = [:]
    private var networks: [Int: TMDbNetworkLogo] = [:]
    private var accessWasEnabled = false
    private var modified: [LiveTVChannelLogoKey: Int64] = [:]
    private var wikidataMatches: [LiveTVChannelLogoKey: StoredWikidataMatch] = [:]
    private var lastSeen: [LiveTVChannelLogoKey: Int] = [:]
    private var images: [URL: ImageMeasure] = [:]
    private let now: @Sendable () -> Date
    private let writeDelay: TimeInterval
    private let batchDelay: TimeInterval
    private let writeQueue = DispatchQueue(label: "com.plozz.livetv.logo-store", qos: .utility)
    private var dirty = false
    private var writeScheduled = false
    private var scheduleToken = 0
    private var scheduledDeadline: DispatchTime?
    private var writes = 0
    private var wroteOnMain = false
    /// Files written so far; changes within one settle period share a write.
    var writeCount: Int { lock.withLock { writes } }
    /// Whether the latest write ran on the main thread. It never should.
    var lastWriteWasOnMainThread: Bool { lock.withLock { wroteOnMain } }
    /// `false` when a file exists but could not be read, so an empty store is not mistaken
    /// for "the user removed everything" and published to iCloud.
    public private(set) var isLoaded = true
    /// Called after a local change, so iCloud sync can publish it.
    public var onLocalChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }
    private var changeHandler: (@Sendable () -> Void)?

    /// Posted on the main thread after changes from another device are applied.
    public static let didApplyRemoteChangesNotification = Notification.Name("LiveTVChannelLogoStoreDidApplyRemoteChanges")

    /// Changes are saved on a background queue: a user's after `writeDelay`, a machine's after `batchDelay`.
    public init(
        fileURL: URL, writeDelay: TimeInterval = 3, batchDelay: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.writeDelay = writeDelay
        self.batchDelay = batchDelay
        self.now = now
        if FileManager.default.fileExists(atPath: fileURL.path) { isLoaded = false }
        if let data = try? Data(contentsOf: fileURL), load(data) { isLoaded = true }
    }

    private func load(_ data: Data) -> Bool {
        struct Header: Decodable { let version: Int }
        guard let version = (try? JSONDecoder().decode(Header.self, from: data))?.version else { return false }
        if version == Self.version, let document = try? JSONDecoder().decode(CompactDocument.self, from: data) {
            for row in document.rows where document.sources.indices.contains(row.s) {
                let key = LiveTVChannelLogoKey(sourceID: document.sources[row.s], channelID: row.c)
                if let value = row.o { overrides[key] = value }
                if let nameKey = row.n, let kind = row.k {
                    switch kind {
                    case 0: if let id = row.i, let path = row.p { matches[key] = StoredMatch(nameKey: nameKey, value: .network(id: id, filePath: path)) }
                    case 1: if let id = row.i, let path = row.p { matches[key] = StoredMatch(nameKey: nameKey, value: .show(id: id, filePath: path)) }
                    default: matches[key] = StoredMatch(nameKey: nameKey, value: .none(directoryDate: Date(timeIntervalSince1970: row.d ?? 0)))
                    }
                }
                if let nameKey = row.wn, let kind = row.wk {
                    if kind == 0, let qid = row.wq, let file = row.wf {
                        wikidataMatches[key] = StoredWikidataMatch(nameKey: nameKey, value: .logo(qid: qid, file: file))
                    } else if kind == 1 {
                        wikidataMatches[key] = StoredWikidataMatch(
                            nameKey: nameKey, value: .none(directoryDate: Date(timeIntervalSince1970: row.wd ?? 0)))
                    }
                }
                if let stamp = row.m { modified[key] = stamp }
                if let day = row.l { lastSeen[key] = day }
            }
            for row in document.images ?? [] {
                guard let url = URL(string: row.u) else { continue }
                var measure = ImageMeasure(lastSeen: row.l)
                if let width = row.w {
                    measure.size = width < 0 ? .vector : width == 0 ? .unmeasurable : .raster(width: width, height: row.h ?? 0)
                }
                measure.colour = row.c.map { Int8($0) }
                images[url] = measure
            }
            networks = Dictionary(document.networks.map { ($0.networkID, $0) }, uniquingKeysWith: { $1 })
            accessWasEnabled = document.accessWasEnabled
            return true
        }
        if version == 1, let document = try? JSONDecoder().decode(Document.self, from: data) {
            modified = Dictionary((document.modified ?? []).map { ($0.key, $0.at) }, uniquingKeysWith: { $1 })
            wikidataMatches = Dictionary(
                (document.wikidataMatches ?? []).map { ($0.key, StoredWikidataMatch(nameKey: $0.nameKey, value: $0.value)) },
                uniquingKeysWith: { $1 })
            overrides = Dictionary(document.overrides.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            matches = Dictionary(document.matches.map { ($0.key, StoredMatch(nameKey: $0.nameKey, value: $0.value)) }, uniquingKeysWith: { $1 })
            networks = Dictionary(document.networks.map { ($0.networkID, $0) }, uniquingKeysWith: { $1 })
            accessWasEnabled = document.accessWasEnabled
            return true
        }
        return false
    }

    /// A file beside the store's, for small derived data that is final for a key (see ``LiveTVChannelLogoService/storedRegionalLogoCounts(inputKey:)``).
    func sidecarURL(named name: String) -> URL { fileURL.deletingLastPathComponent().appendingPathComponent(name) }

    /// `Application Support/Plozz/LiveTVLogos/channel-logos.json`.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Plozz", isDirectory: true)
            .appendingPathComponent("LiveTVLogos", isDirectory: true)
            .appendingPathComponent("channel-logos.json")
    }

    /// A user-entered URL if it is http or https, has no credentials and is not too long.
    public static func validatedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumURLLength,
              let url = URL(string: trimmed), isValid(url) else { return nil }
        return url
    }

    public static func isValid(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.absoluteString.count <= maximumURLLength,
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    // MARK: Reads

    public func override(for key: LiveTVChannelLogoKey) -> LiveTVChannelLogoOverride? {
        lock.withLock { overrides[key] }
    }

    /// The stored automatic result for a channel, if it was made under the same name.
    /// With no `nameKey` the name is not checked, for a channel already on screen.
    public func match(for key: LiveTVChannelLogoKey, nameKey: String?) -> LiveTVChannelLogoMatch? {
        lock.withLock {
            guard let stored = matches[key], nameKey == nil || stored.nameKey == nameKey else { return nil }
            return stored.value
        }
    }

    public func match(for identity: LiveTVChannelLogoIdentity) -> LiveTVChannelLogoMatch? {
        match(for: identity.key, nameKey: identity.nameKey)
    }

    /// The stored Wikidata result for a channel, if it was made under the same name.
    public func wikidataMatch(for key: LiveTVChannelLogoKey, nameKey: String?) -> LiveTVWikidataLogoMatch? {
        lock.withLock {
            guard let stored = wikidataMatches[key], nameKey == nil || stored.nameKey == nameKey else { return nil }
            return stored.value
        }
    }

    public func wikidataMatch(for identity: LiveTVChannelLogoIdentity) -> LiveTVWikidataLogoMatch? {
        wikidataMatch(for: identity.key, nameKey: identity.nameKey)
    }

    public func network(id: Int) -> TMDbNetworkLogo? {
        lock.withLock { networks[id] }
    }

    /// Whether `key` has a choice that automatic matching must not replace.
    public func hasOverride(_ key: LiveTVChannelLogoKey) -> Bool {
        lock.withLock { overrides[key] != nil }
    }

    // MARK: Writes

    /// Returns `false` when the URL is not acceptable. The file is written later, off the calling thread (see ``flush()``).
    @discardableResult
    public func setOverride(_ value: LiveTVChannelLogoOverride?, for key: LiveTVChannelLogoKey) -> Bool {
        if case .url(let url)? = value, !Self.isValid(url) { return false }
        commit(urgent: true) {
            guard overrides[key] != value else { return [] }
            overrides[key] = value
            return [key]
        }
        return true
    }

    /// A "no match" outcome carries the date of the list it was made from. A date that went through the file (a double rounded to
    /// its 1970 grid) or iCloud (milliseconds) differs from the original by a rounding error, so equal outcomes are compared to a second.
    public static func isSameInstant(_ stored: Date, orLater listDate: Date) -> Bool {
        stored.addingTimeInterval(1) >= listDate
    }

    private static func isSameOutcome(_ old: StoredMatch?, _ new: StoredMatch) -> Bool {
        guard let old, old.nameKey == new.nameKey else { return false }
        if case .none(let a) = old.value, case .none(let b) = new.value { return abs(a.timeIntervalSince(b)) < 1 }
        return old.value == new.value
    }

    private static func isSameOutcome(_ old: StoredWikidataMatch?, _ new: StoredWikidataMatch) -> Bool {
        guard let old, old.nameKey == new.nameKey else { return false }
        if case .none(let a) = old.value, case .none(let b) = new.value { return abs(a.timeIntervalSince(b)) < 1 }
        return old.value == new.value
    }

    @discardableResult
    public func recordMatches(_ updates: [LiveTVChannelLogoIdentity: LiveTVChannelLogoMatch]) -> Bool {
        guard !updates.isEmpty else { return true }
        commit {
            var changed = Set<LiveTVChannelLogoKey>()
            for (identity, value) in updates {
                let stored = StoredMatch(nameKey: identity.nameKey, value: value)
                guard !Self.isSameOutcome(matches[identity.key], stored) else { continue }
                matches[identity.key] = stored
                changed.insert(identity.key)
            }
            return changed
        }
        return true
    }

    @discardableResult
    public func recordWikidataMatches(_ updates: [LiveTVChannelLogoIdentity: LiveTVWikidataLogoMatch]) -> Bool {
        guard !updates.isEmpty else { return true }
        commit {
            var changed = Set<LiveTVChannelLogoKey>()
            for (identity, value) in updates {
                let stored = StoredWikidataMatch(nameKey: identity.nameKey, value: value)
                guard !Self.isSameOutcome(wikidataMatches[identity.key], stored) else { continue }
                wikidataMatches[identity.key] = stored
                changed.insert(identity.key)
            }
            return changed
        }
        return true
    }

    @discardableResult
    public func recordNetwork(_ logo: TMDbNetworkLogo) -> Bool {
        commit {
            guard networks[logo.networkID] != logo else { return [] }
            networks[logo.networkID] = logo
            return nil
        }
        return true
    }

    /// Forgets "no match" results so those channels are tried again. Called when the
    /// network list refreshes. Returns how many were cleared.
    @discardableResult
    public func clearNegativeMatches() -> Int {
        var cleared = 0
        commit {
            let stale = matches.filter { if case .none = $0.value.value { true } else { false } }.keys
            cleared = stale.count
            for key in stale { matches[key] = nil }
            return Set(stale)
        }
        return cleared
    }

    /// Records the TMDB access state and reports whether it just changed from disabled to
    /// enabled, in which case "no match" results are cleared as well.
    @discardableResult
    public func noteAccess(enabled: Bool) -> Bool {
        var becameEnabled = false
        commit {
            guard accessWasEnabled != enabled else { return [] }
            becameEnabled = enabled
            accessWasEnabled = enabled
            guard enabled else { return nil }
            let stale = matches.filter { if case .none = $0.value.value { true } else { false } }.keys
            for key in stale { matches[key] = nil }
            return stale.isEmpty ? nil : Set(stale)
        }
        return becameEnabled
    }

    /// Removes every choice stored for a source that no longer exists.
    @discardableResult
    public func removeSource(_ sourceID: String) -> Bool {
        commit(urgent: true) {
            var changed = Set<LiveTVChannelLogoKey>()
            for key in overrides.keys where key.sourceID == sourceID { overrides[key] = nil; changed.insert(key) }
            for key in matches.keys where key.sourceID == sourceID { matches[key] = nil; changed.insert(key) }
            for key in wikidataMatches.keys where key.sourceID == sourceID { wikidataMatches[key] = nil; changed.insert(key) }
            for key in lastSeen.keys where key.sourceID == sourceID { lastSeen[key] = nil }
            return changed
        }
        return true
    }

    /// A record that no complete lineup has listed for this many days may be dropped (see ``noteCompleteLineup(channelIDsBySource:iconURLs:)``).
    public static let lineupGraceDays = 30
    /// A record is stamped again only when its stamp is this old, so a daily launch does not rewrite the file.
    static let restampDays = 7

    /// Maintenance after a **complete** successful lineup fetch, the only safe moment to forget anything. Every record whose channel
    /// is in the lineup is stamped with today's date (at most weekly); a record of a channel the lineup does not list is
    /// dropped only if no complete lineup has listed it for ``lineupGraceDays``, and one that has never been stamped starts its grace
    /// period now. A cached, partial or filtered lineup must never be passed (a country filter that hides most channels, or the few
    /// rows saved from the last session, would otherwise delete matches that took hours to make); filters that hide channels are
    /// covered by the grace period. Only sources named in `channelIDsBySource` are touched, and the user's overrides are always kept.
    /// Guide-icon measurements are aged the same way against `iconURLs`. Not a user change: nothing is stamped for iCloud or published.
    /// Returns how many channels lost their records.
    @discardableResult
    public func noteCompleteLineup(channelIDsBySource: [String: Set<String>], iconURLs: Set<URL> = []) -> Int {
        lock.withLock {
            let today = Int(now().timeIntervalSince1970 / 86_400)
            var changed = false
            var stale: [LiveTVChannelLogoKey] = []
            func visit(_ key: LiveTVChannelLogoKey) {
                guard let ids = channelIDsBySource[key.sourceID] else { return }
                let seen = lastSeen[key]
                if ids.contains(key.channelID) {
                    if seen == nil || today - seen! >= Self.restampDays { lastSeen[key] = today; changed = true }
                } else if let seen {
                    if today - seen > Self.lineupGraceDays { stale.append(key) }
                } else {
                    lastSeen[key] = today
                    changed = true
                }
            }
            for key in matches.keys { visit(key) }
            for key in wikidataMatches.keys where matches[key] == nil { visit(key) }
            for key in stale {
                matches[key] = nil
                wikidataMatches[key] = nil
                lastSeen[key] = nil
                if overrides[key] == nil { modified[key] = nil }
            }
            if !iconURLs.isEmpty {
                for (url, measure) in images where measure.size != nil {
                    if iconURLs.contains(url) {
                        if measure.lastSeen == nil || today - measure.lastSeen! >= Self.restampDays {
                            images[url]?.lastSeen = today
                            changed = true
                        }
                    } else if let seen = measure.lastSeen {
                        if today - seen > Self.lineupGraceDays {
                            images[url]?.size = nil
                            if images[url]?.colour == nil { images[url] = nil }
                            changed = true
                        }
                    } else {
                        images[url]?.lastSeen = today
                        changed = true
                    }
                }
            }
            if changed || !stale.isEmpty { markDirty() }
            return stale.count
        }
    }

    // MARK: Image measurements

    /// The measured size of a guide icon: `nil` when it was never measured, `.some(nil)` when it could not be measured.
    public func iconSize(for url: URL) -> LiveTVLogoSize?? {
        lock.withLock {
            switch images[url]?.size {
            case nil: nil
            case .vector?: .some(.vector)
            case .raster(let width, let height)?: .some(.raster(width: width, height: height))
            case .unmeasurable?: .some(nil)
            }
        }
    }

    public func recordIconSizes(_ sizes: [URL: LiveTVLogoSize?]) {
        guard !sizes.isEmpty else { return }
        lock.withLock {
            var changed = false
            for (url, size) in sizes {
                let stored: StoredIconSize
                switch size {
                case .vector?: stored = .vector
                case .raster(let width, let height)?: stored = .raster(width: width, height: height)
                case nil: stored = .unmeasurable
                }
                guard images[url]?.size != stored else { continue }
                images[url, default: ImageMeasure()].size = stored
                if images[url]?.lastSeen == nil { images[url]?.lastSeen = Int(now().timeIntervalSince1970 / 86_400) }
                changed = true
            }
            if changed { markDirty() }
        }
    }

    /// Whether a logo image is black/white/grey (`true`) or coloured (`false`); `nil` when never measured, `.some(nil)` when it
    /// could not be measured.
    public func isMonochrome(_ url: URL) -> Bool?? {
        lock.withLock {
            switch images[url]?.colour {
            case nil: nil
            case 0?: .some(false)
            case 1?: .some(true)
            default: .some(nil)
            }
        }
    }

    public func recordMonochrome(_ value: Bool?, for url: URL) {
        lock.withLock {
            let code: Int8 = value == nil ? 2 : value! ? 1 : 0
            guard images[url]?.colour != code else { return }
            images[url, default: ImageMeasure()].colour = code
            markDirty()
        }
    }

    /// Applies `change`, which returns the channels whose choices changed (they are stamped and published), `[]` when nothing
    /// changed, or `nil` for a change that is saved but concerns no channel (network details, access state).
    private func commit(urgent: Bool = false, _ change: () -> Set<LiveTVChannelLogoKey>?) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard let changedKeys = change() else {
                markDirty(urgent: urgent)
                return nil
            }
            guard !changedKeys.isEmpty else { return nil }
            let stamp = Int64(now().timeIntervalSince1970 * 1_000)
            for key in changedKeys {
                modified[key] = overrides[key] != nil || matches[key] != nil || wikidataMatches[key] != nil ? stamp : nil
            }
            markDirty(urgent: urgent)
            return changeHandler
        }
        handler?()
    }

    // MARK: Background writing

    /// A user's own change (an override, a change from another device) is saved `writeDelay` after it; machine-made changes
    /// (matches, measurements, lineup maintenance) wait `batchDelay`, so a matching pass that records every few seconds writes the
    /// file at most once per `batchDelay`, plus once when the pass ends (``requestWrite()``). Must be called with `lock` held.
    private func markDirty(urgent: Bool = false) {
        dirty = true
        let deadline = DispatchTime.now() + (urgent ? writeDelay : batchDelay)
        if writeScheduled {
            guard urgent, let scheduledDeadline, deadline < scheduledDeadline else { return }
            scheduleToken += 1
        }
        writeScheduled = true
        scheduledDeadline = deadline
        let token = scheduleToken
        writeQueue.asyncAfter(deadline: deadline) { [self] in performWrite(scheduledWith: token) }
    }

    /// Called when a matching pass ends: saves what it recorded soon instead of at the end of the batch window. Does nothing when
    /// nothing changed.
    public func requestWrite() {
        lock.withLock { if dirty { markDirty(urgent: true) } }
    }

    /// Writes any unsaved change now and returns when it is on disk. For leaving the foreground, terminating, and tests;
    /// never call it on the main thread during interaction.
    public func flush() {
        writeQueue.sync { performWrite(scheduledWith: nil) }
    }

    /// Runs on `writeQueue` only. A write scheduled before a ``flush()`` that already saved its changes does nothing.
    private func performWrite(scheduledWith token: Int?) {
        let snapshot: Snapshot? = lock.withLock {
            if let token, token != scheduleToken { return nil }
            scheduleToken += 1
            writeScheduled = false
            scheduledDeadline = nil
            guard dirty else { return nil }
            dirty = false
            return Snapshot(
                overrides: overrides, matches: matches, wikidata: wikidataMatches, modified: modified,
                lastSeen: lastSeen, images: images,
                networks: Array(networks.values), accessWasEnabled: accessWasEnabled)
        }
        guard let snapshot else { return }
        var written = false
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try snapshot.encoded().write(to: fileURL, options: .atomic)
            written = true
        } catch {
            // The change stays in memory; the next change schedules another attempt.
            lock.withLock { dirty = true }
        }
        if written {
            lock.withLock {
                writes += 1
                // An explicit ``flush()`` from the main thread runs inline there by design; only scheduled writes are judged.
                if token != nil { wroteOnMain = Thread.isMainThread }
            }
        }
    }

    // MARK: iCloud

    /// Keys and values of every synced record, for the sync layer.
    struct SyncItem {
        let key: LiveTVChannelLogoKey
        let override: LiveTVChannelLogoOverride?
        let match: (nameKey: String, value: LiveTVChannelLogoMatch)?
        let wikidata: (nameKey: String, value: LiveTVWikidataLogoMatch)?
        let modified: Int64
        let networkPath: String?
    }

    func syncSnapshot() -> [SyncItem] {
        lock.withLock {
            Set(overrides.keys).union(matches.keys).union(wikidataMatches.keys).map { key in
                var path: String?
                if case .tmdbNetwork(let id)? = overrides[key] { path = networks[id]?.filePath }
                return SyncItem(
                    key: key, override: overrides[key], match: matches[key].map { ($0.nameKey, $0.value) },
                    wikidata: wikidataMatches[key].map { ($0.nameKey, $0.value) },
                    modified: modified[key] ?? 0, networkPath: path
                )
            }
        }
    }

    /// Adopts a record from another device. The newer change wins; an equal timestamp takes the remote one.
    /// An empty record removes the channel's choices. Returns whether anything changed.
    @discardableResult
    func applySynced(
        key: LiveTVChannelLogoKey, override: LiveTVChannelLogoOverride?, networkPath: String?,
        match: (nameKey: String, value: LiveTVChannelLogoMatch)?,
        wikidata: (nameKey: String, value: LiveTVWikidataLogoMatch)?, modifiedAt: Int64?
    ) -> Bool {
        lock.withLock {
            if let modifiedAt, let local = modified[key], local > modifiedAt,
               overrides[key] != nil || matches[key] != nil || wikidataMatches[key] != nil { return false }
            let newMatch = match.map { StoredMatch(nameKey: $0.nameKey, value: $0.value) }
            let newWikidata = wikidata.map { StoredWikidataMatch(nameKey: $0.nameKey, value: $0.value) }
            var changed = overrides[key] != override || matches[key] != newMatch || wikidataMatches[key] != newWikidata
            overrides[key] = override
            matches[key] = newMatch
            wikidataMatches[key] = newWikidata
            if case .tmdbNetwork(let id)? = override, let networkPath, networks[id]?.filePath == nil {
                networks[id] = TMDbNetworkLogo(networkID: id, name: "", originCountry: nil, filePath: networkPath)
                changed = true
            }
            modified[key] = override != nil || newMatch != nil || newWikidata != nil ? modifiedAt : nil
            if changed { markDirty(urgent: true) }
            return changed
        }
    }
}


/// FNV-1a over UTF-8, stable across launches (``Hasher`` is seeded per process), for keys that are saved to disk.
struct LiveTVStableHash {
    private(set) var value: UInt64 = 0xcbf29ce484222325

    mutating func add(_ text: String) {
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        value = (value ^ 0xff) &* 0x100000001b3
    }
}
