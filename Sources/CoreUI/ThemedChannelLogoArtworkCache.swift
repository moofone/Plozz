#if canImport(UIKit)
import Foundation

/// The prepared-artwork identity a row supplies: the logo URL and the provider's dark-background flag, the same pair that
/// keys ``PreparedChannelLogoStore``. The theme is supplied separately at lookup (the row's current dark/light).
public struct ThemedChannelLogoIdentity: Hashable, Sendable {
    public let url: URL
    public let providerRequestsDarkBackground: Bool

    public init(url: URL, providerRequestsDarkBackground: Bool) {
        self.url = url
        self.providerRequestsDarkBackground = providerRequestsDarkBackground
    }
}

/// Bounded in-memory cache of both theme variants of a channel logo, filled only by the explicit sync writer API below.
///
/// Display (``ChannelLogoArtwork`` with `preparedArtworkCache` set) calls only ``prepared(for:theme:)``: one dictionary lookup
/// under a lock, returning a finished value or `nil`. It never decodes, analyses, hashes pixel data, reads or writes disk, fetches
/// or starts a task, so a theme switch is just a second lookup of the pair already built.
///
/// Treatment precedence matches ``ChannelLogoExtractionLoader``: a plain logo is `prepare(analysis:...)` per theme; a matched network
/// logo draws, per theme, the listed variant with the best readable share (ties keep the listed order) and never falls back to text.
public final class ThemedChannelLogoArtworkCache: @unchecked Sendable {
    public static let shared = ThemedChannelLogoArtworkCache(capacity: 4_000)

    struct Pair {
        let dark: ChannelLogoExtraction.Prepared
        let light: ChannelLogoExtraction.Prepared

        func prepared(theme: ChannelLogoExtraction.Theme) -> ChannelLogoExtraction.Prepared {
            theme == .dark ? dark : light
        }
    }

    /// What a writer call did.
    public enum WriteOutcome: Equatable, Sendable {
        /// Both variants were built (from `analysis` and prepare) and persisted.
        case built
        /// Both variants came back from the persisted prepared store; no decode or pixel work.
        case restoredFromStore
        /// Input was missing or undecodable; nothing was cached.
        case unavailable
    }

    /// Entries kept; the oldest written are dropped first, except logos a current station mark needs (``require(_:)``), which are
    /// never dropped, so the count can exceed `capacity` by exactly the required logos.
    public let capacity: Int
    private let lock = NSLock()
    private var pairs: [ThemedChannelLogoIdentity: Pair] = [:]
    private var insertionOrder: [ThemedChannelLogoIdentity] = []
    private var required = Set<ThemedChannelLogoIdentity>()
    /// After a sweep that could not get under capacity (everything left is required), the count at which to sweep again.
    private var nextSweepAt = 0
    private var probes = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    // MARK: Read (render path)

    /// The finished artwork for `theme`, or `nil` on a miss. O(1), synchronous, no side effects.
    func prepared(for identity: ThemedChannelLogoIdentity, theme: ChannelLogoExtraction.Theme) -> ChannelLogoExtraction.Prepared? {
        lock.withLock { pairs[identity]?.prepared(theme: theme) }
    }

    public func contains(_ identity: ThemedChannelLogoIdentity) -> Bool {
        lock.withLock { pairs[identity] != nil }
    }

    public var count: Int { lock.withLock { pairs.count } }

    /// How many times the prepared store was probed on disk for a pair; the once-per-logo bound is tested through this.
    public var preparedStoreProbeCount: Int { lock.withLock { probes } }

    public func removeAll() {
        lock.withLock {
            pairs.removeAll()
            insertionOrder.removeAll()
            nextSweepAt = 0
        }
    }

    /// One logo a current station mark draws; `variants` is the matched network logo's listed variants, `nil` for a plain logo.
    public struct RequiredLogo: Sendable {
        public let identity: ThemedChannelLogoIdentity
        public let variants: [URL]?

        public init(identity: ThemedChannelLogoIdentity, variants: [URL]?) {
            self.identity = identity
            self.variants = variants
        }
    }

    /// Declares logos current station marks need, in addition to those already declared (accounts accumulate until the process ends). Neither this cache nor the prepared
    /// store's disk trim drops one of them, so a capacity can never turn a logo whose artwork is final back into a name.
    public func require(_ logos: [RequiredLogo]) {
        var keys = Set<String>()
        for logo in logos {
            for theme in [ChannelLogoExtraction.Theme.dark, .light] {
                keys.insert(PreparedChannelLogoStore.key(
                    url: logo.identity.url, variants: logo.variants,
                    providerRequestsDarkBackground: logo.identity.providerRequestsDarkBackground, theme: theme))
            }
        }
        PreparedChannelLogoStore.protect(keys: keys)
        lock.withLock { required.formUnion(logos.map(\.identity)) }
    }

    // MARK: Write (sync only; call off the main thread)

