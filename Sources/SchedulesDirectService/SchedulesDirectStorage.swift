import Foundation

/// On-device files for Schedules Direct, under Application Support and excluded
/// from backup. Nothing is created until the feature is used.
public struct SchedulesDirectStorage: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func applicationSupport() -> SchedulesDirectStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SchedulesDirectStorage(root: base.appendingPathComponent("SchedulesDirect", isDirectory: true))
    }

    func directory(accountKey: String) -> URL {
        root.appendingPathComponent(accountKey, isDirectory: true)
    }

    func read<T: Decodable>(_ type: T.Type, name: String, accountKey: String) -> T? {
        let url = directory(accountKey: accountKey).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.sdStorage.decode(T.self, from: data)
    }

    func write<T: Encodable>(_ value: T, name: String, accountKey: String) throws -> Int {
        let directory = directory(accountKey: accountKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        let data = try JSONEncoder.sdStorage.encode(value)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return data.count
    }

    func remove(name: String, accountKey: String) {
        try? FileManager.default.removeItem(at: directory(accountKey: accountKey).appendingPathComponent(name))
    }

    func removeAll(accountKey: String) {
        try? FileManager.default.removeItem(at: directory(accountKey: accountKey))
    }
}

extension JSONEncoder {
    static var sdStorage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

extension JSONDecoder {
    static var sdStorage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
