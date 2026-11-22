import XCTest
@testable import FeatureLiveTVCore

final class LiveTVLogoQualityTests: XCTestCase {
    private func candidate(_ source: LiveTVLogoSource, _ name: String, _ size: LiveTVLogoSize?) -> LiveTVLogoCandidate {
        LiveTVLogoCandidate(source: source, url: URL(string: "https://example.invalid/\(name)")!, size: size)
    }

    func testAnOverrideBeatsEverything() {
        let chosen = LiveTVLogoQuality.choose([
            candidate(.wikidata, "wiki.svg", .vector), candidate(.override, "mine.png", .raster(width: 20, height: 20)),
            candidate(.tmdb, "tmdb.png", .raster(width: 2_000, height: 800))
        ])
        XCTAssertEqual(chosen?.source, .override)
    }

    /// A matched TMDB network logo is never replaced, however soft or monochrome; a show match or no match falls through to the rest.
    func testMatchedNetworkLogoBeatsEveryOtherSourceButAnOverride() {
        let soft = candidate(.tmdb, "tmdb.png", .raster(width: 60, height: 30))
        let vector = candidate(.wikidata, "wiki.svg", .vector)
        let icon = candidate(.xmltv, "icon.png", .raster(width: 900, height: 400))
        XCTAssertEqual(LiveTVLogoQuality.choose([soft, vector, icon], tmdbIsNetworkMatch: true, isMonochrome: { _ in true })?.source, .tmdb)
        XCTAssertEqual(LiveTVLogoQuality.choose([soft, vector, icon], tmdbIsNetworkMatch: false)?.source, .wikidata, "a show match stays lower")
        XCTAssertEqual(LiveTVLogoQuality.choose([vector, icon], tmdbIsNetworkMatch: true)?.source, .wikidata, "no TMDB candidate: fall through")
        let mine = candidate(.override, "mine.png", nil)
        XCTAssertEqual(LiveTVLogoQuality.choose([soft, mine], tmdbIsNetworkMatch: true)?.source, .override)
    }

    func testCrispCandidatesKeepSourceOrder() {
        let chosen = LiveTVLogoQuality.choose([
            candidate(.wikidata, "wiki.svg", .vector), candidate(.tmdb, "tmdb.png", .raster(width: 800, height: 300)),
            candidate(.curated, "curated.png", .raster(width: 1_000, height: 400))
        ])
        XCTAssertEqual(chosen?.source, .curated)
    }

    func testASoftTMDBLogoLosesToAVectorOfTheSameChannel() {
        let chosen = LiveTVLogoQuality.choose([
            candidate(.tmdb, "tmdb.png", .raster(width: 180, height: 60)), candidate(.wikidata, "wiki.svg", .vector)
        ])
        XCTAssertEqual(chosen?.source, .wikidata)
    }

    func testASoftTMDBLogoIsStillDrawnWhenItIsTheOnlyRealLogo() {
        let chosen = LiveTVLogoQuality.choose([candidate(.tmdb, "tmdb.png", .raster(width: 150, height: 50))])
        XCTAssertEqual(chosen?.source, .tmdb)
    }

    func testAnUnmeasuredLogoBeatsAMeasuredSoftOne() {
        let chosen = LiveTVLogoQuality.choose([
            candidate(.tmdb, "tmdb.png", .raster(width: 150, height: 50)), candidate(.wikidata, "wiki.png", nil)
        ])
        XCTAssertEqual(chosen?.source, .wikidata)
    }

    func testTheLargerSoftRasterWins() {
        let chosen = LiveTVLogoQuality.choose([
            candidate(.tmdb, "small.png", .raster(width: 100, height: 40)), candidate(.wikidata, "bigger.png", .raster(width: 300, height: 90))
        ])
        XCTAssertEqual(chosen?.source, .wikidata)
    }

    func testNothingIsChosenWithoutCandidates() {
        XCTAssertNil(LiveTVLogoQuality.choose([]))
    }

    func testACrispXMLTVIconIsDrawnButASoftOrUnmeasuredOneIsNot() {
        XCTAssertEqual(LiveTVLogoQuality.choose([candidate(.xmltv, "i.png", .raster(width: 800, height: 300))])?.source, .xmltv)
        XCTAssertEqual(LiveTVLogoQuality.choose([candidate(.xmltv, "i.svg", .vector)])?.source, .xmltv)
        XCTAssertNil(LiveTVLogoQuality.choose([candidate(.xmltv, "soft.png", .raster(width: 300, height: 90))]))
        XCTAssertNil(LiveTVLogoQuality.choose([candidate(.xmltv, "unknown.png", nil)]))
    }

    func testASoftXMLTVIconLosesToARealLogoAndNeverBeatsOne() {
        let chosen = LiveTVLogoQuality.choose([
            candidate(.xmltv, "soft.png", .raster(width: 300, height: 90)), candidate(.tmdb, "tmdb.png", .raster(width: 150, height: 50))
        ])
        XCTAssertEqual(chosen?.source, .tmdb)
    }

    func testCrispnessUsesTheLimitingAxis() {
        XCTAssertFalse(LiveTVLogoQuality.isCrisp(.raster(width: 96, height: 96), for: .guide))
        XCTAssertTrue(LiveTVLogoQuality.isCrisp(.raster(width: 400, height: 90), for: .guide), "wide enough along the width")
        XCTAssertTrue(LiveTVLogoQuality.isCrisp(.raster(width: 120, height: 110), for: .guide), "tall enough along the height")
        XCTAssertTrue(LiveTVLogoQuality.isCrisp(.vector, for: .hero))
        XCTAssertFalse(LiveTVLogoQuality.isCrisp(.raster(width: 400, height: 90), for: .hero))
    }

    func testNoUpscalingOfARasterAndTheCommonsCap() {
        XCTAssertEqual(LiveTVLogoQuality.renditionWidth(for: .raster(width: 300, height: 100), target: .hero), 300, "never above its own width")
        XCTAssertEqual(LiveTVLogoQuality.renditionWidth(for: .vector, target: .hero), 702)
        XCTAssertEqual(LiveTVLogoQuality.renditionWidth(for: .vector, target: LiveTVLogoTarget(width: 5_000, height: 100)), 1_024)
        XCTAssertEqual(LiveTVLogoQuality.renditionWidth(for: nil, target: .guide), 328)
    }
}
