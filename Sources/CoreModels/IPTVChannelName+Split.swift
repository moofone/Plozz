import Foundation

extension IPTVChannelName {
    /// The displayed name and the tags a provider wrote into a channel name.
    ///
    /// One documented rule set, applied to `cleaned(_:)` of the name with superscripts folded to ASCII:
    /// - **Prefix.** A leading upper-case ISO 3166 country code (`UK` means `GB`), optionally followed by an
    ///   ISO 639-1 language code, ended by `:` or ` |` (`CA EN:`, `CA:`, `CA|`, `|FR|`), becomes `.country`
    ///   and `.language` tags and leaves the name. Both codes must validate, otherwise the prefix stays
    ///   (`AB: News`). A prefix that would leave nothing stays.
    /// - **Trailing descriptors.** Words at the end that are feed descriptors (`HD FHD UHD 4K 8K HDR RAW BK`,
    ///   `NNfps`, `NNNp`, brackets allowed, `HD/RAW` joined by `/`) become tags and leave the name.
    ///   `SD`, codecs (`HEVC H264 H265`) and unmapped `NNNp` sizes leave the name without a tag.
    ///   Bare numbers and `+1` stay, so `CHANNEL 4` is intact. The name is never emptied.
    /// - Tags are ordered country, language, then descriptors as written; duplicates are dropped.
    ///
    /// The tags do not depend on the clean-names setting: callers choose whether to show `name`.
    public static func split(_ name: String) -> (name: String, tags: [IPTVChannelTag]) {
        // The ASCII path reads the cleaned bytes directly; both paths then share `splitCleaned`.
        if let result = cleanedASCII(name, splitCleaned) { return result }
        let folded = foldingSuperscripts(name)
        if folded != name, let result = cleanedASCII(folded, splitCleaned) { return result }
        var text = cleanedUnicode(folded)
        return text.withUTF8(splitCleaned)
    }