    /// Builds and caches both themes of a plain logo. Persisted prepared values are reused first; otherwise the bytes are
    /// analysed once and both themes derived from that one analysis, then persisted. `logoData` runs only when needed.
    /// `knownUnprepared` skips the disk probe when the caller just found nothing persisted.
    @discardableResult
    public func store(identity: ThemedChannelLogoIdentity, knownUnprepared: Bool = false, logoData: () -> Data?) -> WriteOutcome {
        let flag = identity.providerRequestsDarkBackground
        let darkKey = PreparedChannelLogoStore.key(url: identity.url, variants: nil, providerRequestsDarkBackground: flag, theme: .dark)
        let lightKey = PreparedChannelLogoStore.key(url: identity.url, variants: nil, providerRequestsDarkBackground: flag, theme: .light)
        if !knownUnprepared, let pair = restored(darkKey: darkKey, lightKey: lightKey) {
            insert(pair, for: identity)
            return .restoredFromStore
        }
        guard let data = logoData(), let analysis = ChannelLogoExtraction.analyze(data: data) else { return .unavailable }
        let pair = Pair(
            dark: ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: flag, theme: .dark),
            light: ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: flag, theme: .light))
        PreparedChannelLogoStore.write(pair.dark, key: darkKey)
        PreparedChannelLogoStore.write(pair.light, key: lightKey)
        insert(pair, for: identity)
        return .built
    }

    /// Builds and caches both themes of a matched network logo whose default URL is `identity.url`. `variants` lists the variant URLs
    /// (the default first, at most five are considered); each variant is analysed once and serves both themes.
    @discardableResult
    public func storeNetworkLogo(
        identity: ThemedChannelLogoIdentity, variants: [URL], knownUnprepared: Bool = false, variantData: (URL) -> Data?
    ) -> WriteOutcome {
        let flag = identity.providerRequestsDarkBackground
        let listed = Array(variants.prefix(5))
        let darkKey = PreparedChannelLogoStore.key(url: identity.url, variants: variants, providerRequestsDarkBackground: flag, theme: .dark)
        let lightKey = PreparedChannelLogoStore.key(url: identity.url, variants: variants, providerRequestsDarkBackground: flag, theme: .light)
        if !knownUnprepared, let pair = restored(darkKey: darkKey, lightKey: lightKey) {
            insert(pair, for: identity)
            return .restoredFromStore
        }
        let analyses = listed.compactMap { variantData($0).flatMap { ChannelLogoExtraction.analyze(data: $0) } }
        guard !analyses.isEmpty else { return .unavailable }
        func best(_ theme: ChannelLogoExtraction.Theme) -> ChannelLogoExtraction.Prepared? {
            ChannelLogoExtraction.chosenNetworkVariant(among: analyses.map {
                ChannelLogoExtraction.prepare(analysis: $0, providerRequestsDarkBackground: flag, theme: theme)
            })
        }
        guard let dark = best(.dark), let light = best(.light) else { return .unavailable }
        let pair = Pair(dark: dark, light: light)
        PreparedChannelLogoStore.write(pair.dark, key: darkKey)
        PreparedChannelLogoStore.write(pair.light, key: lightKey)
        insert(pair, for: identity)
        return .built
    }

    /// Restores a pair from the persisted prepared store without any recompute; `variants` is `nil` for a plain logo.
    /// Returns `false` (caching nothing) unless both themes are stored.
    @discardableResult
    public func restoreFromStore(identity: ThemedChannelLogoIdentity, variants: [URL]? = nil) -> Bool {
        let flag = identity.providerRequestsDarkBackground
        let darkKey = PreparedChannelLogoStore.key(url: identity.url, variants: variants, providerRequestsDarkBackground: flag, theme: .dark)
        let lightKey = PreparedChannelLogoStore.key(url: identity.url, variants: variants, providerRequestsDarkBackground: flag, theme: .light)
        guard let pair = restored(darkKey: darkKey, lightKey: lightKey) else { return false }
        insert(pair, for: identity)
        return true
    }

    private func restored(darkKey: String, lightKey: String) -> Pair? {
        lock.withLock { probes += 1 }
        guard let dark = PreparedChannelLogoStore.load(key: darkKey),
              let light = PreparedChannelLogoStore.load(key: lightKey) else { return nil }
        return Pair(dark: dark, light: light)
    }

    private func insert(_ pair: Pair, for identity: ThemedChannelLogoIdentity) {
        lock.withLock {
            if pairs.updateValue(pair, forKey: identity) == nil { insertionOrder.append(identity) }
            guard pairs.count > capacity, pairs.count >= nextSweepAt else { return }
            var excess = pairs.count - capacity
            var kept: [ThemedChannelLogoIdentity] = []
            kept.reserveCapacity(insertionOrder.count)
            for candidate in insertionOrder {
                if excess > 0, !required.contains(candidate) {
                    pairs[candidate] = nil
                    excess -= 1
                } else {
                    kept.append(candidate)
                }
            }
            insertionOrder = kept
            nextSweepAt = excess > 0 ? pairs.count + 64 : 0
        }
    }
}
#endif
