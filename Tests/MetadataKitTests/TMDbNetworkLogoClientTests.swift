import Foundation
import XCTest
@testable import MetadataKit

final class TMDbNetworkLogoClientTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    }

    private func client(
        access: TMDbAccess, recorder: Recorder, respond: @escaping @Sendable (URL) -> (Int, String)
    ) -> TMDbNetworkLogoClient {
        TMDbNetworkLogoClient(access: access, http: MetadataDiscoveryHTTPClient(send: { request in
            recorder.record(request)
            let (status, body) = respond(request.url!)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }), limiter: RateLimiter(requestsPerSecond: 1_000, burst: 100))
    }

    private let networkJSON = #"{"id":110,"name":"CTV","origin_country":"ca"}"#
    private let imagesJSON = """
    {"id":110,"logos":[
     {"file_path":"/png-big.png","width":2000,"height":800,"file_type":".png","vote_average":9.0},
     {"file_path":"/svg-low.png","width":500,"height":200,"file_type":".svg","vote_average":1.0},
     {"file_path":"/svg-high.png","width":400,"height":160,"file_type":".svg","vote_average":5.0},
     {"file_path":"/svg-high-wide.png","width":900,"height":360,"file_type":".svg","vote_average":5.0}]}
    """

    func testPrefersSVGThenVotesThenWidth() throws {
        let logos = try JSONDecoder().decode(TMDbNetworkLogoClient.ImagesResponse.self, from: Data(imagesJSON.utf8)).logos
        XCTAssertEqual(TMDbNetworkLogoClient.bestLogo(logos)?.file_path, "/svg-high-wide.png")
        XCTAssertEqual(TMDbNetworkLogoClient.bestLogo(Array(logos.prefix(1)))?.file_path, "/png-big.png")
        XCTAssertNil(TMDbNetworkLogoClient.bestLogo([]))
    }

    func testAnImageLargeEnoughForThePanelBeatsASmallerSVG() throws {
        let json = #"{"id":1,"logos":[{"file_path":"/small-svg.png","width":300,"height":100,"file_type":".svg","vote_average":9.0},{"file_path":"/large.png","width":1000,"height":300,"file_type":".png","vote_average":1.0}]}"#
        let logos = try JSONDecoder().decode(TMDbNetworkLogoClient.ImagesResponse.self, from: Data(json.utf8)).logos
        XCTAssertEqual(TMDbNetworkLogoClient.bestLogo(logos)?.file_path, "/large.png")
    }

    func testTheChosenImagesPixelSizeIsKept() async throws {
        let client = client(access: .userToken("test-token"), recorder: Recorder()) { [networkJSON, imagesJSON] url in
            (200, url.path.hasSuffix("/images") ? imagesJSON : networkJSON)
        }
        let logo = try await client.logo(forNetworkID: 110)
        XCTAssertEqual(logo?.pixelWidth, 900)
        XCTAssertEqual(logo?.pixelHeight, 360)
    }

    func testReadsNameCountryAndLogoThroughTheBearerToken() async throws {
        let recorder = Recorder()
        let client = client(access: .userToken("test-token"), recorder: recorder) { [networkJSON, imagesJSON] url in
            (200, url.path.hasSuffix("/images") ? imagesJSON : networkJSON)
        }
        let logo = try await client.logo(forNetworkID: 110)
        XCTAssertEqual(logo, TMDbNetworkLogo(
            networkID: 110, name: "CTV", originCountry: "CA", filePath: "/svg-high-wide.png",
            pixelWidth: 900, pixelHeight: 360,
            variantPaths: ["/svg-high-wide.png", "/png-big.png", "/svg-high.png", "/svg-low.png"]
        ))
        XCTAssertEqual(logo?.logoURL?.absoluteString, "https://image.tmdb.org/t/p/original/svg-high-wide.png")
        XCTAssertEqual(recorder.requests.map { $0.url?.absoluteString }, [
            "https://api.themoviedb.org/3/network/110", "https://api.themoviedb.org/3/network/110/images"
        ])
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testProxyAccessSendsNoCredentialAndUsesTheProxyHost() async throws {
        let recorder = Recorder()
        let proxy = URL(string: "https://proxy.example.com")!
        let client = client(access: .proxy(baseURL: proxy), recorder: recorder) { [networkJSON, imagesJSON] url in
            (200, url.path.hasSuffix("/images") ? imagesJSON : networkJSON)
        }
        _ = try await client.logo(forNetworkID: 110)
        XCTAssertEqual(recorder.requests.first?.url?.host, "proxy.example.com")
        XCTAssertNil(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testDisabledAccessMakesNoRequests() async {
        let recorder = Recorder()
        let client = client(access: .disabled, recorder: recorder) { _ in (200, "{}") }
        do {
            _ = try await client.logo(forNetworkID: 110)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? TMDbNetworkLogoClient.Failure, .disabled)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testUnknownNetworkIsAnAnswerNotAFailure() async throws {
        let client = client(access: .directToken("t"), recorder: Recorder()) { _ in (404, "{}") }
        let logo = try await client.logo(forNetworkID: 1)
        XCTAssertNil(logo)
    }

    func testRejectedKeyOpensTheBreakerSoLaterCallsSkipTheNetwork() async {
        let recorder = Recorder()
        let client = client(access: .userToken("bad"), recorder: recorder) { _ in (401, "{}") }
        _ = try? await client.logo(forNetworkID: 1)
        do {
            _ = try await client.logo(forNetworkID: 2)
            XCTFail("expected the breaker to refuse")
        } catch {
            XCTAssertEqual(error as? TMDbNetworkLogoClient.Failure, .unavailable)
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testImageURLRejectsPathsThatCouldChangeTheHost() {
        XCTAssertNotNil(TMDbNetworkLogoClient.imageURL(filePath: "/a.png"))
        XCTAssertNil(TMDbNetworkLogoClient.imageURL(filePath: "evil.example/a.png"))
        XCTAssertNil(TMDbNetworkLogoClient.imageURL(filePath: "/a.png#x"))
        XCTAssertNil(TMDbNetworkLogoClient.imageURL(filePath: "/a.png?x=1"))
    }

    func testAStoredLogoWithoutPixelSizesStillDecodes() throws {
        let old = Data(#"{"networkID":110,"name":"CTV","originCountry":"CA","filePath":"/ctv.png"}"#.utf8)
        let logo = try JSONDecoder().decode(TMDbNetworkLogo.self, from: old)
        XCTAssertNil(logo.pixelWidth)
        XCTAssertEqual(logo.filePath, "/ctv.png")
    }
}
