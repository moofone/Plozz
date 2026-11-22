import Foundation

/// A TV show's title logo from TMDB.
public struct TMDbShowLogo: Codable, Equatable, Sendable {
    public let showID: Int
    public let filePath: String

    public init(showID: Int, filePath: String) {
        self.showID = showID
        self.filePath = filePath
    }

    public var logoURL: URL? { TMDbNetworkLogoClient.imageURL(filePath: filePath) }
}

/// Chooses the TMDB show a 24/7 single-show channel carries: exact title only.
///
/// A trailing year in the channel name ("TEENAGE MUTANT NINJA TURTLES 2003") must equal the show's first air year. A leading "The" is
/// ignored on both sides. When several shows share the title, the most popular one wins only if it is at least twice as popular as the
/// runner-up; otherwise the title is a tie and stays unmatched.
public enum TMDbShowTitleMatch {
    public struct Candidate: Equatable, Sendable {
        public let id: Int
        public let name: String
        public let originalName: String
        public let firstAirYear: Int?
        public let popularity: Double

        public init(id: Int, name: String, originalName: String, firstAirYear: Int?, popularity: Double) {
            self.id = id
            self.name = name
            self.originalName = originalName
            self.firstAirYear = firstAirYear
            self.popularity = popularity
        }
    }

    /// The title to search for and the year the channel name ends with, if any.
    public static func query(from title: String) -> (name: String, year: Int?) {
        let pattern = #"^(.+?)\s*\(?((?:19|20)\d\d)\)?$"#
        guard let match = title.range(of: pattern, options: .regularExpression) else { return (title, nil) }
        let text = String(title[match])
        guard let yearRange = text.range(of: #"(?:19|20)\d\d\)?$"#, options: .regularExpression),
              let year = Int(text[yearRange].filter(\.isNumber)) else { return (title, nil) }
        let name = String(text[..<yearRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " ("))
        return name.isEmpty ? (title, nil) : (name, year)
    }

    public static func select(title: String, candidates: [Candidate]) -> Int? {
        let (name, year) = query(from: title)
        let wanted = comparable(name)
        guard !wanted.isEmpty else { return nil }
        var exact = candidates.filter { comparable($0.name) == wanted || comparable($0.originalName) == wanted }
        if let year { exact = exact.filter { $0.firstAirYear == year } }
        exact.sort { ($0.popularity, $1.id) > ($1.popularity, $0.id) }
        guard let best = exact.first else { return nil }
        if exact.count > 1, exact[1].popularity * 2 > best.popularity { return nil }
        return best.id
    }

    /// Case-, accent- and punctuation-insensitive comparison without a leading "the".
    static func comparable(_ text: String) -> String {
        var folded = text.decomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "&", with: "and").replacingOccurrences(of: "+", with: "plus")
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }))
    }
}

extension TMDbNetworkLogoClient {
    /// The title logo of the show whose name equals `title` (see ``TMDbShowTitleMatch``). `nil` when no single show matches or it has
    /// no logo in English or without a language; a thrown error means TMDB could not answer, so the caller retries later.
    public func showLogo(forTitle title: String) async throws -> TMDbShowLogo? {
        let (name, _) = TMDbShowTitleMatch.query(from: title)
        guard let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))),
              let search = try await get(ShowSearchResponse.self, path: "/3/search/tv?include_adult=false&query=\(query)") else { return nil }
        let candidates = search.results.map {
            TMDbShowTitleMatch.Candidate(
                id: $0.id, name: $0.name ?? "", originalName: $0.original_name ?? "",
                firstAirYear: $0.first_air_date.flatMap { Int($0.prefix(4)) }, popularity: $0.popularity ?? 0
            )
        }
        guard let id = TMDbShowTitleMatch.select(title: title, candidates: candidates),
              let images = try await get(ShowImagesResponse.self, path: "/3/tv/\(id)/images?include_image_language=en,null"),
              let best = Self.bestShowLogo(images.logos) else { return nil }
        return TMDbShowLogo(showID: id, filePath: best)
    }

    struct ShowSearchResponse: Decodable, Sendable {
        struct Result: Decodable, Sendable {
            let id: Int
            let name: String?
            let original_name: String?
            let first_air_date: String?
            let popularity: Double?
        }
        let results: [Result]
    }

    struct ShowImagesResponse: Decodable, Sendable {
        struct Logo: Decodable, Sendable {
            let file_path: String?
            let iso_639_1: String?
            let vote_average: Double?
            let width: Int?
        }
        let logos: [Logo]
    }

    /// The highest-voted English or language-less logo; ties go to the wider image, then the path.
    static func bestShowLogo(_ logos: [ShowImagesResponse.Logo]) -> String? {
        logos.filter { ($0.file_path?.hasPrefix("/") ?? false) && ($0.iso_639_1 == nil || $0.iso_639_1 == "en") }
            .min { lhs, rhs in
                let (left, right) = ((-(lhs.vote_average ?? 0), -(lhs.width ?? 0)), (-(rhs.vote_average ?? 0), -(rhs.width ?? 0)))
                if left != right { return left < right }
                return (lhs.file_path ?? "") < (rhs.file_path ?? "")
            }?.file_path
    }
}
