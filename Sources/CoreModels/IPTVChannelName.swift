import Foundation

/// Display cleanup only. Never use the result as a channel identity or guide-matching key.
public enum IPTVChannelName {
    /// Prefer affected names, retaining at most three distinct preview rows.
    public static func previewSamples(from names: some Sequence<String>) -> [String] {
        let limit = 3
        var changed: [(name: String, cleaned: String)] = []
        var unchanged: [String] = []
        for name in names {
            let value = split(name).name
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if value != name {
                guard !changed.contains(where: { $0.cleaned == value }) else { continue }
                changed.append((name, value))
                if changed.count == limit { return changed.map(\.name) }
            } else if unchanged.count < limit, !unchanged.contains(name) {
                unchanged.append(name)
            }
        }
        return Array((changed.map(\.name) + unchanged.filter { name in
            !changed.contains(where: { $0.cleaned == name })
        }).prefix(limit))
    }

    /// A provider's section header rather than a channel, such as `#### CANADA NEWS ####`.
    /// The shape is the one `cleaned` strips: runs of `#` or `*` at both ends around letters or digits.
    /// Three or more on each side is a marker. Exactly two is a marker only when the inside text,
    /// normalised (upper case, letters and digits, superscripts folded), equals, contains or is
    /// contained by the group label after its `CC|` prefix, so "## UK|BBC One H D ##" stays a channel.
    public static func isSectionMarker(name: String, groupTitle: String?) -> Bool {
        // Nearly every channel fails here, so the name is not rebuilt for it (this runs for every channel of a 43,000-channel lineup).
        guard let opening = name.first(where: { !$0.isWhitespace }), opening == "#" || opening == "*" else { return false }
        let value = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let marker = value.first, marker == "#" || marker == "*" else { return false }
        let leading = value.prefix { $0 == marker }.count
        let trailing = value.reversed().prefix { $0 == marker }.count
        guard leading >= 2, trailing >= 2, leading + trailing < value.count else { return false }
        let inner = value.dropFirst(leading).dropLast(trailing).trimmingCharacters(in: .whitespaces)
        guard inner.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        // A slot named for an event is a channel (it belongs to the Events path), however it is decorated.
        guard !looksLikeEvent(inner) else { return false }
        if leading >= 3, trailing >= 3 { return true }
        guard leading == 2, trailing == 2, let groupTitle else { return false }
        let label = groupTitle.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? groupTitle
        let group = normalizedForMarker(label), text = normalizedForMarker(inner)
        if !group.isEmpty && !text.isEmpty && (text.contains(group) || group.contains(text)) { return true }
        // "## DISNEY+ ORIGINAL RAW ##" under "US| DISNEY+ NETWORK RAW": it opens with the group's own first word, a label for the run.
        let firstWord = { (text: String) in text.split(separator: " ").first.map { normalizedForMarker(String($0)) } ?? "" }
        let innerFirst = firstWord(inner), groupFirst = firstWord(label)
        return innerFirst.count >= 4 && innerFirst == groupFirst
    }

    /// ` vs `, ` @ ` or ` at ` between two words; a clock time; a date stamp; the placeholder text.
    private static let eventPatterns = [
        #"\S\s+(vs\.?|v|@|at)\s+\S"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"\b20\d\d-\d\d-\d\d\b"#,
        #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b"#,
        #"no\s+event\s+streaming"#
    ]

