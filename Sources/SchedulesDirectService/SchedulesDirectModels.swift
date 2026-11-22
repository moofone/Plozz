import Foundation

/// Wire models for the Schedules Direct JSON API (version 20141201). Decoding is
/// deliberately tolerant: the service adds fields without notice and reports
/// per-item problems inline, so almost everything is optional.

struct SchedulesDirectTokenResponse: Decodable, Sendable {
    let token: String?
    /// Epoch seconds at which the token stops working.
    let tokenExpires: TimeInterval?
    let serverTime: String?
}

public struct SchedulesDirectStatus: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        /// ISO-8601 instant at which the membership ends.
        public var expires: String?
        public var maxLineups: Int?
        public var messages: [String]?

        public init(expires: String? = nil, maxLineups: Int? = nil, messages: [String]? = nil) {
            self.expires = expires
            self.maxLineups = maxLineups
            self.messages = messages
        }
    }

    public struct LineupEntry: Codable, Equatable, Sendable {
        public var lineup: String
        public var modified: String?
        public var isDeleted: Bool?

        public init(lineup: String, modified: String? = nil, isDeleted: Bool? = nil) {
            self.lineup = lineup
            self.modified = modified
            self.isDeleted = isDeleted
        }
    }

    public struct SystemStatus: Codable, Equatable, Sendable {
        public var status: String?
        public var message: String?
    }

    public var account: Account?
    public var lineups: [LineupEntry]?
    public var lastDataUpdate: String?
    public var systemStatus: [SystemStatus]?

    public init(
        account: Account? = nil, lineups: [LineupEntry]? = nil,
        lastDataUpdate: String? = nil, systemStatus: [SystemStatus]? = nil
    ) {
        self.account = account
        self.lineups = lineups
        self.lastDataUpdate = lastDataUpdate
        self.systemStatus = systemStatus
    }

    /// The service reports itself offline; clients must not connect for an hour.
    var reportsOffline: Bool {
        systemStatus?.contains { $0.status?.lowercased() == "offline" } ?? false
    }

    public var accountExpiry: Date? {
        account?.expires.flatMap(SchedulesDirectDates.parse)
    }
}

public struct SchedulesDirectHeadend: Codable, Equatable, Sendable, Identifiable {
    public struct Lineup: Codable, Equatable, Sendable {
        public var name: String
        public var lineup: String
    }

    public var headend: String
    public var transport: String?
    public var location: String?
    public var lineups: [Lineup]

    public var id: String { headend }
}

public struct SchedulesDirectLineupPreviewEntry: Codable, Equatable, Sendable {
    public var channel: String?
    public var name: String?
    public var callsign: String?
    public var affiliate: String?
}

public struct SchedulesDirectAccountLineup: Codable, Equatable, Sendable, Identifiable {
    public var lineup: String
    public var name: String?
    public var transport: String?
    public var location: String?
    public var isDeleted: Bool?

    public var id: String { lineup }
}

struct SchedulesDirectAccountLineupsResponse: Decodable, Sendable {
    let lineups: [SchedulesDirectAccountLineup]?
}

struct SchedulesDirectLineupChangeResponse: Decodable, Sendable {
    let changesRemaining: Int?
}

public struct SchedulesDirectStation: Codable, Equatable, Sendable, Identifiable {
    public var stationID: String
    public var name: String?
    public var callsign: String?
    public var affiliate: String?
    public var broadcastLanguage: [String]?

    public var id: String { stationID }
}

struct SchedulesDirectLineupDetail: Decodable, Sendable {
    struct MapEntry: Decodable, Sendable {
        let stationID: String
    }

    struct Metadata: Decodable, Sendable {
        let modified: String?
    }

    let map: [MapEntry]?
    let stations: [SchedulesDirectStation]?
    let metadata: Metadata?
}

struct SchedulesDirectScheduleHash: Decodable, Equatable, Sendable {
    let code: Int?
    let md5: String?
}

struct SchedulesDirectScheduleRequest: Encodable, Sendable {
    let stationID: String
    let date: [String]
}

struct SchedulesDirectScheduleProgram: Codable, Equatable, Sendable {
    var programID: String
    var airDateTime: String
    var duration: Int?
    var md5: String?
    var liveTapeDelay: String?
    var new: Bool?
}

struct SchedulesDirectScheduleDay: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let startDate: String?
        let md5: String?
    }

    let stationID: String?
    let code: Int?
    let programs: [SchedulesDirectScheduleProgram]?
    let metadata: Metadata?
}

public struct SchedulesDirectProgram: Codable, Equatable, Sendable {
    public struct Title: Codable, Equatable, Sendable { public var title120: String? }
    public struct Descriptions: Codable, Equatable, Sendable {
        public struct Entry: Codable, Equatable, Sendable { public var description100: String?; public var description1000: String? }
        public var description100: [Entry]?
        public var description1000: [Entry]?
    }

    public var programID: String
    public var titles: [Title]?
    public var descriptions: Descriptions?
    public var genres: [String]?
    public var episodeTitle150: String?
    public var md5: String?
    public var code: Int?
}

enum SchedulesDirectDates {
    static func parse(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value) ?? withFraction.date(from: value)
    }

    /// `yyyy-MM-dd` in UTC, the only day form the schedule endpoints accept.
    static func utcDay(_ date: Date) -> String {
        let calendar = utcCalendar
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
}
