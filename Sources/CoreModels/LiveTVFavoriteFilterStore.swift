import Foundation

/// A saved Live TV favourite filter: an ordered list of tag identifiers that a channel must all carry.
/// Its name is derived from the tags unless the person typed one, which is stored in `name`. Filters saved before names existed
/// decode with no `name`.
public struct LiveTVFavoriteFilter: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var tagIDs: [String]
    /// The name the person typed; nil while the filter is named after its tags.
    public var name: String?

    public init(id: String = UUID().uuidString, tagIDs: [String], name: String? = nil) {
        self.id = id
        self.tagIDs = tagIDs
        self.name = name
    }

    /// Whether both filters require the same tags, in any order.
    public func hasSameTags(as other: [String]) -> Bool {
        tagIDs.count == other.count && Set(tagIDs) == Set(other)
    }
}

public protocol LiveTVFavoriteFilterStoring: Sendable {
    func load() throws -> [LiveTVFavoriteFilter]
    func save(_ filters: [LiveTVFavoriteFilter]) throws
    /// The filters, with `seed` added once if it has never been offered to this profile (see the file store).
    func load(seeding seed: LiveTVFavoriteFilter) throws -> [LiveTVFavoriteFilter]
    /// The tags every new favourite filter starts with ("Save as Default"); none until the person saves some.
    func loadDefaultTagIDs() throws -> [String]
    func saveDefaultTagIDs(_ tagIDs: [String]) throws
}

extension LiveTVFavoriteFilterStoring {
    public func load(seeding seed: LiveTVFavoriteFilter) throws -> [LiveTVFavoriteFilter] { try load() }
    public func loadDefaultTagIDs() throws -> [String] { [] }
    public func saveDefaultTagIDs(_ tagIDs: [String]) throws {}
}

public enum LiveTVFavoriteFilterStoreError: Error, Equatable, Sendable {
    case invalidStoredValue
    case decodingFailed
    case encodingFailed
}

/// Persists one profile's favourite filters in `UserDefaults`, under the profile's namespace like the other Live TV
/// preferences. It is device-local: it does not travel with the portable Live TV sync records.
///
/// As `LiveTVPreferencesStore` does, it reports an unreadable stored value instead of treating it as empty, and
/// `save(_:)` refuses to replace one.
public final class LiveTVFavoriteFilterStore: LiveTVFavoriteFilterStoring, @unchecked Sendable {
    static let baseKey = "com.plozz.liveTV.favoriteFilters"
    static let defaultTagsBaseKey = "com.plozz.liveTV.favoriteFilterDefaultTags"

    private let defaults: UserDefaults
    private let key: String
    private let defaultTagsKey: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.baseKey, namespace: namespace)
        defaultTagsKey = SettingsKey.scoped(Self.defaultTagsBaseKey, namespace: namespace)
    }

    public func loadDefaultTagIDs() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = defaults.object(forKey: defaultTagsKey) else { return [] }
        guard let data = stored as? Data else { throw LiveTVFavoriteFilterStoreError.invalidStoredValue }
        do { return try JSONDecoder().decode([String].self, from: data) } catch { throw LiveTVFavoriteFilterStoreError.decodingFailed }
    }

    public func saveDefaultTagIDs(_ tagIDs: [String]) throws {
        let encoded: Data
        do { encoded = try JSONEncoder().encode(tagIDs) } catch { throw LiveTVFavoriteFilterStoreError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }
        defaults.set(encoded, forKey: defaultTagsKey)
    }

    public func load() throws -> [LiveTVFavoriteFilter] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func save(_ filters: [LiveTVFavoriteFilter]) throws {
        let encoded: Data
        do { encoded = try JSONEncoder().encode(filters) } catch { throw LiveTVFavoriteFilterStoreError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }
        if defaults.object(forKey: key) != nil { _ = try loadLocked() }
        defaults.set(encoded, forKey: key)
    }

    /// The saved filters, with `seed` appended the first time it is offered to this profile and then never again: a marker per profile
    /// and seed records the offer, so a filter the person deletes or edits stays as they left it. Not added when a filter with the same
    /// id or the same tags already exists. An unreadable stored value is reported and nothing is written.
    public func load(seeding seed: LiveTVFavoriteFilter) throws -> [LiveTVFavoriteFilter] {
        lock.lock()
        defer { lock.unlock() }
        var filters = try loadLocked()
        let marker = "\(key).seeded.\(seed.id)"
        guard !defaults.bool(forKey: marker) else { return filters }
        if !filters.contains(where: { $0.id == seed.id || $0.hasSameTags(as: seed.tagIDs) }) {
            let updated = filters + [seed]
            guard let encoded = try? JSONEncoder().encode(updated) else { throw LiveTVFavoriteFilterStoreError.encodingFailed }
            defaults.set(encoded, forKey: key)
            filters = updated
        }
        defaults.set(true, forKey: marker)
        return filters
    }

    private func loadLocked() throws -> [LiveTVFavoriteFilter] {
        guard let stored = defaults.object(forKey: key) else { return [] }
        guard let data = stored as? Data else { throw LiveTVFavoriteFilterStoreError.invalidStoredValue }
        do { return try JSONDecoder().decode([LiveTVFavoriteFilter].self, from: data) } catch { throw LiveTVFavoriteFilterStoreError.decodingFailed }
    }
}
