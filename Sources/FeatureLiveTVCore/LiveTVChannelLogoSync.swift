import Foundation

/// The iCloud form of a channel's logo choices: data only, never image bytes. A record exists while
/// the channel has an override or a match; when both are gone the record is deleted, which is
/// how a reset to Automatic reaches the other devices.
public struct LiveTVChannelLogoSyncRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// Largest accepted payload; real records are a few hundred bytes.
    public static let maximumBytes = 8 * 1_024

    public struct Override: Codable, Equatable, Sendable {
        /// `tmdb` (a network id and its logo path) or `url`.
        public var kind: String
        public var networkID: Int?
        public var filePath: String?
        public var url: String?
    }

    public struct Match: Codable, Equatable, Sendable {
        /// `tmdb` (a network and logo path) or `none` (nothing matched).
        public var kind: String
        public var nameKey: String
        public var networkID: Int?
        public var filePath: String?
        /// Milliseconds of the network list a `none` result used.
        public var directoryDate: Int64?
    }

    /// A Wikidata result, tagged by source so it never reads as a TMDB one.
    public struct WikidataMatch: Codable, Equatable, Sendable {
        /// `logo` or `none`.
        public var kind: String
        public var nameKey: String
        public var qid: String?
        public var file: String?
        public var directoryDate: Int64?
    }

    public var version = LiveTVChannelLogoSyncRecord.currentVersion
    public var sourceID: String
    public var channelID: String
    /// Milliseconds since 1970; the newer record wins.
    public var modifiedAt: Int64
    public var override: Override?
    public var match: Match?
    public var wikidata: WikidataMatch?
}

/// Maps the store to iCloud records named `logo:<base64url source>:<base64url channel>`.
public enum LiveTVChannelLogoSync {
    /// Beyond this many channels, overrides come first, then network matches, then "no match" results.
    public static let maximumRecords = 5_000
    static let maximumRecordNameBytes = 240

    public static func recordName(for key: LiveTVChannelLogoKey) -> String? {
        let name = "logo:\(encode(key.sourceID)):\(encode(key.channelID))"
        return name.utf8.count <= maximumRecordNameBytes ? name : nil
    }

    public static func key(forRecordName name: String) -> LiveTVChannelLogoKey? {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "logo",
              let source = decode(String(parts[1])), !source.isEmpty,
              let channel = decode(String(parts[2])), !channel.isEmpty else { return nil }
        let key = LiveTVChannelLogoKey(sourceID: source, channelID: channel)
        return recordName(for: key) == name ? key : nil
    }

    /// Every record this device would publish, by record name. `nil` while the store could not be
    /// read, so the caller keeps what iCloud already has instead of deleting it.
    public static func capture(_ store: LiveTVChannelLogoStore) -> [String: Data]? {
        guard store.isLoaded else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var ranked: [(rank: Int, modified: Int64, name: String, data: Data)] = []
        for item in store.syncSnapshot() {
            guard let name = recordName(for: item.key) else { continue }
            var record = LiveTVChannelLogoSyncRecord(
                sourceID: item.key.sourceID, channelID: item.key.channelID, modifiedAt: item.modified
            )
            switch item.override {
            case .tmdbNetwork(let id)?:
                // Without the logo path the other device could not draw it.
                guard let path = item.networkPath else { continue }
                record.override = .init(kind: "tmdb", networkID: id, filePath: path)
            case .url(let url)?:
                record.override = .init(kind: "url", url: url.absoluteString)
            case nil:
                break
            }
            if let match = item.match {
                switch match.value {
                case .network(let id, let path):
                    record.match = .init(kind: "tmdb", nameKey: match.nameKey, networkID: id, filePath: path)
                case .show(let id, let path):
                    record.match = .init(kind: "tmdbShow", nameKey: match.nameKey, networkID: id, filePath: path)
                case .none(let date):
                    record.match = .init(
                        kind: "none", nameKey: match.nameKey, directoryDate: Int64(date.timeIntervalSince1970 * 1_000)
                    )
                }
            }
            if let wikidata = item.wikidata {
                switch wikidata.value {
                case .logo(let qid, let file):
                    record.wikidata = .init(kind: "logo", nameKey: wikidata.nameKey, qid: qid, file: file)
                case .none(let date):
                    record.wikidata = .init(
                        kind: "none", nameKey: wikidata.nameKey, directoryDate: Int64(date.timeIntervalSince1970 * 1_000)
                    )
                }
            }
            guard record.override != nil || record.match != nil || record.wikidata != nil,
                  let data = try? encoder.encode(record), data.count <= LiveTVChannelLogoSyncRecord.maximumBytes else {
                continue
            }
            let positive = record.match?.kind == "tmdb" || record.wikidata?.kind == "logo"
            let rank = record.override != nil ? 0 : (positive ? 1 : 2)
            ranked.append((rank, item.modified, name, data))
        }
        ranked.sort { ($0.rank, -$0.modified, $0.name) < ($1.rank, -$1.modified, $1.name) }
        return Dictionary(uniqueKeysWithValues: ranked.prefix(maximumRecords).map { ($0.name, $0.data) })
    }

