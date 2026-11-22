import XCTest
@testable import CoreModels

final class IPTVChannelNameSplitTests: XCTestCase {
    private func split(_ name: String) -> (String, [IPTVChannelTag]) {
        let result = IPTVChannelName.split(name)
        return (result.name, result.tags)
    }

    func testSuperscriptGroupsBecomeTagsAndLeaveTheName() {
        XCTAssertEqual(split("CANADA \u{1D34}\u{1D30}/\u{1D3F}\u{1D2C}\u{1D42} \u{2076}\u{2070}\u{1DA0}\u{1D56}\u{02E2}").0, "CANADA")
        XCTAssertEqual(split("CANADA \u{1D34}\u{1D30}/\u{1D3F}\u{1D2C}\u{1D42} \u{2076}\u{2070}\u{1DA0}\u{1D56}\u{02E2}").1, [.hd, .raw, .fps(60)])
        XCTAssertEqual(split("BBC One \u{207D}\u{1D2E}\u{1D37}\u{207E}").0, "BBC One")
        XCTAssertEqual(split("BBC One \u{207D}\u{1D2E}\u{1D37}\u{207E}").1, [.backup])
        XCTAssertEqual(split("Sport \u{1D41}\u{1D34}\u{1D30}").1, [.uhd])
    }

    func testUnknownSuperscriptTokensStayInTheNameAsASCII() {
        XCTAssertEqual(split("CBC \u{1D3A}\u{1D31}\u{1D42}\u{02E2}").0, "CBC NEWs")
        XCTAssertEqual(split("CBC \u{1D3A}\u{1D31}\u{1D42}\u{02E2}").1, [])
    }

    func testPlainDescriptors() {
        XCTAssertEqual(split("CBC HD 60FPS").0, "CBC")
        XCTAssertEqual(split("CBC HD 60FPS").1, [.hd, .fps(60)])
        XCTAssertEqual(split("Movies (4K)").1, [.k4])
        XCTAssertEqual(split("Movies (4K)").0, "Movies")
        XCTAssertEqual(split("Movies UHD").1, [.uhd])
        XCTAssertEqual(split("Movies H D").1, [.hd])
        XCTAssertEqual(split("Movies 1080p").1, [.fhd])
        XCTAssertEqual(split("Movies HEVC HDR").1, [.hdr])
        XCTAssertEqual(split("Movies HEVC HDR").0, "Movies")
        XCTAssertEqual(split("Movies 50fps").1, [.fps(50)])
        XCTAssertEqual(split("Movies HD HD").1, [.hd])
    }

    func testReadsHDAtTheEndOfTaggedFeeds() {
        let fixtures = [
            ("CA EN: CP24 HD (R)", "CP24", "CA", "EN"),
            ("CA EN: APTN HD (CA)", "APTN", "CA", "EN"),
            ("CA EN: CBC MONTREALHD", "CBC MONTREAL", "CA", "EN"),
            ("DE DE: Example Regional HD (DE)", "Example Regional", "DE", "DE"),
            ("FR FR: Example RégionalHD", "Example Régional", "FR", "FR")
        ]
        for (input, name, country, language) in fixtures {
            let actual = split(input)
            XCTAssertEqual(actual.0, name, input)
            XCTAssertEqual(actual.1, [.country(country), .language(language), .hd], input)
        }
    }

    func testKeepsUncorroboratedNameEndings() {
        let fixtures = [
            ("CA EN: Station HD (FR)", "Station HD (FR)"),
            ("CA EN: Station HD (LIVE)", "Station HD (LIVE)"),
            ("CA EN: Station (R)", "Station (R)"),
            ("CA EN: Station HD(R)", "Station HD(R)"),
            ("CA EN: Radio SHAHD", "Radio SHAHD"),
            ("CA EN: RegionalHD", "RegionalHD"),
            ("CA EN: Station RegionalFHD", "Station RegionalFHD"),
            ("Station RegionalHD", "Station RegionalHD"),
            ("CA EN: Station REGIONALhd", "Station REGIONALhd")
        ]
        for (input, expected) in fixtures {
            let actual = split(input)
            XCTAssertEqual(actual.0, expected, input)
            XCTAssertFalse(actual.1.contains(.hd), input)
        }
    }

