import CoreModels
import Foundation

/// DEBUG aid for auditing tags: with the launch argument `-PlozzLiveTVMetadataAudit`, every lineup read appends one header line and
/// one JSON line per row READ (kept or not) to `Documents/live-tv-metadata-audit.jsonl` in the app container. Each line holds the
/// group title, name, number, the country/region the lineup read and the rule that read it, the verdict and its reason, and, for
/// kept rows, the tags the tag index would derive. Never a URL, token or stream id: ids are not written at all, and any word that
/// looks like a URL is replaced by `[url]`. The file stops at `byteCap` (60 MB).
///
/// The same read also writes the raw INPUT as a `LiveTVGuideSnapshot` (`Documents/live-tv-snapshot/`): `channels.jsonl` (every row
/// read, before the cut) and `manifest.json`; `LiveTVGuideSnapshotWriter.writeGuide` adds `guide.jsonl` from the guide store.
final class LiveTVLineupAudit: @unchecked Sendable {
    static let launchArgument = "-PlozzLiveTVMetadataAudit"
    static let defaultByteCap = 60 * 1_024 * 1_024
    /// The file is emptied once per process, by the first read.
    private nonisolated(unsafe) static var truncatedThisLaunch = false
    private static let lock = NSLock()

    private let file: URL
    private let byteCap: Int
    private var lines: [String] = []
    private var bytes = 0
    private var truncated = false
    private var tagger = LiveTVChannelTagging()
    private let snapshotDirectory: URL?
    private var channelLines: [String] = []
    private var channelBytes = 0
    private var channelRows = 0
    private var channelsTruncated = false
    /// A launch-argument audit does its work after the list is published (`finishInBackground`): reading the rows costs a
    /// copy of their fields, not the tag derivation and the encoding of every row on the mapping path.
    let defersWork: Bool
    private var pending: [PendingRow] = []

    private struct AuditedRow: LiveTVLineupRow {
        let lineupID: String
        let lineupName: String
        let lineupNumber: String?
        let lineupGuideID: String?
        let lineupGuideName: String?
        let lineupIsRadio: Bool
        let lineupCountry: String?
        let lineupGroups: [String]
        let lineupEventGroups: [String]

        init(_ row: some LiveTVLineupRow) {
            lineupID = row.lineupID
            lineupName = row.lineupName
            lineupNumber = row.lineupNumber
            lineupGuideID = row.lineupGuideID
            lineupGuideName = row.lineupGuideName
            lineupIsRadio = row.lineupIsRadio
            lineupCountry = row.lineupCountry
            lineupGroups = row.lineupGroups
            lineupEventGroups = row.lineupEventGroups
        }
    }

    private struct PendingRow {
        let row: AuditedRow
        let scopedID: String
        let placement: LiveTVLineupClassifier.Placement
        let rule: String
        let kept: Bool
        let reason: String
    }

    /// `nil` unless this is a DEBUG build launched with `-PlozzLiveTVMetadataAudit`.
    convenience init?(source: String, arguments: [String] = ProcessInfo.processInfo.arguments) {
        #if DEBUG
        guard arguments.contains(Self.launchArgument),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        self.init(
            source: source, file: documents.appendingPathComponent("live-tv-metadata-audit.jsonl"),
            snapshotDirectory: documents.appendingPathComponent(LiveTVGuideSnapshot.directoryName), launchFile: true,
            defersWork: true)
        #else
        return nil
        #endif
    }

    init(
        source: String, file: URL, byteCap: Int = LiveTVLineupAudit.defaultByteCap, snapshotDirectory: URL? = nil,
        launchFile: Bool = false, defersWork: Bool = false
    ) {
        self.defersWork = defersWork
        self.file = file
        self.snapshotDirectory = snapshotDirectory
        self.byteCap = byteCap
        Self.lock.lock()
        let reset = launchFile ? !Self.truncatedThisLaunch : true
        if launchFile { Self.truncatedThisLaunch = true }
        if reset { try? Data().write(to: file) }
        Self.lock.unlock()
        self.bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        self.header = source
    }

