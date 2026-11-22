import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoreUI

final class LiveTVLogoImageStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTVLogoImageStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Downloads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var total: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    private func pngData(width: Int = 4) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func response(_ url: URL, status: Int = 200) -> URLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testLogoIsDownloadedOnceAndThenReadFromDiskAcrossRelaunches() async throws {
        let png = try pngData()
        let downloads = Downloads()
        let url = try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/original/a.png"))
        let make = { LiveTVLogoImageStore(directory: self.directory, download: { url in
            downloads.bump()
            return (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }) }
        let first = await make().data(for: url)
        let second = await make().data(for: url)
        XCTAssertEqual(first, png)
        XCTAssertEqual(second, png)
        XCTAssertEqual(downloads.total, 1)
    }

    func testOverlappingRequestsShareOneDownload() async throws {
        let png = try pngData()
        let downloads = Downloads()
        let url = try XCTUnwrap(URL(string: "https://example.com/slow.png"))
        let store = LiveTVLogoImageStore(directory: directory, download: { url in
            downloads.bump()
            try await Task.sleep(for: .milliseconds(100))
            return (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        async let one = store.data(for: url)
        async let two = store.data(for: url)
        let results = await (one, two)
        XCTAssertNotNil(results.0)
        XCTAssertEqual(results.0, results.1)
        XCTAssertEqual(downloads.total, 1)
    }

    func testFailuresAndNonImagesAreNotStored() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/bad.png"))
        let statusFailure = LiveTVLogoImageStore(directory: directory, download: { url in
            (Data("x".utf8), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        let notImage = LiveTVLogoImageStore(directory: directory, download: { url in
            (Data("<html>".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let thrown = LiveTVLogoImageStore(directory: directory, download: { _ in throw URLError(.timedOut) })
        let a = await statusFailure.data(for: url)
        let b = await notImage.data(for: url)
        let c = await thrown.data(for: url)
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertNil(c)
        let stored = await statusFailure.storedBytes()
        XCTAssertEqual(stored, 0)
    }

    func testLeastRecentlyUsedLogosAreEvictedOnlyOverCapacity() async throws {
        let small = try pngData(width: 4)
        let size = small.count
        var clock = Date(timeIntervalSince1970: 1_000)
        let lock = NSLock()
        let store = LiveTVLogoImageStore(
            directory: directory, capacityBytes: size * 2 + size / 2,
            download: { url in (small, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            now: { lock.withLock { clock = clock.addingTimeInterval(10); return clock } }
        )
        let urls = try (1...3).map { try XCTUnwrap(URL(string: "https://example.com/\($0).png")) }
        _ = await store.data(for: urls[0])
        _ = await store.data(for: urls[1])
        let beforeEviction = await store.storedBytes()
        XCTAssertEqual(beforeEviction, size * 2, "under capacity nothing is removed")
        _ = await store.data(for: urls[0])  // makes the first more recent than the second
        _ = await store.data(for: urls[2])
        let after = await store.storedBytes()
        XCTAssertEqual(after, size * 2)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertTrue(names.contains(LiveTVLogoImageStore.fileName(for: urls[0])))
        XCTAssertTrue(names.contains(LiveTVLogoImageStore.fileName(for: urls[2])))
        XCTAssertFalse(names.contains(LiveTVLogoImageStore.fileName(for: urls[1])))
    }

    func testStoringManyFilesListsTheDirectoryOnceWhileUnderCapacity() async throws {
        let png = try pngData()
        let store = LiveTVLogoImageStore(directory: directory, download: { url in
            (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for index in 0..<300 { _ = await store.data(for: try XCTUnwrap(URL(string: "https://example.com/n\(index).png"))) }
        let scans = await store.directoryScanCount
        XCTAssertLessThanOrEqual(scans, 1, "one listing to learn the starting total, not one per stored file")
    }

    func testEvictionListsTheDirectoryOnlyOncePerTenthOfCapacityStored() async throws {
        let png = try pngData()
        let store = LiveTVLogoImageStore(directory: directory, capacityBytes: png.count * 50, download: { url in
            (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let stored = 500
        for index in 0..<stored { _ = await store.data(for: try XCTUnwrap(URL(string: "https://example.com/e\(index).png"))) }
        let scans = await store.directoryScanCount
        // Over capacity every file used to list the directory (500 listings). Trimming to 90% makes a listing every ~5 files.
        XCTAssertLessThanOrEqual(scans, stored / 4)
        let bytes = await store.storedBytes()
        XCTAssertLessThanOrEqual(bytes, png.count * 50)
    }

    func testDefaultDirectoryIsApplicationSupport() {
        XCTAssertTrue(LiveTVLogoImageStore.defaultDirectory().path.contains("Application Support"))
    }
}
