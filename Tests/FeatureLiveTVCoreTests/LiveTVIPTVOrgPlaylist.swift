import Foundation

/// Test data only: loads a local copy of the iptv-org public playlist as evaluation rows. Nothing from it is bundled or shipped.
enum LiveTVIPTVOrgPlaylist {
    /// `CTV2Atlantic.ca@SD` → `CA`; no suffix → `??`.
    static func countryCode(tvgID: String) -> String {
        guard let dot = tvgID.lastIndex(of: ".") else { return "??" }
        let tail = tvgID[tvgID.index(after: dot)...].prefix { $0 != "@" }
        return tail.count == 2 ? tail.uppercased() : "??"
    }

    /// The name part of a `tvg-id`: `CTV2Atlantic.ca@SD` → `CTV2Atlantic`.
    static func idName(tvgID: String) -> String {
        String(tvgID[..<(tvgID.lastIndex(of: ".") ?? tvgID.endIndex)])
    }

    /// A stable stand-in for a logo URL (FNV-1a), the way the export's `logoKey` stands in for one.
    static func stableKey(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    static func attributes(_ line: Substring) -> [String: String] {
        var result: [String: String] = [:]
        let scalars = Array(line)
        var index = 0
        while index < scalars.count {
            guard let equal = scalars[index...].firstIndex(of: "="), equal + 1 < scalars.count, scalars[equal + 1] == "\"" else { index += 1; continue }
            var keyStart = equal
            while keyStart > 0, scalars[keyStart - 1] != " " { keyStart -= 1 }
            let key = String(scalars[keyStart..<equal])
            guard let close = scalars[(equal + 2)...].firstIndex(of: "\"") else { break }
            result[key] = String(scalars[(equal + 2)..<close])
            index = close + 1
        }
        return result
    }

    /// Rows for every `#EXTINF` entry. `withCountry` gives the matcher the tvg-id's country as the channel's declared country (an upper
    /// bound: the app only has one when the provider declares it); otherwise the matcher gets none, as for most playlists.
    static func rows(path: String, withCountry: Bool) throws -> [LiveTVLogoMatchEvaluator.Row] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var rows: [LiveTVLogoMatchEvaluator.Row] = []
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXTINF") {
            guard let comma = line.lastIndex(of: ",") else { continue }
            let name = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let attributes = attributes(line[..<comma])
            let tvgID = attributes["tvg-id"]
            let logo = attributes["tvg-logo"].flatMap { $0.isEmpty ? nil : $0 }
            let code = tvgID.map { countryCode(tvgID: $0) }
            rows.append(.init(
                name: name, groups: attributes["group-title"].map { [$0] } ?? [], logoKey: logo.map(stableKey),
                hasLogo: logo != nil, guideID: nil, country: withCountry && code != "??" ? code : nil, tvgID: tvgID
            ))
        }
        return rows
    }
}