    private var header: String

    func begin(rows: Int) {
        append(object(["read": header, "rows": rows, "at": ISO8601DateFormatter().string(from: Date())]))
    }

    func record(
        _ row: some LiveTVLineupRow, scopedID: String, placement: LiveTVLineupClassifier.Placement, rule: String, kept: Bool, reason: String
    ) {
        if defersWork {
            pending.append(PendingRow(row: AuditedRow(row), scopedID: scopedID, placement: placement, rule: rule, kept: kept, reason: reason))
            return
        }
        write(row, scopedID: scopedID, placement: placement, rule: rule, kept: kept, reason: reason)
    }

    private func write(
        _ row: some LiveTVLineupRow, scopedID: String, placement: LiveTVLineupClassifier.Placement, rule: String, kept: Bool, reason: String
    ) {
        var entry: [String: Any] = [
            "group": Self.scrub(row.lineupGroups.first ?? ""), "name": Self.scrub(row.lineupName),
            "verdict": kept ? "kept" : "dropped", "reason": reason, "rule": rule
        ]
        if let number = row.lineupNumber { entry["number"] = Self.scrub(number) }
        switch placement {
        case .country(let code): entry["country"] = code
        case .region(let id): entry["region"] = id
        case .group(let id): entry["noCountryGroup"] = Self.scrub(id)
        case .adult: entry["adult"] = true
        }
        if kept { entry["tags"] = derivedTags(of: row) }
        append(object(entry))
        recordChannel(row, scopedID: scopedID, isAdult: placement == .adult)
    }

    private func recordChannel(_ row: some LiveTVLineupRow, scopedID: String, isAdult: Bool) {
        channelRows += 1
        guard snapshotDirectory != nil else { return }
        let clean = LiveTVGuideSnapshot.clean
        let channel = LiveTVGuideSnapshot.Channel(
            stableID: clean(scopedID), number: row.lineupNumber.map(clean), name: clean(row.lineupName), groups: row.lineupGroups.map(clean),
            epgID: row.lineupGuideID.map(clean), tvgName: row.lineupGuideName.map(clean), country: row.lineupCountry.map(clean),
            kind: LiveTVChannelKind.classify(name: row.lineupName, groups: row.lineupGroups).rawValue, isRadio: row.lineupIsRadio,
            isAdult: isAdult)
        guard let data = try? LiveTVGuideSnapshot.makeEncoder().encode(channel), let line = String(data: data, encoding: .utf8) else { return }
        guard channelBytes + line.utf8.count + 1 <= byteCap else { channelsTruncated = true; return }
        channelBytes += line.utf8.count + 1
        channelLines.append(line)
    }

    private func writeSnapshot() {
        guard let directory = snapshotDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = channelLines.isEmpty ? "" : channelLines.joined(separator: "\n") + "\n"
        try? text.write(to: directory.appendingPathComponent(LiveTVGuideSnapshot.channelsFileName), atomically: true, encoding: .utf8)
        // A guide captured earlier in the launch stays in the manifest.
        LiveTVGuideSnapshotWriter.lockManifest()
        defer { LiveTVGuideSnapshotWriter.unlockManifest() }
        var manifest = LiveTVGuideSnapshotWriter.manifest(in: directory)
            ?? LiveTVGuideSnapshot.Manifest(capturedAt: Date(), sourceKind: header, channelCount: 0)
        manifest.capturedAt = Date()
        manifest.sourceKind = header
        manifest.channelCount = channelRows
        manifest.truncated = channelsTruncated
        LiveTVGuideSnapshotWriter.write(manifest, in: directory)
        channelLines = []
    }

    /// Writes what was recorded on a utility task, so the lineup read does not wait for it.
    func finishInBackground() {
        guard defersWork else { return }
        Task.detached(priority: .utility) { self.finish() }
    }

