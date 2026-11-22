import CoreModels
import Foundation
import Observation

public enum LiveTVLineupStoreError: Error, Equatable, Sendable {
    case invalidStoredValue
    case encodingFailed
}

public protocol LiveTVLineupStoring: Sendable {
    func load() throws -> (lineup: LiveTVLineup, inventory: LiveTVLineupInventory)?
    func save(lineup: LiveTVLineup) throws
    func save(inventory: LiveTVLineupInventory) throws
}

/// One profile's lineup and the last inventory of the provider's list, in `UserDefaults` under the profile's namespace like the
/// other Live TV preferences. Device-local. An unreadable stored value is reported and never overwritten.
public final class LiveTVLineupStore: LiveTVLineupStoring, @unchecked Sendable {
    static let baseKey = "com.plozz.liveTV.lineup"
    private let defaults: UserDefaults
    private let lineupKey: String
    private let inventoryKey: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        lineupKey = SettingsKey.scoped(Self.baseKey, namespace: namespace)
        inventoryKey = SettingsKey.scoped(Self.baseKey + ".inventory", namespace: namespace)
    }

    public func load() throws -> (lineup: LiveTVLineup, inventory: LiveTVLineupInventory)? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = defaults.object(forKey: lineupKey) else { return nil }
        guard let data = stored as? Data, let lineup = try? JSONDecoder().decode(LiveTVLineup.self, from: data) else {
            throw LiveTVLineupStoreError.invalidStoredValue
        }
        // The inventory is a cache of the provider's list: an unreadable one is only a missing one.
        let inventory = (defaults.data(forKey: inventoryKey)).flatMap { try? JSONDecoder().decode(LiveTVLineupInventory.self, from: $0) }
        return (lineup, inventory ?? .empty)
    }

    public func save(lineup: LiveTVLineup) throws {
        guard let data = try? JSONEncoder().encode(lineup) else { throw LiveTVLineupStoreError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }
        if let stored = defaults.object(forKey: lineupKey),
           !(stored is Data && (try? JSONDecoder().decode(LiveTVLineup.self, from: stored as! Data)) != nil) {
            throw LiveTVLineupStoreError.invalidStoredValue
        }
        defaults.set(data, forKey: lineupKey)
    }

    public func save(inventory: LiveTVLineupInventory) throws {
        guard let data = try? JSONEncoder().encode(inventory) else { throw LiveTVLineupStoreError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }
        defaults.set(data, forKey: inventoryKey)
    }
}

/// The chips of one sheet section.
public struct LiveTVLineupChip: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case place, group, adult }
    public let id: String
    public let kind: Kind
    public let title: String
    public let count: Int
    public let isOn: Bool
}

public struct LiveTVLineupSection: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable { case countries, regions, withoutCountry, adult }
    public var id: String { kind.rawValue }
    public let kind: Kind
    public let title: String
    public let chips: [LiveTVLineupChip]
}

public enum LiveTVLineupKeep: String, CaseIterable, Sendable {
    case favouritesAndRecents, liveEvents, searchLeftOut
}

/// My Channels: the saved lineup, the sheet's draft of it, and the inventory the sheet counts from.
/// Nothing changes until `apply()`; `discard()` (Back) drops the draft.
@MainActor @Observable
public final class LiveTVLineupState {
    public private(set) var applied: LiveTVLineup
    public private(set) var inventory: LiveTVLineupInventory
    public private(set) var draft: LiveTVLineup
    /// Channels the lineup left out of the last import, by name, for Search.
    public private(set) var leftOut: [LiveTVLeftOutChannel] = []
    /// Set when the saved lineup could not be read or written; the standard lineup stays in force and is not saved over it.
    public private(set) var storeFailed = false
    @ObservationIgnored private let store: (any LiveTVLineupStoring)?
    @ObservationIgnored private var lowercasedLeftOut: [String] = []

    public init(store: (any LiveTVLineupStoring)?) {
        self.store = store
        var lineup = LiveTVLineup.standard
        var inventory = LiveTVLineupInventory.empty
        var failed = false
        if let store {
            do {
                if let stored = try store.load() { (lineup, inventory) = stored }
            } catch {
                failed = true
            }
        }
        #if DEBUG
        if let override = Self.debugOverride { lineup = override }
        #endif
        applied = lineup
        draft = lineup
        self.inventory = inventory
        storeFailed = failed
    }

    #if DEBUG
    /// `-PlozzLiveTVDebugCountryPrefixes CA,US` loads only those countries (the earlier design-test filter, now a lineup).
    private static var debugOverride: LiveTVLineup? {
        debugLineup(from: UserDefaults.standard.string(forKey: "PlozzLiveTVDebugCountryPrefixes") ?? "")
    }

