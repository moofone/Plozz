#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// A prepared logo is final for (logo URL, provider flag, theme): written once, read back on every later launch with no decode,
/// analysis or pixel work, and the other theme is never prepared until it is asked for.
final class PreparedChannelLogoStoreTests: XCTestCase {
    private var savedDirectory: URL!
    private var directory: URL!

    override func setUpWithError() throws {
        savedDirectory = PreparedChannelLogoStore.directory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreparedLogos-\(UUID().uuidString)")
        PreparedChannelLogoStore.directory = directory
    }

    override func tearDownWithError() throws {
        PreparedChannelLogoStore.directory = savedDirectory
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) throws -> Data {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "LogoRule", withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    func testASavedResultReadsBackIdenticallyForBothThemes() throws {
        let analysis = try XCTUnwrap(ChannelLogoExtraction.analyze(data: try fixture("CBC_16644.png")))
        let url = URL(string: "https://example.test/roundtrip.png")!
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let prepared = ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: false, theme: theme)
            let key = PreparedChannelLogoStore.key(url: url, variants: nil, providerRequestsDarkBackground: false, theme: theme)
            PreparedChannelLogoStore.write(prepared, key: key)
            let read = try XCTUnwrap(PreparedChannelLogoStore.load(key: key))
            XCTAssertEqual(read.aspect, prepared.aspect)
            XCTAssertEqual(read.isDark, prepared.isDark)
            XCTAssertEqual(read.isLowQuality, prepared.isLowQuality)
            XCTAssertEqual(read.readableShare, prepared.readableShare)
            XCTAssertEqual(read.needsTextFallback, prepared.needsTextFallback)
            XCTAssertEqual(read.inkFill, prepared.inkFill)
            XCTAssertEqual(read.image.size, prepared.image.size)
            XCTAssertEqual(
                ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(read.image.cgImage)),
                ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(prepared.image.cgImage)))
        }
    }

    func testWritingManyFilesListsTheDirectoryOnce() throws {
        let analysis = try XCTUnwrap(ChannelLogoExtraction.analyze(data: try fixture("CBC_16644.png")))
        let prepared = ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: false, theme: .dark)
        let before = PreparedChannelLogoStore.directoryScanCount
        for index in 0..<250 {
            let key = PreparedChannelLogoStore.key(
                url: URL(string: "https://example.test/scan\(index).png")!, variants: nil, providerRequestsDarkBackground: false, theme: .dark)
            PreparedChannelLogoStore.write(prepared, key: key)
        }
        XCTAssertLessThanOrEqual(PreparedChannelLogoStore.directoryScanCount - before, 1)
    }

    func testTrimKeepsProtectedFilesAndRemovesOthers() throws {
        let analysis = try XCTUnwrap(ChannelLogoExtraction.analyze(data: try fixture("CBC_16644.png")))
        let prepared = ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: false, theme: .dark)
        let keys = (0..<4).map {
            PreparedChannelLogoStore.key(
                url: URL(string: "https://example.test/trim\($0).png")!, variants: nil, providerRequestsDarkBackground: false, theme: .dark)
        }
        for key in keys { PreparedChannelLogoStore.write(prepared, key: key) }
        PreparedChannelLogoStore.protect(keys: [keys[0]])
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(keys[0] + ".plogo").path)[.size] as? Int)
        PreparedChannelLogoStore.trim(toBytes: size * 3)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertTrue(names.contains(keys[0] + ".plogo"), "protected, though the oldest")
        XCTAssertEqual(names.count, 2)
    }

    func testKeysDifferByThemeFlagUrlAndVariants() {
        let url = URL(string: "https://example.test/a.png")!
        let other = URL(string: "https://example.test/b.png")!
        let keys: Set<String> = [
            PreparedChannelLogoStore.key(url: url, variants: nil, providerRequestsDarkBackground: false, theme: .dark),
            PreparedChannelLogoStore.key(url: url, variants: nil, providerRequestsDarkBackground: false, theme: .light),
            PreparedChannelLogoStore.key(url: url, variants: nil, providerRequestsDarkBackground: true, theme: .dark),
            PreparedChannelLogoStore.key(url: other, variants: nil, providerRequestsDarkBackground: false, theme: .dark),
            PreparedChannelLogoStore.key(url: url, variants: [url, other], providerRequestsDarkBackground: false, theme: .dark)
        ]
        XCTAssertEqual(keys.count, 5)
    }

    /// The relaunch: a result saved by an earlier launch is served by the loader with no decode and no preparation, and asking for
    /// it does not prepare the other theme.
    func testARelaunchServesTheSavedResultWithoutAnyPixelWork() async throws {
        let analysis = try XCTUnwrap(ChannelLogoExtraction.analyze(data: try fixture("CBC_16644.png")))
        let url = URL(string: "https://example.test/relaunch-\(UUID().uuidString).png")!
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let prepared = ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: false, theme: theme)
            PreparedChannelLogoStore.write(
                prepared, key: PreparedChannelLogoStore.key(url: url, variants: nil, providerRequestsDarkBackground: false, theme: theme))
        }
        let preparedBefore = ChannelLogoExtractionLoader.preparedCount
        let decodedBefore = ChannelLogoExtractionLoader.decodeCount
        let dark = await ChannelLogoExtractionLoader.shared.prepared(url: url, providerRequestsDarkBackground: false, theme: .dark)
        XCTAssertNotNil(dark)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(ChannelLogoExtractionLoader.preparedCount, preparedBefore, "no pixel preparation on a relaunch")
        XCTAssertEqual(ChannelLogoExtractionLoader.decodeCount, decodedBefore, "no logo decode on a relaunch")
        XCTAssertNil(
            ChannelLogoExtractionLoader.cached(url: url, providerRequestsDarkBackground: false, theme: .light),
            "the other theme is not prepared until it is asked for")
    }
}
#endif
