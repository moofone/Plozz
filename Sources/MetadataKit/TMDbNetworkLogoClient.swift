import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What TMDB knows about one TV network, and the logo chosen for it.
public struct TMDbNetworkLogo: Codable, Equatable, Sendable {
    public let networkID: Int
    public let name: String
    /// ISO 3166-1 country, `nil` when TMDB does not know it.
    public let originCountry: String?
    /// TMDB image path such as `/abc.png`, `nil` when the network has no logo.
    public let filePath: String?
    /// Pixel size of the chosen image as TMDB lists it, `nil` when not known (stored before sizes were kept).
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// The best few logo files TMDB lists for the network (see ``TMDbNetworkLogoClient/maximumVariants``), the chosen one first.
    /// `nil` when stored before variants were kept; the logo service then asks TMDB once more.
    public let variantPaths: [String]?

    public init(
        networkID: Int, name: String, originCountry: String?, filePath: String?,
        pixelWidth: Int? = nil, pixelHeight: Int? = nil, variantPaths: [String]? = nil
    ) {
        self.variantPaths = variantPaths
        self.networkID = networkID
        self.name = name
        self.originCountry = originCountry
        self.filePath = filePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var logoURL: URL? { filePath.flatMap(TMDbNetworkLogoClient.imageURL(filePath:)) }

    /// The URLs of ``variantPaths``, the chosen logo first.
    public var variantURLs: [URL] {
        ([filePath].compactMap { $0 } + (variantPaths ?? [])).compactMap(TMDbNetworkLogoClient.imageURL(filePath:)).reduce(into: []) {
            if !$0.contains($1) { $0.append($1) }
        }
    }
}

/// Reads TV network details and logos through the app's existing TMDB access.
///
/// The request URL and auth header builders are the ones the TMDB metadata provider uses,
/// so a bundled token, a user's own key and a proxy all work as they do elsewhere. Calls
/// share a rate limiter and a circuit breaker, and nothing is requested while access is
/// disabled. Image bytes come straight from TMDB's CDN and are never fetched here.
public struct TMDbNetworkLogoClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case disabled
        /// The breaker is open after repeated failures, or the key was rejected.
        case unavailable
        case invalidResponse
    }

    public static let imageBase = "https://image.tmdb.org/t/p/original"

    private let access: TMDbAccess
    private let http: MetadataDiscoveryHTTPClient
    private let limiter: RateLimiter
    private let breaker: ProviderCircuitBreaker

    public init(
        access: TMDbAccess,
        http: MetadataDiscoveryHTTPClient = MetadataDiscoveryHTTPClient(),
        limiter: RateLimiter = RateLimiter(requestsPerSecond: 10, burst: 5),
        breaker: ProviderCircuitBreaker = ProviderCircuitBreaker()
    ) {
        self.access = access
        self.http = http
        self.limiter = limiter
        self.breaker = breaker
    }

    public var isEnabled: Bool { access.isEnabled }

    public static func imageURL(filePath: String) -> URL? {
        guard filePath.hasPrefix("/"), !filePath.contains("?"), !filePath.contains("#") else { return nil }
        return URL(string: imageBase + filePath)
    }

    /// Name, country and chosen logo for one network; `nil` when TMDB has no such network.
    public func logo(forNetworkID id: Int) async throws -> TMDbNetworkLogo? {
        guard let details = try await get(DetailsResponse.self, path: "/3/network/\(id)") else { return nil }
        let images = try await get(ImagesResponse.self, path: "/3/network/\(id)/images")
        let best = Self.bestLogo(images?.logos ?? [])
        return TMDbNetworkLogo(
            networkID: id, name: details.name ?? "",
            originCountry: details.origin_country?.trimmedNonEmpty?.uppercased(),
            filePath: best?.file_path,
            pixelWidth: best?.width, pixelHeight: best?.height,
            variantPaths: Self.rankedLogos(images?.logos ?? []).prefix(Self.maximumVariants).compactMap(\.file_path)
        )
    }

    // MARK: Selection

    struct DetailsResponse: Decodable, Sendable {
        let name: String?
        let origin_country: String?
    }

    struct ImagesResponse: Decodable, Sendable {
        let logos: [Image]
    }

    struct Image: Decodable, Sendable, Equatable {
        let file_path: String?
        let width: Int?
        let height: Int?
        let file_type: String?
        let vote_average: Double?
    }

    static func isVector(_ image: Image) -> Bool {
        let type = image.file_type?.lowercased()
        return type == ".svg" || type == "svg"
    }

    /// Sharp at the largest size a logo is drawn (the 351 × 124 pt channel panel at 4K, 702 × 248 px): one axis reaches the box.
    static let panelWidth = 702, panelHeight = 248

    static func isLargeEnough(_ image: Image) -> Bool {
        (image.width ?? 0) >= panelWidth || (image.height ?? 0) >= panelHeight
    }

    /// Prefers an image large enough for the panel, then an `.svg` original (TMDB serves it as a PNG), then the highest vote
    /// average, then the widest image; the path breaks any remaining tie.
    static func bestLogo(_ logos: [Image]) -> Image? { rankedLogos(logos).first }

    /// How many of a network's listed logos are kept as variants for the per-theme pick (the `/images` call returns them all anyway).
    public static let maximumVariants = 5

    /// Every usable logo, best first by the key of ``bestLogo(_:)``.
    static func rankedLogos(_ logos: [Image]) -> [Image] {
        logos.filter { $0.file_path.map { $0.hasPrefix("/") } ?? false }.sorted { lhs, rhs in
            func key(_ image: Image) -> (Int, Int, Double, Int) {
                (isLargeEnough(image) ? 0 : 1, isVector(image) ? 0 : 1,
                 -(image.vote_average ?? 0), -(image.width ?? 0))
            }
            let (left, right) = (key(lhs), key(rhs))
            if left != right { return left < right }
            return (lhs.file_path ?? "") < (rhs.file_path ?? "")
        }
    }

    // MARK: Transport

    func get<Value: Decodable & Sendable>(_ type: Value.Type, path: String) async throws -> Value? {
        guard access.isEnabled else { throw Failure.disabled }
        guard await breaker.allow() else { throw Failure.unavailable }
        let base = access.metadataAPIBaseURL.absoluteString
        guard let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + path) else {
            throw Failure.invalidResponse
        }
        var request = URLRequest(url: url)
        for (name, value) in access.metadataAuthorizationHeaders { request.setValue(value, forHTTPHeaderField: name) }
        await limiter.acquire()
        try Task.checkCancellation()
        do {
            let value = try await http.decode(type, from: request)
            await breaker.record(.ok)
            return value
        } catch MetadataDiscoveryHTTPError.status(404, _) {
            await breaker.record(.empty)
            return nil
        } catch MetadataDiscoveryHTTPError.status(let code, let retryAfter) {
            await breaker.record(.failure(Self.failureKind(status: code, retryAfter: retryAfter)))
            throw MetadataDiscoveryHTTPError.status(code, retryAfter: retryAfter)
        } catch is CancellationError {
            throw CancellationError()
        } catch MetadataDiscoveryHTTPError.invalidResponse {
            await breaker.record(.failure(.transient))
            throw Failure.invalidResponse
        } catch {
            if Task.isCancelled { throw CancellationError() }
            await breaker.record(.failure(.transient))
            throw error
        }
    }

    static func failureKind(status: Int, retryAfter: TimeInterval?) -> ProviderFailureKind {
        switch status {
        case 401, 403: .unauthorized
        case 429: .rateLimited(retryAfter: retryAfter)
        default: .transient
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
