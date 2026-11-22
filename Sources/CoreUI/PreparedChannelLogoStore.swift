#if canImport(UIKit)
import CryptoKit
import Foundation
import UIKit

/// Permanent on-disk store of prepared channel logos (``ChannelLogoExtraction/Prepared``).
///
/// A prepared logo is final for its logo URL, the provider's dark-background flag and the theme, because the logo bytes are kept
/// permanently (``LiveTVLogoImageStore``). It is therefore computed once and read back on every later launch, so a relaunch does no
/// decode, ink analysis, trim or recolour. One file per key: a length-prefixed JSON header with the scalar results, then the PNG of
/// the trimmed image. Files live in Application Support, excluded from backup; the oldest are removed past ``capacityBytes``.
enum PreparedChannelLogoStore {
    /// Bump when the treatment in ``ChannelLogoExtraction/prepare(analysis:providerRequestsDarkBackground:whitensMixedInk:theme:)``
    /// changes, so stale results are not read.
    static let formatVersion = 1
    static let capacityBytes = 256 * 1_024 * 1_024

    /// Tests point this at a temporary directory.
    nonisolated(unsafe) static var directory: URL = defaultDirectory() {
        didSet { lock.withLock { runningBytes = nil; trimAt = capacityBytes; protectedKeys = [] } }
    }
    /// Counters for the relaunch test.
    nonisolated(unsafe) static var loadCount = 0
    nonisolated(unsafe) static var saveCount = 0
    /// How many times the whole directory was listed and statted; the O(N) bound is tested through this.
    nonisolated(unsafe) static var directoryScanCount = 0

    private struct Header: Codable {
        let aspect: Double
        let isDark: Bool
        let isLowQuality: Bool
        let readableShare: Double
        let needsTextFallback: Bool
        let inkFill: Double
    }

    private static let lock = NSLock()
    /// Bytes on disk: read from the directory once (on the first write), then kept current.
    nonisolated(unsafe) private static var runningBytes: Int?
    /// The size past which the next trim lists the directory. Trims go down to 90% of capacity, and when the protected files alone
    /// exceed capacity the threshold rises with them, so a full directory is not listed on every write.
    nonisolated(unsafe) private static var trimAt = capacityBytes
    /// Keys of logos a current station mark needs; a trim never removes them (prepared logos are final data).
    nonisolated(unsafe) private static var protectedKeys = Set<String>()

    /// Adds keys a trim must keep.
    static func protect(keys: Set<String>) { lock.withLock { protectedKeys.formUnion(keys) } }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Plozz", isDirectory: true)
            .appendingPathComponent("PreparedChannelLogos", isDirectory: true)
    }

    /// `variants` is the network logo's listed variants (the result depends on them); `nil` for a plain logo.
    static func key(url: URL, variants: [URL]?, providerRequestsDarkBackground: Bool, theme: ChannelLogoExtraction.Theme) -> String {
        let variantPart = variants.map { $0.prefix(5).map(\.absoluteString).joined(separator: ",") } ?? ""
        let text = "\(formatVersion)|\(providerRequestsDarkBackground ? 1 : 0)|\(theme.rawValue)|\(url.absoluteString)|\(variantPart)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load(key: String) -> ChannelLogoExtraction.Prepared? {
        let file = directory.appendingPathComponent(key + ".plogo")
        guard let data = try? Data(contentsOf: file), data.count > 4 else { return nil }
        let headerLength = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard headerLength > 0, data.count > 4 + headerLength,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 4..<(4 + headerLength))),
              let image = UIImage(data: data.subdata(in: (4 + headerLength)..<data.count)) else { return nil }
        lock.withLock { loadCount += 1 }
        return ChannelLogoExtraction.Prepared(
            image: image, aspect: header.aspect, isDark: header.isDark, isLowQuality: header.isLowQuality,
            readableShare: header.readableShare, needsTextFallback: header.needsTextFallback, inkFill: header.inkFill)
    }

    /// Saves in the background; a failure only means the logo is prepared again next launch.
    static func save(_ prepared: ChannelLogoExtraction.Prepared, key: String) {
        Task.detached(priority: .background) { write(prepared, key: key) }
    }

    static func write(_ prepared: ChannelLogoExtraction.Prepared, key: String) {
        guard let png = prepared.image.pngData(),
              let header = try? JSONEncoder().encode(Header(
                aspect: prepared.aspect, isDark: prepared.isDark, isLowQuality: prepared.isLowQuality,
                readableShare: prepared.readableShare, needsTextFallback: prepared.needsTextFallback, inkFill: prepared.inkFill))
        else { return }
        var data = Data((0..<4).map { UInt8((header.count >> (8 * (3 - $0))) & 0xFF) })
        data.append(header)
        data.append(png)
        let directory = Self.directory
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutable = directory
            try? mutable.setResourceValues(excluded)
        }
        let file = directory.appendingPathComponent(key + ".plogo")
        let needsScan = lock.withLock { runningBytes == nil }
        let initial = needsScan ? scan().reduce(0) { $0 + $1.size } : 0
        let replaced = (try? manager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        let shouldTrim = lock.withLock { () -> Bool in
            saveCount += 1
            runningBytes = (runningBytes ?? initial) - replaced + data.count
            return (runningBytes ?? 0) > trimAt
        }
        if shouldTrim { trim() }
    }

    private static func scan() -> [(url: URL, size: Int, date: Date)] {
        lock.withLock { directoryScanCount += 1 }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return files.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    /// Removes the oldest unprotected files down to 90% of ``capacityBytes`` once the directory passes it.
    static func trim(toBytes capacityBytes: Int = PreparedChannelLogoStore.capacityBytes) {
        var entries = scan()
        var total = entries.reduce(0) { $0 + $1.size }
        let protected = lock.withLock { protectedKeys }
        let target = capacityBytes / 10 * 9
        if total > capacityBytes {
            entries.sort { $0.date < $1.date }
            for entry in entries where total > target {
                if protected.contains(entry.url.deletingPathExtension().lastPathComponent) { continue }
                if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
            }
        }
        lock.withLock {
            runningBytes = total
            trimAt = max(capacityBytes, total + capacityBytes / 20)
        }
    }
}
#endif