    /// Applies records from iCloud. A `nil` value removes that channel's choices. Unknown versions,
    /// unknown kinds, oversize or mismatched records are ignored. Returns whether anything changed.
    @discardableResult
    public static func apply(_ changes: [String: Data?], to store: LiveTVChannelLogoStore) -> Bool {
        var changed = false
        for (name, value) in changes {
            guard let key = key(forRecordName: name) else { continue }
            guard let data = value else {
                changed = store.applySynced(
                    key: key, override: nil, networkPath: nil, match: nil, wikidata: nil, modifiedAt: nil
                ) || changed
                continue
            }
            guard data.count <= LiveTVChannelLogoSyncRecord.maximumBytes,
                  let record = try? JSONDecoder().decode(LiveTVChannelLogoSyncRecord.self, from: data),
                  record.version == LiveTVChannelLogoSyncRecord.currentVersion,
                  record.sourceID == key.sourceID, record.channelID == key.channelID,
                  let parsed = parse(record) else { continue }
            changed = store.applySynced(
                key: key, override: parsed.override, networkPath: parsed.networkPath,
                match: parsed.match, wikidata: parsed.wikidata, modifiedAt: record.modifiedAt
            ) || changed
        }
        if changed {
            NotificationCenter.default.post(name: LiveTVChannelLogoStore.didApplyRemoteChangesNotification, object: store)
        }
        return changed
    }

    private static func parse(_ record: LiveTVChannelLogoSyncRecord) -> (
        override: LiveTVChannelLogoOverride?, networkPath: String?,
        match: (nameKey: String, value: LiveTVChannelLogoMatch)?,
        wikidata: (nameKey: String, value: LiveTVWikidataLogoMatch)?
    )? {
        var override: LiveTVChannelLogoOverride?
        var networkPath: String?
        if let stored = record.override {
            switch stored.kind {
            case "tmdb":
                guard let id = stored.networkID, let path = stored.filePath, validPath(path) else { return nil }
                override = .tmdbNetwork(id)
                networkPath = path
            case "url":
                guard let text = stored.url, let url = LiveTVChannelLogoStore.validatedURL(text) else { return nil }
                override = .url(url)
            default:
                return nil
            }
        }
        var match: (nameKey: String, value: LiveTVChannelLogoMatch)?
        if let stored = record.match {
            switch stored.kind {
            case "tmdb":
                guard let id = stored.networkID, let path = stored.filePath, validPath(path) else { return nil }
                match = (stored.nameKey, .network(id: id, filePath: path))
            case "tmdbShow":
                guard let id = stored.networkID, let path = stored.filePath, validPath(path) else { return nil }
                match = (stored.nameKey, .show(id: id, filePath: path))
            case "none":
                guard let millis = stored.directoryDate else { return nil }
                match = (stored.nameKey, .none(directoryDate: Date(timeIntervalSince1970: Double(millis) / 1_000)))
            default:
                return nil
            }
        }
        var wikidata: (nameKey: String, value: LiveTVWikidataLogoMatch)?
        if let stored = record.wikidata {
            switch stored.kind {
            case "logo":
                guard let qid = stored.qid, qid.hasPrefix("Q"), qid.utf8.count <= 16,
                      let file = stored.file, validFile(file) else { return nil }
                wikidata = (stored.nameKey, .logo(qid: qid, file: file))
            case "none":
                guard let millis = stored.directoryDate else { return nil }
                wikidata = (stored.nameKey, .none(directoryDate: Date(timeIntervalSince1970: Double(millis) / 1_000)))
            default:
                return nil
            }
        }
        guard override != nil || match != nil || wikidata != nil else { return nil }
        return (override, networkPath, match, wikidata)
    }

    /// A logo path is joined onto TMDB's image host, so it must stay a plain path.
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("//") && path.utf8.count <= 256
            && !path.contains("?") && !path.contains("#") && !path.contains("..")
    }

    /// A Commons file name is joined onto a Commons URL, so it stays a plain name.
    private static func validFile(_ file: String) -> Bool {
        !file.isEmpty && file.utf8.count <= 240 && !file.contains("/") && !file.contains("?") && !file.contains("#")
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> String? {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64 + padding).flatMap { String(data: $0, encoding: .utf8) }
    }
}
