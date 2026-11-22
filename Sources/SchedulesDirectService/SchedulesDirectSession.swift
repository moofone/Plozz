import Foundation
import CoreModels
import CoreNetworking

public enum SchedulesDirectEnvironment {
    public static let origin = URL(string: "https://json.schedulesdirect.org")!
    public static let apiPath = "/20141201"
    public static var baseURL: URL { origin.appendingPathComponent("20141201") }

    /// `Plozz/<version> (<platform>)`, the only User-Agent every request carries.
    public static func userAgent(version: String? = nil) -> String {
        let resolved = version
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "other"
        #endif
        return "Plozz/\(resolved) (\(platform))"
    }
}

/// One Schedules Direct account's connection: a single reused token, the request
/// governor and the limiter. Every endpoint call goes through ``send``.
actor SchedulesDirectSession {
    struct Call: Sendable {
        var method: HTTPMethod
        var path: String
        var query: [URLQueryItem] = []
        var body: Data?
        var headers: [String: String] = [:]
        var needsToken = true
    }

    let governor: SchedulesDirectGovernor
    private let accountKey: String
    private let limiter: SchedulesDirectRequestLimiter
    private let tokenStore: SchedulesDirectTokenStore
    private let http: any HTTPClient
    private let clock: SchedulesDirectClock
    private let limits: SchedulesDirectLimits
    private let userAgent: String
    private let jitter: @Sendable () -> Double
    private var credentials: SchedulesDirectCredentials

    init(
        credentials: SchedulesDirectCredentials, storage: SchedulesDirectStorage,
        tokenStore: SchedulesDirectTokenStore, http: any HTTPClient, clock: SchedulesDirectClock,
        limits: SchedulesDirectLimits, userAgent: String, jitter: @escaping @Sendable () -> Double
    ) {
        self.credentials = credentials
        self.accountKey = credentials.accountKey
        self.tokenStore = tokenStore
        self.http = http
        self.clock = clock
        self.limits = limits
        self.userAgent = userAgent
        self.jitter = jitter
        self.governor = SchedulesDirectGovernor(
            accountKey: credentials.accountKey, storage: storage, clock: clock, limits: limits, jitter: jitter
        )
        self.limiter = SchedulesDirectRequestLimiter(maxConcurrent: limits.maxConcurrentRequests, clock: clock)
    }

    func update(credentials: SchedulesDirectCredentials) {
        self.credentials = credentials
    }

    // MARK: Token

    /// Reuses the stored token until shortly before it expires. A new token is
    /// requested only when none is valid, or explicitly (`forceNew`, "Reconnect").
    func token(forceNew: Bool = false) async throws -> String {
        if !forceNew, let stored = tokenStore.load(accountKey: accountKey),
           stored.expires.timeIntervalSince(clock.now()) > 300 {
            return stored.token
        }
        struct TokenBody: Encodable { let username: String; let password: String; let newToken: Bool? }
        let body = try JSONEncoder().encode(TokenBody(
            username: credentials.username, password: credentials.passwordHash, newToken: forceNew ? true : nil
        ))
        let data = try await send(Call(method: .post, path: "/token", body: body, needsToken: false))
        guard let response = try? JSONDecoder().decode(SchedulesDirectTokenResponse.self, from: data),
              let token = response.token, !token.isEmpty else {
            let attention = SchedulesDirectAttention(reason: .unexpectedResponse, message: "No token was returned.")
            await governor.recordAttention(attention)
            throw SchedulesDirectError.needsAttention(attention)
        }
        let expires = response.tokenExpires.map { Date(timeIntervalSince1970: $0) }
            ?? clock.now().addingTimeInterval(24 * 3600)
        try? tokenStore.save(SchedulesDirectStoredToken(token: token, expires: expires), accountKey: accountKey)
        return token
    }

    func clearToken() {
        try? tokenStore.clear(accountKey: accountKey)
    }

    // MARK: Requests

    /// Sends one logical call, governed: ledger admission, limiter, classification of
    /// every response, bounded retry for short back-pressure, persisted stop otherwise.
    func send(_ call: Call) async throws -> Data {
        var refreshedToken = false
        var attempt = 0
        while true {
            attempt += 1
            try await governor.admitRequest()
            var headers = call.headers
            headers["User-Agent"] = userAgent
            headers["Accept"] = "application/json"
            if call.body != nil { headers["Content-Type"] = "application/json" }
            if call.needsToken { headers["token"] = try await token() }
            let endpoint = Endpoint(
                method: call.method, path: SchedulesDirectEnvironment.apiPath + call.path, queryItems: call.query,
                headers: headers, body: call.body, redirectPolicy: .sameOrigin,
                allowsAutomaticAddressRetry: call.method == .get
            )
            let outcome = try await perform(endpoint)
            switch outcome {
            case let .success(data):
                await governor.recordSuccess()
                return data
            case .tokenExpired:
                guard call.needsToken, !refreshedToken else {
                    throw await stop(.init(reason: .unexpectedResponse, message: "The session token was rejected."))
                }
                refreshedToken = true
                clearToken()
                continue
            case let .backPressure(wait):
                let wait = wait ?? defaultRetryWait(attempt: attempt)
                if attempt < limits.maxAttemptsPerRequest, wait <= limits.maxInSyncRetryWait {
                    try await clock.sleep(wait + wait * 0.1 * min(max(jitter(), 0), 1))
                    continue
                }
                let date = await governor.recordBackPressure(serverWait: wait)
                PlozzLog.sync.info("Schedules Direct backing off until \(date.timeIntervalSince1970)")
                throw SchedulesDirectError.notBefore(date)
            case let .attention(attention):
                throw await stop(attention)
            case let .failure(error):
                throw error
            }
        }
    }

    func json<T: Decodable>(_ type: T.Type, _ call: Call) async throws -> T {
        let data = try await send(call)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            // A body we cannot interpret is treated like server trouble, never retried blindly.
            let date = await governor.recordBackPressure(serverWait: nil)
            throw SchedulesDirectError.notBefore(date)
        }
    }

    private func stop(_ attention: SchedulesDirectAttention) async -> SchedulesDirectError {
        PlozzLog.sync.error("Schedules Direct stopped: \(attention.reason.rawValue) code=\(attention.code.map(String.init) ?? "none")")
        await governor.recordAttention(attention)
        return .needsAttention(attention)
    }

    private func defaultRetryWait(attempt: Int) -> TimeInterval {
        2 * pow(2, Double(attempt - 1))
    }

    private enum Outcome {
        case success(Data)
        case tokenExpired
        case backPressure(TimeInterval?)
        case attention(SchedulesDirectAttention)
        case failure(SchedulesDirectError)
    }

    private func perform(_ endpoint: Endpoint) async throws -> Outcome {
        try await limiter.acquire()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.sendRaw(endpoint, baseURL: SchedulesDirectEnvironment.origin)
        } catch let error as AppError {
            await limiter.release()
            if error == .cancelled { throw CancellationError() }
            return .failure(.transport(error))
        } catch {
            await limiter.release()
            if error is CancellationError { throw error }
            return .failure(.transport(.serverUnreachable))
        }
        await limiter.release()
        return classify(data: data, response: response)
    }

    private func classify(data: Data, response: HTTPURLResponse) -> Outcome {
        let status = response.statusCode
        let headerWait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Self.retryAfter)
        if status == 429 || status == 503 { return .backPressure(headerWait) }
        let object = try? JSONSerialization.jsonObject(with: data)
        guard let object else {
            // HTML or any non-JSON body is the load balancer or an outage talking.
            return .backPressure(headerWait)
        }
        if let dictionary = object as? [String: Any], let code = Self.intValue(dictionary["code"]), code != 0 {
            let message = (dictionary["message"] as? String) ?? (dictionary["response"] as? String) ?? "Schedules Direct error \(code)"
            switch SchedulesDirectErrorCodes.classify(code) {
            case .ok: break
            case .tokenExpired: return .tokenExpired
            case .backPressure:
                return .backPressure(headerWait ?? Self.retryTime(dictionary["retryTime"], now: clock.now()))
            case let .attention(reason): return .attention(.init(reason: reason, message: message, code: code))
            case .lineupLimit: return .failure(.lineupLimitReached(message: message))
            case .lineupChanges: return .failure(.lineupChangesExhausted(message: message))
            case .item: return .failure(.request(code: code, message: message))
            }
        }
        if !(200...299).contains(status) {
            if status >= 500 { return .backPressure(headerWait) }
            return .attention(.init(reason: .unexpectedResponse, message: "Unexpected response (HTTP \(status)).", code: nil))
        }
        return .success(data)
    }

    static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func retryAfter(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return max(0, seconds) }
        return nil
    }

    /// `retryTime` is either seconds to wait or an ISO-8601 instant.
    static func retryTime(_ value: Any?, now: Date) -> TimeInterval? {
        if let seconds = value as? Double { return max(0, seconds) }
        if let text = value as? String {
            if let seconds = TimeInterval(text) { return max(0, seconds) }
            if let date = SchedulesDirectDates.parse(text) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }
}
