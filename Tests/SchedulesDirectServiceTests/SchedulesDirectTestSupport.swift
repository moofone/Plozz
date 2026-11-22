import Foundation
import CoreModels
import CoreNetworking
@testable import SchedulesDirectService

/// Scripted `HTTPClient`: responses are queued per path suffix (the last one repeats).
final class SchedulesDirectStubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Stub { var status = 200; var body: String; var headers: [String: String] = [:] }
    struct Sent { let method: HTTPMethod; let path: String; let query: [URLQueryItem]; let headers: [String: String]; let body: Data? }

    private let lock = NSLock()
    private var stubs: [String: [Stub]] = [:]
    private(set) var sent: [Sent] = []
    private var concurrent = 0
    private(set) var peakConcurrency = 0
    var latency: TimeInterval = 0

    func stub(_ suffix: String, _ body: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        stubs[suffix, default: []].append(Stub(status: status, body: body, headers: headers))
    }

    func replace(_ suffix: String, _ body: String, status: Int = 200, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        stubs[suffix] = [Stub(status: status, body: body, headers: headers)]
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return sent.map(\.path) }
    func count(suffix: String) -> Int { paths().filter { $0.hasSuffix(suffix) }.count }
    func bodies(suffix: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return sent.filter { $0.path.hasSuffix(suffix) }.compactMap(\.body) }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await sendRaw(endpoint, baseURL: baseURL)
    }

    func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        sent.append(Sent(method: endpoint.method, path: endpoint.path, query: endpoint.queryItems, headers: endpoint.headers, body: endpoint.body))
        concurrent += 1
        peakConcurrency = max(peakConcurrency, concurrent)
        let key = stubs.keys.filter { endpoint.path.hasSuffix($0) }.max { $0.count < $1.count }
        var stub = Stub(status: 404, body: "{\"code\":9999,\"message\":\"no stub\"}")
        if let key, var queue = stubs[key] {
            stub = queue.count > 1 ? queue.removeFirst() : queue[0]
            stubs[key] = queue
        }
        lock.unlock()
        if latency > 0 { try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        lock.lock(); concurrent -= 1; lock.unlock()
        let response = HTTPURLResponse(url: baseURL, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        return (Data(stub.body.utf8), response)
    }
}

final class SchedulesDirectFakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var sleeps: [TimeInterval] = []

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = date }

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }

    var clock: SchedulesDirectClock {
        SchedulesDirectClock(now: { self.now }, sleep: { seconds in
            self.lock.lock(); self.sleeps.append(seconds); self.current = self.current.addingTimeInterval(seconds); self.lock.unlock()
        })
    }
}

final class SchedulesDirectMemorySecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String: String] = [:]
    func setString(_ value: String, for key: String) throws { lock.lock(); values[key] = value; lock.unlock() }
    func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func readString(for key: String) throws -> String? { string(for: key) }
    func removeValue(for key: String) throws { lock.lock(); values[key] = nil; lock.unlock() }
}

/// A self-contained world: temp storage root, memory Keychain, fake clock and stub HTTP.
final class SchedulesDirectFixture {
    let http = SchedulesDirectStubHTTPClient()
    let time = SchedulesDirectFakeClock()
    let secure = SchedulesDirectMemorySecureStore()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-tests-\(UUID().uuidString)")
    var limits = SchedulesDirectLimits()
    var flags = RuntimeFeatureFlags(enabled: [.schedulesDirect])
    var networkAllowed = true

    init() { SchedulesDirectAccounts.shared.removeAll() }
    deinit { try? FileManager.default.removeItem(at: root) }

    var storage: SchedulesDirectStorage { SchedulesDirectStorage(root: root) }

    func service(namespace: String? = nil) -> SchedulesDirectService {
        let allowed = networkAllowed
        return SchedulesDirectService(
            namespace: namespace, secureStore: secure, http: http, storage: storage, featureFlags: flags,
            clock: time.clock, limits: limits, userAgent: "Plozz/9.9 (tvOS)", jitter: { 0 },
            isNetworkAllowed: { allowed }
        )
    }

    func stubLogin(expires: Date? = nil) {
        let expiry = (expires ?? time.now.addingTimeInterval(86_400)).timeIntervalSince1970
        http.stub("/token", "{\"code\":0,\"message\":\"OK\",\"token\":\"tok-1\",\"tokenExpires\":\(Int(expiry))}")
        http.stub("/status", statusJSON())
    }

    func statusJSON(lineups: String = "[{\"lineup\":\"USA-OTA-60030\",\"modified\":\"2030-01-01T00:00:00Z\"}]") -> String {
        "{\"code\":0,\"account\":{\"expires\":\"2031-01-01T00:00:00Z\",\"maxLineups\":4},\"lineups\":\(lineups),\"systemStatus\":[{\"status\":\"Online\"}]}"
    }

    /// Simulates an app relaunch: in-memory sessions go, files and Keychain stay.
    func relaunch() { SchedulesDirectAccounts.shared.removeAll() }
}