    /// Writes what was recorded; the last line says so when the cap cut it short.
    func finish() {
        let rows = pending
        pending = []
        for item in rows {
            write(item.row, scopedID: item.scopedID, placement: item.placement, rule: item.rule, kept: item.kept, reason: item.reason)
        }
        writeSnapshot()
        if truncated { lines.append(object(["truncated": true])) }
        guard !lines.isEmpty, let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        lines = []
    }

    // MARK: Lines

    private func append(_ line: String) {
        let size = line.utf8.count + 1
        guard bytes + size <= byteCap - 64 else { truncated = true; return }
        bytes += size
        lines.append(line)
    }

    private func object(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{}"
    }

    /// The tag titles the tag index derives for the row, by section: genre, network, sport, language, country, channels (4K, Live
    /// Events, 24/7, Radio, Pay-per-view).
    private func derivedTags(of row: some LiveTVLineupRow) -> [String: [String]] {
        let groups = row.lineupGroups
        let channel = LiveTVPrototypeChannel(
            id: "audit", number: 0, name: row.lineupName, category: groups.first ?? "Live", symbol: "tv", accent: 0, source: .iptv, tagline: "",
            country: row.lineupCountry, groups: groups.isEmpty ? nil : groups, tags: IPTVChannelName.split(row.lineupName, groups: groups).tags,
            eventSlot: LiveTVEventSlotClassifier.classify(name: row.lineupName, groups: row.lineupEventGroups))
        var slots: [Int] = []
        tagger.storedSlots(for: channel, measured: { _ in nil }, into: &slots)
        var result: [String: [String]] = [:]
        for slot in slots {
            guard let tag = Self.tagByID[LiveTVChannelTagging.vocabulary[slot]] else { continue }
            result[tag.section.rawValue, default: []].append(tag.title)
        }
        return result
    }

    private static let tagByID: [String: LiveTVFilterTag] = {
        var table: [String: LiveTVFilterTag] = [:]
        for tag in LiveTVFilterTagCatalog.all where table[tag.id] == nil { table[tag.id] = tag }
        return table
    }()

    static func scrub(_ text: String) -> String { LiveTVGuideSnapshot.clean(text) }
}

/// Writes the guide half of the snapshot, and reads and writes its manifest.
enum LiveTVGuideSnapshotWriter {
    /// `Documents/live-tv-snapshot/` when the app was launched (DEBUG) with `-PlozzLiveTVMetadataAudit`.
    static func launchDirectory(arguments: [String] = processArguments) -> URL? {
        #if DEBUG
        guard arguments.contains(LiveTVLineupAudit.launchArgument) else { return nil }
        if let testingDirectory { return testingDirectory }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent(LiveTVGuideSnapshot.directoryName)
        #else
        return nil
        #endif
    }

    /// Tests only: stand-ins for the process's launch arguments and for `Documents/live-tv-snapshot/`.
    nonisolated(unsafe) static var testingArguments: [String]?
    nonisolated(unsafe) static var testingDirectory: URL?
    static var processArguments: [String] { testingArguments ?? ProcessInfo.processInfo.arguments }

    /// The manifest is read, changed and written by the lineup audit and the guide capture, which can run at the same time.
    private static let manifestLock = NSLock()
    static func lockManifest() { manifestLock.lock() }
    static func unlockManifest() { manifestLock.unlock() }