    public static func looksLikeEvent(_ text: String) -> Bool {
        eventPatterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static func normalizedForMarker(_ text: String) -> String {
        String(text.decomposedStringWithCompatibilityMapping.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    public static func cleaned(_ name: String) -> String {
        // Most lineups are ASCII, and a large one cleans tens of thousands of names
        // while Live TV opens. The byte path applies the same rules without Unicode work.
        cleanedASCII(name) { String(decoding: $0, as: UTF8.self) } ?? cleanedUnicode(name)
    }

    static func cleanedUnicode(_ name: String) -> String {
        var value = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let marker = value.first, marker == "#" || marker == "*" {
            let leading = value.prefix { $0 == marker }.count
            let trailing = value.reversed().prefix { $0 == marker }.count
            if leading >= 2, trailing >= 2, leading + trailing < value.count {
                let content = value.dropFirst(leading).dropLast(trailing)
                    .trimmingCharacters(in: .whitespaces)
                if content.contains(where: { $0.isLetter || $0.isNumber }) { value = content }
            }
        }

        var words = value.replacingOccurrences(of: "|", with: " | ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        // Keep the tag itself: a short uppercase prefix is not proof of a country.
        if words.count > 3, words[0] == "|", words[2] == "|",
           (2...5).contains(words[1].count),
           words[1].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
            words.removeFirst()
        }

        var end = words.count
        while end > 1 {
            if let tag = spacedTags.first(where: {
                end > $0.count && Array(words[(end - $0.count)..<end]) == $0
            }) {
                words.replaceSubrange((end - tag.count)..<end, with: [tag.joined()])
                end -= tag.count
            } else {
                let word = words[end - 1]
                let normalized = superscriptTags[word] ?? word
                guard isFeedDescriptor(normalized) else { break }
                words[end - 1] = normalized
                end -= 1
            }
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? name : result
    }

    /// The rules of `cleanedUnicode` for an ASCII name; `nil` for any other name.
    /// Plain loops over bytes: this also has to be quick in unoptimized builds.
    /// `finish` receives the cleaned bytes, so a caller can read them without a `String` in between.
    static func cleanedASCII<Result>(
        _ name: String, _ finish: (UnsafeBufferPointer<UInt8>) -> Result
    ) -> Result? {
        var contiguous = name
        return contiguous.withUTF8 { bytes -> Result? in
            let count = bytes.count
            var index = 0
            while index < count {
                if bytes[index] >= 0x80 { return nil }
                index += 1
            }
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count + 1) { value -> Result in
                // Whitespace runs collapse to one space; leading and trailing runs vanish.
                var length = 0
                var pendingSpace = false
                index = 0
                while index < count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) {
                        pendingSpace = length > 0
                    } else {
                        if pendingSpace { value[length] = 0x20; length += 1; pendingSpace = false }
                        value[length] = byte
                        length += 1
                    }
                }
                var lower = 0
                var upper = length
                if length > 0, value[0] == 0x23 || value[0] == 0x2A {
                    let marker = value[0]
                    var leading = 0
                    while leading < length, value[leading] == marker { leading += 1 }
                    var trailing = 0
                    while trailing < length, value[length - 1 - trailing] == marker { trailing += 1 }
                    if leading >= 2, trailing >= 2, leading + trailing < length {
                        var start = leading
                        var end = length - trailing
                        while start < end, value[start] == 0x20 { start += 1 }
                        while end > start, value[end - 1] == 0x20 { end -= 1 }
                        var scan = start
                        while scan < end, !isASCIILetterOrDigit(value[scan]) { scan += 1 }
                        if scan < end { lower = start; upper = end }
                    }
                }

                // Words live in stack buffers: `starts[i]..<ends[i]` is a byte range of `value`.
                // `tagAt[i]` is 1 + the index of the spaced tag that word `i` starts (0 for none) and
                // `skip[i]` how many words that tag joined.
                let capacity = count + 2
                return withUnsafeTemporaryAllocation(of: Int.self, capacity: capacity * 2) { ranges -> Result in
                    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: capacity * 2) { marks -> Result in
                        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count * 3 + 1) { output -> Result in
                            let starts = ranges.baseAddress!
                            let ends = ranges.baseAddress! + capacity
                            let tagAt = marks.baseAddress!
                            let skip = marks.baseAddress! + capacity
                            var wordTotal = 0
                            var wordStart = -1
                            index = lower
                            while index < upper {
                                let byte = value[index]
                                if byte == 0x20 || byte == 0x7C {
                                    if wordStart >= 0 { starts[wordTotal] = wordStart; ends[wordTotal] = index; wordTotal += 1; wordStart = -1 }
                                    if byte == 0x7C { starts[wordTotal] = index; ends[wordTotal] = index + 1; wordTotal += 1 }
                                } else if wordStart < 0 {
                                    wordStart = index
                                }
                                index += 1
                            }
                            if wordStart >= 0 { starts[wordTotal] = wordStart; ends[wordTotal] = upper; wordTotal += 1 }
                            var first = 0
                            var wordCount = wordTotal
                            if wordCount > 3, ends[0] - starts[0] == 1, value[starts[0]] == 0x7C,
                               ends[2] - starts[2] == 1, value[starts[2]] == 0x7C,
                               ends[1] - starts[1] >= 2, ends[1] - starts[1] <= 5 {
                                var scan = starts[1]
                                while scan < ends[1], isASCIIUppercase(value[scan]) || isASCIIDigit(value[scan]) { scan += 1 }
                                if scan == ends[1] { first = 1 }
                            }
                            wordCount -= first
                            guard wordCount > 0 else { return finish(bytes) }

                            // Spaced tags ("H D") at the end are joined, however many descriptors follow them.
                            var anyTag = false
                            var end = wordCount
                            while end > 1 {
                                var matched = -1
                                var candidate = 0
                                while candidate < asciiSpacedTags.count, matched < 0 {
                                    let tag = asciiSpacedTags[candidate]
                                    if end > tag.count {
                                        var offset = 0
                                        while offset < tag.count {
                                            let word = first + end - tag.count + offset
                                            if ends[word] - starts[word] != 1 || value[starts[word]] != tag[offset] { break }
                                            offset += 1
                                        }
                                        if offset == tag.count { matched = candidate }
                                    }
                                    candidate += 1
                                }
                                if matched >= 0 {
                                    let size = asciiSpacedTags[matched].count
                                    if !anyTag {
                                        anyTag = true
                                        var clear = 0
                                        while clear < wordTotal { tagAt[clear] = 0; clear += 1 }
                                    }
                                    tagAt[first + end - size] = UInt8(matched + 1)
                                    skip[first + end - size] = UInt8(size)
                                    end -= size
                                } else {
                                    let word = first + end - 1
                                    guard isASCIIFeedDescriptor(value, starts[word], ends[word]) else { break }
                                    end -= 1
                                }
                            }
                            var length = 0
                            var word = first
                            while word < wordTotal {
                                if word > first { output[length] = 0x20; length += 1 }
                                if anyTag, tagAt[word] != 0 {
                                    for byte in asciiSpacedTags[Int(tagAt[word]) - 1] { output[length] = byte; length += 1 }
                                    word += Int(skip[word])
                                } else {
                                    var scan = starts[word]
                                    while scan < ends[word] { output[length] = value[scan]; length += 1; scan += 1 }
                                    word += 1
                                }
                            }
                            return finish(UnsafeBufferPointer(rebasing: output[0..<length]))
                        }
                    }
                }
            }
        }
    }

    private static let asciiSpacedTags: [[UInt8]] = spacedTags.map { $0.flatMap { Array($0.utf8) } }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isASCIIUppercase(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || isASCIIUppercase(byte) || (byte >= 0x61 && byte <= 0x7A)
    }
    private static func isASCIIBracket(_ byte: UInt8) -> Bool {
        byte == 0x28 || byte == 0x29 || byte == 0x5B || byte == 0x5D
    }

    private static func isASCIIFeedDescriptor(
        _ value: UnsafeMutableBufferPointer<UInt8>, _ start: Int, _ end: Int
    ) -> Bool {
        var lower = start
        var upper = end
        while lower < upper, isASCIIBracket(value[lower]) { lower += 1 }
        while upper > lower, isASCIIBracket(value[upper - 1]) { upper -= 1 }
        func byte(_ index: Int) -> UInt8 {
            let raw = value[index]
            return raw >= 0x61 && raw <= 0x7A ? raw - 0x20 : raw
        }
        func allDigits(_ from: Int, _ to: Int) -> Bool {
            guard from < to else { return false }
            var scan = from
            while scan < to, isASCIIDigit(value[scan]) { scan += 1 }
            return scan == to
        }
        let length = upper - lower
        // Every named descriptor starts with a letter or digit and has two to five characters:
        // packed into an integer (upper-cased) it is matched without building a string.
        if length >= 2, length <= 5 {
            var key: UInt64 = 0
            var scan = 0
            while scan < length { key = key << 8 | UInt64(byte(lower + scan)); scan += 1 }
            if isPackedFeedDescriptor(key) { return true }
        }
        if length >= 3, byte(upper - 3) == 0x46, byte(upper - 2) == 0x50, byte(upper - 1) == 0x53 {
            return allDigits(lower, upper - 3)
        }
        if length >= 1, byte(upper - 1) == 0x50 { return allDigits(lower, upper - 1) }
        if length >= 1, value[lower] == 0x2B { return allDigits(lower + 1, upper) }
        return allDigits(lower, upper)
    }

    /// `feedDescriptors` as packed upper-case bytes (`HD` is 0x4844).
    private static func isPackedFeedDescriptor(_ key: UInt64) -> Bool {
        switch key {
        case 0x4844, 0x464844, 0x554844, 0x5344,           // HD FHD UHD SD
             0x344B, 0x384B, 0x484452, 0x4844523130,       // 4K 8K HDR HDR10
             0x48455643, 0x48323634, 0x48323635,           // HEVC H264 H265
             0x482E323634, 0x482E323635: true              // H.264 H.265
        default: false
        }
    }

    private static let spacedTags = [
        ["U", "H", "D"], ["F", "H", "D"], ["H", "D"], ["S", "D"]
    ]
    private static let superscriptTags = [
        "\u{1D34}\u{1D30}": "HD",
        "\u{1DA0}\u{1D34}\u{1D30}": "FHD",
        "\u{1D41}\u{1D34}\u{1D30}": "UHD",
        "\u{02E2}\u{1D30}": "SD"
    ]
    private static let feedDescriptors: Set<String> = [
        "HD", "FHD", "UHD", "SD", "4K", "8K", "HDR", "HDR10", "HEVC", "H264", "H265", "H.264", "H.265"
    ]

    private static func isFeedDescriptor(_ word: String) -> Bool {
        let token = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]")).uppercased()
        if feedDescriptors.contains(token) { return true }
        let number: Substring
        if token.hasSuffix("FPS") { number = token.dropLast(3) }
        else if token.hasSuffix("P") { number = token.dropLast() }
        else if token.hasPrefix("+") { number = token.dropFirst() }
        else { number = token[...] }
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