    /// The lineup of a comma-separated country list; "UK" is the United Kingdom (ISO "GB").
    nonisolated static func debugLineup(from raw: String) -> LiveTVLineup? {
        let codes = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }.map { $0 == "UK" ? "GB" : $0 }
        return codes.isEmpty ? nil : LiveTVLineup(placeIDs: Set(codes), removedGroupIDs: [], keepsLiveEvents: false)
    }
    #endif

    // MARK: The sheet

    public var hasChanges: Bool { draft != applied }
    public var draftCount: Int { inventory.keptCount(by: draft) }
    public var totalCount: Int { inventory.total }

    public func beginEditing() { draft = applied }
    public func discard() { draft = applied }

    public func togglePlace(_ id: String) {
        if draft.placeIDs.contains(id) { draft.placeIDs.remove(id) } else { draft.placeIDs.insert(id) }
    }

    public func toggleGroup(_ id: String) {
        if draft.removedGroupIDs.contains(id) { draft.removedGroupIDs.remove(id) } else { draft.removedGroupIDs.insert(id) }
    }

    public func toggleKeep(_ keep: LiveTVLineupKeep) {
        switch keep {
        case .favouritesAndRecents: draft.keepsFavouritesAndRecents.toggle()
        case .liveEvents: draft.keepsLiveEvents.toggle()
        case .searchLeftOut: draft.searchesLeftOut.toggle()
        }
    }

    public func isOn(_ keep: LiveTVLineupKeep) -> Bool {
        switch keep {
        case .favouritesAndRecents: draft.keepsFavouritesAndRecents
        case .liveEvents: draft.keepsLiveEvents
        case .searchLeftOut: draft.searchesLeftOut
        }
    }

    /// The sections for a search text, as the mockup's `lineupLayout`: countries and regions sorted by count, then (without a
    /// search) the groups without a country, then Adult. Adult is shown but cannot be switched on: no Parental PIN prompt is
    /// wired into this page yet, and Adult stays off (see `isAdultAvailable`).
    public func sections(query: String = "") -> [LiveTVLineupSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ title: String) -> Bool { needle.isEmpty || title.lowercased().contains(needle) }
        let countries = inventory.codeCounts.map { (code: $0.key, count: $0.value, title: LiveTVLineupPlace.title(ofCode: $0.key)) }
            .filter { matches($0.title) }
            .sorted { ($0.count, $1.title) > ($1.count, $0.title) }
            .map { LiveTVLineupChip(id: $0.code, kind: .place, title: $0.title, count: $0.count, isOn: draft.placeIDs.contains($0.code)) }
        let regions = LiveTVLineupPlace.regions.compactMap { region -> LiveTVLineupChip? in
            let count = inventory.count(ofRegion: region)
            guard count > 0, matches(region.title) else { return nil }
            return LiveTVLineupChip(id: region.id, kind: .place, title: region.title, count: count, isOn: draft.placeIDs.contains(region.id))
        }.sorted { ($0.count, $1.title) > ($1.count, $0.title) }
        let groups = needle.isEmpty ? inventory.groups.map {
            LiveTVLineupChip(id: $0.id, kind: .group, title: $0.id.isEmpty ? String(localized: "Everything Else") : $0.title, count: $0.count, isOn: draft.keepsGroup($0.id))
        } : []
        let adult = needle.isEmpty && inventory.adultCount > 0 ? [
            LiveTVLineupChip(id: "adult", kind: .adult, title: "Adult", count: inventory.adultCount, isOn: draft.includesAdult)
        ] : []
        return [
            LiveTVLineupSection(kind: .countries, title: "Countries", chips: countries),
            LiveTVLineupSection(kind: .regions, title: "Regions", chips: regions),
            LiveTVLineupSection(kind: .withoutCountry, title: "Without a Country", chips: groups),
            LiveTVLineupSection(kind: .adult, title: "Adult", chips: adult)
        ].filter { !$0.chips.isEmpty }
    }

    /// Adult can be listed but not turned on until a Parental PIN prompt guards it.
    public var isAdultAvailable: Bool { false }

    public func toggle(_ chip: LiveTVLineupChip) {
        switch chip.kind {
        case .place: togglePlace(chip.id)
        case .group: toggleGroup(chip.id)
        case .adult: break
        }
    }

    /// Saves the draft. Returns whether the lineup changed (a new import is then due). A failed save changes nothing.
    @discardableResult
    public func apply() -> Bool {
        guard draft != applied else { return false }
        if let store {
            do { try store.save(lineup: draft) } catch {
                storeFailed = true
                return false
            }
        }
        applied = draft
        return true
    }

    // MARK: The import

    /// Records what the last import found. Counts every row of the provider's list, loaded or not.
    public func record(inventory: LiveTVLineupInventory, leftOut: [LiveTVLeftOutChannel]) {
        self.inventory = inventory
        self.leftOut = leftOut
        lowercasedLeftOut = leftOut.map { $0.name.lowercased() }
        try? store?.save(inventory: inventory)
    }

    /// Left-out channels whose name contains the text (name index only; at most `limit`).
    public func leftOutChannels(matching query: String, limit: Int = 30) -> [LiveTVLeftOutChannel] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard applied.searchesLeftOut, needle.count >= 2 else { return [] }
        var found: [LiveTVLeftOutChannel] = []
        for index in lowercasedLeftOut.indices where lowercasedLeftOut[index].contains(needle) {
            found.append(leftOut[index])
            if found.count == limit { break }
        }
        return found
    }

    /// A saved favourite filter whose country is no longer in the lineup, as the mockup words it.
    public func missingCountryNotice(forTagIDs tagIDs: [String]) -> String? {
        for id in tagIDs {
            guard let code = Self.countryCode(forTagID: id), !applied.keeps(code: code) else { continue }
            return String(localized: "\(LiveTVLineupPlace.shortTitle(ofCode: code)) isn’t in My Channels — add it with Set Up My Channels")
        }
        return nil
    }

    private static func countryCode(forTagID id: String) -> String? {
        LiveTVChannelTagging.countryTitleByCode.first { LiveTVFilterTagCatalog.tagID($0.value) == id }?.key
    }
}