    private static func splitCleaned(_ bytes: UnsafeBufferPointer<UInt8>) -> (name: String, tags: [IPTVChannelTag]) {
        var end = bytes.count
        var descriptors: [IPTVChannelTag] = []
        // Trailing descriptors, scanned from the end.
        while true {
            while end > 0, bytes[end - 1] == 0x20 { end -= 1 }
            var wordStart = end
            while wordStart > 0, bytes[wordStart - 1] != 0x20 { wordStart -= 1 }
            guard wordStart > 0, wordStart < end,
                  let found = descriptor(in: bytes, wordStart, end) else { break }
            descriptors.append(contentsOf: found.reversed())
            end = wordStart
        }
        var start = 0
        var tags = parsePrefix(bytes, end: end, start: &start)
        for tag in descriptors.reversed() where !tags.contains(tag) { tags.append(tag) }
        return (String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self), tags)
    }

    // MARK: Superscripts

    /// `name` with superscript and modifier letters, digits and brackets replaced by ASCII; `name` itself when it has none.
    public static func foldingSuperscripts(_ name: String) -> String {
        guard name.utf8.contains(where: { $0 >= 0x80 }) else { return name }
        var folded = String.UnicodeScalarView()
        var changed = false
        for scalar in name.unicodeScalars {
            if let ascii = superscriptASCII[scalar.value] {
                folded.append(Unicode.Scalar(ascii))
                changed = true
            } else {
                folded.append(scalar)
            }
        }
        return changed ? String(folded) : name
    }

    /// Capitals fold to upper case and lower-case forms to lower case.
    private static let superscriptASCII: [UInt32: UInt8] = {
        var table: [UInt32: UInt8] = [:]
        let upper: [(UInt32, Character)] = [
            (0x1D2C, "A"), (0x1D2E, "B"), (0x1D30, "D"), (0x1D31, "E"), (0x1D33, "G"), (0x1D34, "H"), (0x1D35, "I"),
            (0x1D36, "J"), (0x1D37, "K"), (0x1D38, "L"), (0x1D39, "M"), (0x1D3A, "N"), (0x1D3C, "O"), (0x1D3E, "P"),
            (0x1D3F, "R"), (0x1D40, "T"), (0x1D41, "U"), (0x2C7D, "V"), (0x1D42, "W")
        ]
        let lower: [(UInt32, Character)] = [
            (0x1D43, "a"), (0x1D47, "b"), (0x1D9C, "c"), (0x1D48, "d"), (0x1D49, "e"), (0x1DA0, "f"), (0x1D4D, "g"),
            (0x02B0, "h"), (0x2071, "i"), (0x02B2, "j"), (0x1D4F, "k"), (0x02E1, "l"), (0x1D50, "m"), (0x207F, "n"),
            (0x1D52, "o"), (0x1D56, "p"), (0x02B3, "r"), (0x02E2, "s"), (0x1D57, "t"), (0x1D58, "u"), (0x1D5B, "v"),
            (0x02B7, "w"), (0x02E3, "x"), (0x02B8, "y"), (0x1DBB, "z")
        ]
        for (value, character) in upper + lower { table[value] = character.asciiValue }
        let digits: [(UInt32, Character)] = [
            (0x2070, "0"), (0x00B9, "1"), (0x00B2, "2"), (0x00B3, "3"), (0x2074, "4"), (0x2075, "5"),
            (0x2076, "6"), (0x2077, "7"), (0x2078, "8"), (0x2079, "9"), (0x207A, "+"), (0x207B, "-"),
            (0x207D, "("), (0x207E, ")")
        ]
        for (value, character) in digits { table[value] = character.asciiValue }
        return table
    }()

    // MARK: Trailing descriptors

    private enum Descriptor {
        case tag(IPTVChannelTag)
        case dropped
    }

    /// Up to eight upper-case bytes packed into an integer; `nil` for longer or non-ASCII input.
    private static func packed(_ bytes: UnsafeBufferPointer<UInt8>, _ lower: Int, _ upper: Int) -> UInt64? {
        guard upper - lower <= 8 else { return nil }
        var value: UInt64 = 0
        var index = lower
        while index < upper {
            var byte = bytes[index]
            if byte >= 0x61, byte <= 0x7A { byte -= 0x20 }
            value = value << 8 | UInt64(byte)
            index += 1
        }
        return value
    }

    private static func namedDescriptor(_ key: UInt64) -> Descriptor? {
        switch key {
        case 0x4844: .tag(.hd)             // HD
        case 0x464844: .tag(.fhd)          // FHD
        case 0x554844: .tag(.uhd)          // UHD
        case 0x344B: .tag(.k4)             // 4K
        case 0x384B: .tag(.k8)             // 8K
        case 0x484452, 0x4844523130: .tag(.hdr) // HDR, HDR10
        case 0x524157: .tag(.raw)          // RAW
        case 0x424B: .tag(.backup)         // BK
        case 0x5344,                       // SD
             0x48455643,                   // HEVC
             0x48323634, 0x48323635,       // H264, H265
             0x482E323634, 0x482E323635:   // H.264, H.265
            .dropped
        default: nil
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func descriptorPart(_ bytes: UnsafeBufferPointer<UInt8>, _ lower: Int, _ upper: Int) -> Descriptor? {
        guard upper > lower, let key = packed(bytes, lower, upper) else { return nil }
        if let named = namedDescriptor(key) { return named }
        func number(_ from: Int, _ to: Int) -> Int? {
            guard from < to, to - from <= 4 else { return nil }
            var value = 0
            var index = from
            while index < to {
                guard isDigit(bytes[index]) else { return nil }
                value = value * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            return value
        }
        let length = upper - lower
        func upperByte(_ index: Int) -> UInt8 { bytes[index] & 0xDF }
        if length >= 4, upperByte(upper - 1) == 0x53, upperByte(upper - 2) == 0x50, upperByte(upper - 3) == 0x46,
           let rate = number(lower, upper - 3), (1...240).contains(rate) {
            return .tag(.fps(rate))
        }
        if length >= 4, upperByte(upper - 1) == 0x50, let size = number(lower, upper - 1) {
            switch size {
            case 720: return .tag(.hd)
            case 1080: return .tag(.fhd)
            case 2160, 3840: return .tag(.k4)
            case 4320, 7680: return .tag(.k8)
            case 480, 540, 576, 1440: return .dropped
            default: return nil
            }
        }
        return nil
    }

    /// The tags of one trailing word, `nil` when it is not a descriptor. Brackets and `/` joins are allowed.
    private static func descriptor(in raw: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> [IPTVChannelTag]? {
        var lower = start
        var upper = end
        while lower < upper, raw[lower] == 0x28 || raw[lower] == 0x5B { lower += 1 }
        while upper > lower, raw[upper - 1] == 0x29 || raw[upper - 1] == 0x5D { upper -= 1 }
        guard upper > lower, upper - lower <= 24 else { return nil }
        // Most trailing words are plain words; only these first letters can start a descriptor.
        switch raw[lower] & 0xDF {
        case 0x48, 0x46, 0x55, 0x52, 0x42, 0x53: break // H F U R B S
        default: guard isDigit(raw[lower]) else { return nil }
        }
        var tags: [IPTVChannelTag] = []
        var partStart = lower
        var index = lower
        while index <= upper {
            if index == upper || raw[index] == 0x2F {
                guard let part = descriptorPart(raw, partStart, index) else { return nil }
                if case let .tag(tag) = part { tags.append(tag) }
                partStart = index + 1
            }
            index += 1
        }
        return tags
    }

    // MARK: Prefix

    /// Two ASCII letters packed as `first << 8 | second`, upper-cased.
    static func pairKey(_ code: String) -> UInt16? {
        let bytes = Array(code.utf8)
        guard bytes.count == 2 else { return nil }
        return UInt16(bytes[0] & 0xDF) << 8 | UInt16(bytes[1] & 0xDF)
    }
    static let regionCodes: Set<UInt16> = Set(Locale.Region.isoRegions.compactMap { pairKey($0.identifier) })
    static let languageCodes: Set<UInt16> = Set(Locale.LanguageCode.isoLanguageCodes.compactMap { pairKey($0.identifier) })

    /// Sets `start` past a valid country (and language) prefix and returns its tags.
    private static func parsePrefix(_ bytes: UnsafeBufferPointer<UInt8>, end: Int, start: inout Int) -> [IPTVChannelTag] {
        func upperPair(_ at: Int) -> UInt16? {
            guard at + 2 <= end, bytes[at] >= 0x41, bytes[at] <= 0x5A, bytes[at + 1] >= 0x41, bytes[at + 1] <= 0x5A
            else { return nil }
            return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
        }
        func text(_ key: UInt16) -> String { String(decoding: [UInt8(key >> 8), UInt8(key & 0xFF)], as: UTF8.self) }
        /// The index past a `:` or ` |` delimiter at `at`, with following spaces skipped; `nil` when absent or nothing follows.
        func delimiterEnd(_ at: Int) -> Int? {
            var index: Int
            if at < end, bytes[at] == 0x3A { index = at + 1 }
            else if at + 1 < end, bytes[at] == 0x20, bytes[at + 1] == 0x7C { index = at + 2 }
            else { return nil }
            while index < end, bytes[index] == 0x20 { index += 1 }
            return index < end ? index : nil
        }
        guard var country = upperPair(0) else { return [] }
        if country == 0x554B { country = 0x4742 } // UK is the common name for GB
        guard regionCodes.contains(country) else { return [] }
        if let next = delimiterEnd(2) {
            start = next
            return [.country(text(country))]
        }
        guard end > 3, bytes[2] == 0x20, let language = upperPair(3),
              languageCodes.contains(language), let next = delimiterEnd(5) else { return [] }
        start = next
        return [.country(text(country)), .language(text(language))]
    }
}
