import Foundation

/// A logo image's pixel size, or "vector" when it can be rendered at any size.
public enum LiveTVLogoSize: Equatable, Sendable {
    case vector
    case raster(width: Int, height: Int)
}

/// The size a logo is drawn at, in pixels at 4K (tvOS draws a 4K canvas at 2×).
public struct LiveTVLogoTarget: Equatable, Sendable {
    public let width: Int
    public let height: Int

    /// The guide row's logo box: 164 × 52 pt.
    public static let guide = LiveTVLogoTarget(width: 328, height: 104)
    /// The largest logo drawn, the channel panel's 351 × 124 pt box.
    public static let hero = LiveTVLogoTarget(width: 702, height: 248)
}

/// Where a logo candidate came from, in the order sources are preferred. The playlist provider's own logo is never a source:
/// Live TV draws the channel's name when nothing better is known.
public enum LiveTVLogoSource: Int, Comparable, Sendable {
    case override, curated, tmdb, wikidata, xmltv
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LiveTVLogoCandidate: Equatable, Sendable {
    public let source: LiveTVLogoSource
    public let url: URL
    /// `nil` when the size is not known (an unmeasured raster).
    public let size: LiveTVLogoSize?

    public init(source: LiveTVLogoSource, url: URL, size: LiveTVLogoSize?) {
        self.source = source
        self.url = url
        self.size = size
    }
}

/// Quality-aware choice between logo candidates of the same channel.
public enum LiveTVLogoQuality {
    /// Is the image sharp when drawn uniformly scaled to fit the target? A vector always is; a raster is when it is at least as
    /// large as the box along the axis that limits it (never upscaled).
    public static func isCrisp(_ size: LiveTVLogoSize, for target: LiveTVLogoTarget) -> Bool {
        switch size {
        case .vector: true
        case .raster(let width, let height):
            width > 0 && height > 0 && (width >= target.width || height >= target.height)
        }
    }

    /// The pixel size to ask a renderer for: the target width for a vector, capped at Commons' 1,024; a raster is never asked for more
    /// than it has.
    public static func renditionWidth(for size: LiveTVLogoSize?, target: LiveTVLogoTarget) -> Int {
        let wanted = min(target.width, 1_024)
        if case .raster(let width, _)? = size { return min(wanted, width) }
        return wanted
    }

    /// 0 crisp, 1 unmeasured, 2 a measured raster below the target.
    private static func tier(_ candidate: LiveTVLogoCandidate, target: LiveTVLogoTarget) -> Int {
        guard let size = candidate.size else { return 1 }
        return isCrisp(size, for: target) ? 0 : 2
    }

    /// The candidate to draw. An override beats everything; then a matched TMDB network logo (`tmdbIsNetworkMatch`) beats every other
    /// source. Otherwise: a crisp candidate, then an unmeasured one, then the best
    /// measured raster below the target (the larger, then source order). Within a quality tier a colour logo beats an unmeasured one,
    /// which beats a monochrome (black or white) one; source order (curated, TMDB, Wikidata, XMLTV) breaks the remaining ties.
    /// `isMonochrome` answers from measurements: `nil` for an image not measured.
    /// An XMLTV icon is only ever drawn when it is measured crisp (an unmeasured or soft one is dropped).
    public static func choose(
        _ candidates: [LiveTVLogoCandidate], target: LiveTVLogoTarget = .hero,
        tmdbIsNetworkMatch: Bool = false,
        isMonochrome: (URL) -> Bool? = { _ in nil }
    ) -> LiveTVLogoCandidate? {
        if let override = candidates.first(where: { $0.source == .override }) { return override }
        // A matched TMDB network's logo is never replaced by another source, however it measures; the recolour and the name fallback
        // downstream deal with a logo that reads poorly.
        if tmdbIsNetworkMatch, let network = candidates.first(where: { $0.source == .tmdb }) { return network }
        let real = candidates.filter { candidate in
            guard candidate.source == .xmltv else { return true }
            guard let size = candidate.size else { return false }
            return isCrisp(size, for: target)
        }
        return real.min(by: { lhs, rhs in
            let (left, right) = (tier(lhs, target: target), tier(rhs, target: target))
            if left != right { return left < right }
            if left == 2, area(lhs) != area(rhs) { return area(lhs) > area(rhs) }
            let (leftColour, rightColour) = (colourRank(lhs, isMonochrome), colourRank(rhs, isMonochrome))
            if leftColour != rightColour { return leftColour < rightColour }
            return lhs.source < rhs.source
        })
    }

    /// 0 measured colour, 1 not measured, 2 measured monochrome.
    private static func colourRank(_ candidate: LiveTVLogoCandidate, _ isMonochrome: (URL) -> Bool?) -> Int {
        switch isMonochrome(candidate.url) {
        case false?: 0
        case nil: 1
        case true?: 2
        }
    }

    private static func area(_ candidate: LiveTVLogoCandidate) -> Int {
        if case .raster(let width, let height)? = candidate.size { return width * height }
        return 0
    }
}