    /// `guide.jsonl`: the XMLTV channels and the programmes that start within 48 hours of `now` (capped at 60 MB).
    static func writeGuide(
        guideChannels: [String: [String]], programmes: [LiveTVPrototypeProgram], now: Date, directory: URL,
        byteCap: Int = LiveTVLineupAudit.defaultByteCap
    ) {
        let clean = LiveTVGuideSnapshot.clean
        let window = DateInterval(start: now, duration: LiveTVGuideSnapshot.guideWindow)
        var records = guideChannels.sorted { $0.key < $1.key }.map {
            LiveTVGuideSnapshot.GuideRecord(type: "channel", id: clean($0.key), displayNames: $0.value.map(clean))
        }
        for programme in programmes.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) })
        where programme.start >= window.start && programme.start < window.end {
            records.append(LiveTVGuideSnapshot.GuideRecord(
                type: "programme", channel: clean(programme.channelID), start: programme.start, end: programme.end,
                title: clean(programme.title), subTitle: programme.subtitle.isEmpty ? nil : clean(programme.subtitle),
                categories: programme.details?.categories.map(clean), episode: programme.details?.episode.map(clean)))
        }
        writeGuide(records: records, now: now, directory: directory, byteCap: byteCap)
    }

    private static let reimportLock = NSLock()
    private nonisolated(unsafe) static var reimportTaken = false
    /// DEBUG, launch argument `-PlozzLiveTVForceGuideReimport`: true once per launch, so the first guide preparation drops the
    /// saved guide's validators and downloads and re-imports the XMLTV (which writes `guide-stations.jsonl`).
    static func takesForcedReimport(arguments: [String] = processArguments) -> Bool {
        #if DEBUG
        guard arguments.contains(forcedReimportArgument) else { return false }
        reimportLock.lock()
        defer { reimportLock.unlock() }
        if reimportTaken { return false }
        reimportTaken = true
        return true
        #else
        return false
        #endif
    }

    private nonisolated(unsafe) static var stationsDumped = false
    /// DEBUG, `-PlozzLiveTVMetadataAudit` with `-PlozzLiveTVForceGuideReimport`: true until `guide-stations.jsonl` has been written
    /// in this launch. While true, the guide index skips every shortcut that would avoid reading the XMLTV (reusing the saved guide,
    /// a 304, an unchanged digest), so the metadata pass that writes the file really runs.
    static func stationDumpOwed(arguments: [String] = processArguments) -> Bool {
        #if DEBUG
        guard arguments.contains(LiveTVLineupAudit.launchArgument), arguments.contains(forcedReimportArgument) else { return false }
        reimportLock.lock()
        defer { reimportLock.unlock() }
        return !stationsDumped
        #else
        return false
        #endif
    }
    static let forcedReimportArgument = "-PlozzLiveTVForceGuideReimport"
    static func resetStationDumpForTesting() {
        reimportLock.lock(); stationsDumped = false; reimportTaken = false; reimportLock.unlock()
    }

    private static let stationLock = NSLock()
    private nonisolated(unsafe) static var fullStationIDs = Set<String>()
    /// The ids of the last full XMLTV read (DEBUG station dump only), folded; for the EPG probe.
    static func recordFullStationIDs(_ ids: Set<String>) { stationLock.lock(); fullStationIDs = ids; stationLock.unlock() }
    static var knowsFullXMLTV: Bool { stationLock.lock(); defer { stationLock.unlock() }; return !fullStationIDs.isEmpty }
    static func isInFullXMLTV(_ id: String) -> Bool { stationLock.lock(); defer { stationLock.unlock() }; return fullStationIDs.contains(id) }

    /// `guide-stations.jsonl` (DEBUG): every `<channel>` the FULL XMLTV declares (id, display names, programmes it carries), then
    /// the ids that have programmes but no declaration. No icons, no URLs. Written from the metadata pass at guide import,
    /// before the importer keeps only the stations the lineup asks for.
    static func writeStations(declared: [String: [String]], undeclared: Set<String>, programmeCounts: [String: Int], directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = LiveTVGuideSnapshot.makeEncoder()
        struct Station: Encodable { var id: String; var displayNames: [String]; var programmes: Int; var declared: Bool }
        var lines: [String] = []
        func append(_ station: Station) {
            if let data = try? encoder.encode(station), let line = String(data: data, encoding: .utf8) { lines.append(line) }
        }
        recordFullStationIDs(Set(declared.keys).union(undeclared).map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) })
        let clean = LiveTVGuideSnapshot.clean
        for id in declared.keys.sorted() {
            append(Station(id: clean(id), displayNames: (declared[id] ?? []).map(clean), programmes: programmeCounts[id] ?? 0, declared: true))
        }
        for id in undeclared.sorted() {
            append(Station(id: clean(id), displayNames: [], programmes: programmeCounts[id] ?? 0, declared: false))
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: directory.appendingPathComponent("guide-stations.jsonl"), atomically: true, encoding: .utf8)
        reimportLock.lock(); stationsDumped = true; reimportLock.unlock()
        let withProgrammes = declared.keys.filter { (programmeCounts[$0] ?? 0) > 0 }.count
            + undeclared.filter { (programmeCounts[$0] ?? 0) > 0 }.count
        LiveTVDiagnosticLog.notice("LIVE_TV event=guideStationsDumped declared=\(declared.count) withProgrammes=\(withProgrammes)")
    }

    /// `guide.jsonl` from records already read from the guide store (`type` "channel" and "programme"), capped at 60 MB.
    static func writeGuide(
        records: [LiveTVGuideSnapshot.GuideRecord], now: Date, directory: URL, byteCap: Int = LiveTVLineupAudit.defaultByteCap
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = DateInterval(start: now, duration: LiveTVGuideSnapshot.guideWindow)
        let encoder = LiveTVGuideSnapshot.makeEncoder()
        var bytes = 0
        var truncated = false
        var lines: [String] = []
        for record in records {
            guard let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8) else { continue }
            guard bytes + line.utf8.count + 1 <= byteCap else { truncated = true; break }
            bytes += line.utf8.count + 1
            lines.append(line)
        }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: directory.appendingPathComponent(LiveTVGuideSnapshot.guideFileName), atomically: true, encoding: .utf8)
        manifestLock.lock()
        defer { manifestLock.unlock() }
        var manifest = manifest(in: directory) ?? LiveTVGuideSnapshot.Manifest(capturedAt: now, sourceKind: "unknown", channelCount: 0)
        manifest.guideChannelCount = records.filter { $0.type == "channel" }.count
        manifest.programmeCount = records.filter { $0.type == "programme" }.count
        manifest.guideWindowStart = window.start
        manifest.guideWindowEnd = window.end
        manifest.truncated = manifest.truncated || truncated
        write(manifest, in: directory)
    }

    private static let captureLock = NSLock()
    private nonisolated(unsafe) static var captureRunning = false
    /// One guide capture runs at a time; a request made while one runs is dropped (the saved guide it reads is the same).
    static func beginCapture() -> Bool {
        captureLock.lock()
        defer { captureLock.unlock() }
        if captureRunning { return false }
        captureRunning = true
        return true
    }
    static func endCapture() {
        captureLock.lock()
        captureRunning = false
        captureLock.unlock()
    }

    /// Reads the 48 hours from `now` out of the provider's saved guide and writes them. Nil, writing nothing, when the provider
    /// keeps no saved guide; otherwise the records written.
    static func captureGuide(
        from provider: any ServerLiveTVProviding, now: Date, directory: URL, byteCap: Int = LiveTVLineupAudit.defaultByteCap
    ) async -> [LiveTVGuideSnapshot.GuideRecord]? {
        guard let records = try? await provider.liveTVGuideSnapshotRecords(
            from: now, to: now.addingTimeInterval(LiveTVGuideSnapshot.guideWindow)) else { return nil }
        writeGuide(records: records, now: now, directory: directory, byteCap: byteCap)
        return records
    }

    static func manifest(in directory: URL) -> LiveTVGuideSnapshot.Manifest? {
        (try? Data(contentsOf: directory.appendingPathComponent(LiveTVGuideSnapshot.manifestFileName)))
            .flatMap { try? LiveTVGuideSnapshot.makeDecoder().decode(LiveTVGuideSnapshot.Manifest.self, from: $0) }
    }

    static func write(_ manifest: LiveTVGuideSnapshot.Manifest, in directory: URL) {
        guard let data = try? LiveTVGuideSnapshot.makeEncoder().encode(manifest) else { return }
        try? data.write(to: directory.appendingPathComponent(LiveTVGuideSnapshot.manifestFileName), options: .atomic)
    }
}