    func testCanadianGlobalFeedsKeepDistinctNames() {
        let fixtures = [
            ("CA EN: GLOBAL NEWS TORONTO HD", "GLOBAL NEWS TORONTO"),
            ("CA EN: GLOBAL NEWS VANCOUVER HD", "GLOBAL NEWS VANCOUVER"),
            ("CA EN: GLOBAL VANCOUVER", "GLOBAL VANCOUVER"),
            ("CA EN: GLOBAL NEWS NATIONAL HD", "GLOBAL NEWS NATIONAL")
        ]
        for (input, expected) in fixtures { XCTAssertEqual(split(input).0, expected, input) }
    }

    func testRealDigitsAndPlainWordsStayIntact() {
        XCTAssertEqual(split("CHANNEL 4").0, "CHANNEL 4")
        XCTAssertEqual(split("CHANNEL 4").1, [])
        XCTAssertEqual(split("FOX 5 HD").0, "FOX 5")
        XCTAssertEqual(split("FOX 5 HD").1, [.hd])
        XCTAssertEqual(split("BBC One +1").0, "BBC One +1")
        XCTAssertEqual(split("HD").0, "HD")
        XCTAssertEqual(split("Sky Sports 10").0, "Sky Sports 10")
        XCTAssertEqual(split("日本テレビ").0, "日本テレビ")
    }

    func testCountryAndLanguagePrefixes() {
        XCTAssertEqual(split("CA EN: CBC CALGARY HD").0, "CBC CALGARY")
        XCTAssertEqual(split("CA EN: CBC CALGARY HD").1, [.country("CA"), .language("EN"), .hd])
        XCTAssertEqual(split("CA FR: ICI RDI").1, [.country("CA"), .language("FR")])
        XCTAssertEqual(split("US EN: ESPN").0, "ESPN")
        XCTAssertEqual(split("CA| TSN 1").0, "TSN 1")
        XCTAssertEqual(split("CA| TSN 1").1, [.country("CA")])
        XCTAssertEqual(split("|FR| TF1").0, "TF1")
        XCTAssertEqual(split("|FR| TF1").1, [.country("FR")])
        XCTAssertEqual(split("UK| BBC One").1, [.country("GB")])
        XCTAssertEqual(split("UK| BBC One").0, "BBC One")
        XCTAssertEqual(split("CA EN | CBC").1, [.country("CA"), .language("EN")])
    }

    func testInvalidPrefixesStayInTheName() {
        XCTAssertEqual(split("AB: News").0, "AB: News")
        XCTAssertEqual(split("AB: News").1, [])
        XCTAssertEqual(split("CA XX: News").0, "CA XX: News")
        XCTAssertEqual(split("Ca: News").0, "Ca: News")
        XCTAssertEqual(split("CA:").0, "CA:")
    }

    func testASCIIAndUnicodeInputsGiveEqualResults() {
        let pairs: [(String, String)] = [
            ("CANADA \u{1D34}\u{1D30}", "CANADA HD"),
            ("\u{1D9C}\u{1D43} EN: X", "ca EN: X"),
            ("CBC \u{2074}\u{1D3A}", "CBC 4N")
        ]
        for (unicode, ascii) in pairs where unicode.contains(where: { !$0.isASCII }) {
            let left = IPTVChannelName.split(unicode), right = IPTVChannelName.split(ascii)
            XCTAssertEqual(left.name, right.name, unicode)
            XCTAssertEqual(left.tags, right.tags, unicode)
        }
    }

