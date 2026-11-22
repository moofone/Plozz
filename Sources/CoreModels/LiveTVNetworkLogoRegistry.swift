import Foundation

/// The logo files TMDB lists for a matched TV network, keyed by the file Live TV draws by default. A URL found here is a NETWORK
/// logo: it is always drawn (never replaced by the channel's name), and the artwork may pick another listed variant per theme.
/// Written by the logo service when it resolves a network; read by the logo artwork. The first variant is the default one.
public final class LiveTVNetworkLogoRegistry: @unchecked Sendable {
    public static let shared = LiveTVNetworkLogoRegistry()

    private let lock = NSLock()
    private var variantsByDefaultURL: [URL: [URL]] = [:]

    public init() {}

    public func register(defaultURL: URL, variants: [URL]) {
        lock.withLock {
            var ordered = [defaultURL]
            for url in variants where !ordered.contains(url) { ordered.append(url) }
            variantsByDefaultURL[defaultURL] = ordered
        }
    }

    /// The variants of a network logo (the default first), `nil` when `url` is not a network logo.
    public func variants(for url: URL) -> [URL]? { lock.withLock { variantsByDefaultURL[url] } }

    public func removeAll() { lock.withLock { variantsByDefaultURL.removeAll() } }
}