    /// The guide plate shows only the 4K word (4K, UHD or 8K); every other tag stays on the hero and the channel panel.
    func testGuidePlateBadgeIsUltraHighDefinitionOnly() {
        XCTAssertEqual(IPTVChannelTag.ultraHighDefinitionBadge(in: [.hdr, .fps(60), .k4]), .k4)
        XCTAssertEqual(IPTVChannelTag.ultraHighDefinitionBadge(in: [.uhd]), .k4)
        XCTAssertEqual(IPTVChannelTag.ultraHighDefinitionBadge(in: [.k8, .k4]), .k8)
        XCTAssertNil(IPTVChannelTag.ultraHighDefinitionBadge(in: [.hd, .fps(60), .hdr]))
        XCTAssertNil(IPTVChannelTag.ultraHighDefinitionBadge(in: [.country("CA"), .language("EN"), .raw, .backup]))
    }

    func testFrameRateBadgeIsAVerbatimTokenWithoutASpace() {
        XCTAssertEqual(IPTVChannelTag.fps(60).badgeText, "60fps")
        XCTAssertEqual(IPTVChannelTag.fps(120).badgeText, "120fps")
    }

    /// The allocation-free ASCII cleaner must equal the Unicode reference on awkward spacing, pipes, spaced tags and markers.
    func testASCIICleanerMatchesTheUnicodeReferenceOnGeneratedNames() {
        let vocabulary = ["CA", "EN", "FR", "US", "UK", "|", "||", ":", "HD", "FHD", "UHD", "4K", "8K", "HDR", "RAW", "BK", "SD",
                          "H", "D", "U", "F", "S", "60FPS", "50fps", "1080p", "(4K)", "[HD]", "HD/RAW", "+1", "4", "CBC", "NEWS",
                          "#", "##", "***", "H.264", "HEVC", "x|y", "(", "a b", "CA|", "|FR|", "240p", "12345", "  ", "\t"]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<20_000 {
            let separator = [" ", " ", "", "  "][next(4)]
            let name = (0..<next(10)).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: separator)
            XCTAssertEqual(IPTVChannelName.cleaned(name), IPTVChannelName.cleanedUnicode(name), name.debugDescription)
        }
    }

    /// Release-mode number is recorded in REPORT-tags.md; Debug runs only check that it completes.
    func testSplitOver60kRealisticNamesPerformance() {
        let names = Self.realisticNames(count: 60_000)
        measure {
            var tagged = 0
            for name in names { tagged += IPTVChannelName.split(name).tags.count }
            XCTAssertGreaterThan(tagged, 0)
        }
    }

    func testCleanedBaseline60k() {
        let names = Self.realisticNames(count: 60_000)
        measure {
            var length = 0
            for name in names { length += IPTVChannelName.cleaned(name).utf8.count }
            XCTAssertGreaterThan(length, 0)
        }
    }

    static func realisticNames(count: Int) -> [String] {
        let prefixes = ["", "", "CA EN: ", "CA FR: ", "US EN: ", "CA| ", "US| ", "UK| ", "|FR| "]
        let bases = ["CBC CALGARY", "CTV NEWS", "GLOBAL TORONTO", "TSN 1", "SPORTSNET ONE", "ESPN 2", "FOX 5", "CHANNEL 4", "BBC One", "Sky Sports 10"]
        let suffixes = ["", "", "", " HD", " FHD", " 4K", " UHD", " HD 60FPS", " RAW", " (4K)", " 1080p", " +1",
                        " \u{1D34}\u{1D30}/\u{1D3F}\u{1D2C}\u{1D42} \u{2076}\u{2070}\u{1DA0}\u{1D56}\u{02E2}", " \u{1D34}\u{1D30}"]
        return (0..<count).map { index in
            prefixes[index % prefixes.count] + bases[(index / 7) % bases.count] + " \(index % 97)" + suffixes[(index / 3) % suffixes.count]
        }
    }
}
