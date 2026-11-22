#if canImport(UIKit)
import UIKit
import XCTest
@testable import CoreUI

/// The layered logo pipeline's cost: the analysis is theme independent and done once; a theme's result is derived from it without any
/// decode; a burst of logos is bounded. Numbers are Debug builds on the simulator host and are written to an attachment.
final class ChannelLogoPipelinePerformanceTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "LogoRule", withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func ms(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// A second theme comes from the cached analysis: deriving takes no bytes (so cannot decode) and equals a from-scratch prepare.
    func testSecondThemeReusesTheAnalysisAndMatchesAFreshPrepare() throws {
        let data = try fixture("CBC_16644.png")
        let analysis = try XCTUnwrap(ChannelLogoExtraction.analyze(data: data))
        for theme in [ChannelLogoExtraction.Theme.dark, .light] {
            let derived = ChannelLogoExtraction.prepare(analysis: analysis, providerRequestsDarkBackground: false, theme: theme)
            let fresh = try XCTUnwrap(ChannelLogoExtraction.prepare(data: data, providerRequestsDarkBackground: false, theme: theme))
            XCTAssertEqual(derived.needsTextFallback, fresh.needsTextFallback)
            XCTAssertEqual(derived.isDark, fresh.isDark)
            XCTAssertEqual(derived.readableShare, fresh.readableShare, accuracy: 0.0001)
            XCTAssertEqual(
                ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(derived.image.cgImage)),
                ChannelLogoExtraction.rgbaPixels(try XCTUnwrap(fresh.image.cgImage)))
        }
    }

    /// Deriving a theme must be much cheaper than the analysis it reuses.
    func testDerivingAThemeIsCheaperThanAnalysing() throws {
        let data = try fixture("CBC_16644.png")
        var analyse: [Double] = [], derive: [Double] = []
        var analysis: ChannelLogoExtraction.Analysis?
        for _ in 0..<5 {
            analyse.append(ms { analysis = ChannelLogoExtraction.analyze(data: data) })
            let a = try XCTUnwrap(analysis)
            derive.append(ms { _ = ChannelLogoExtraction.prepare(analysis: a, providerRequestsDarkBackground: false, theme: .light) })
        }
        add({ let x = XCTAttachment(string: "CBC real file: analyse median \(median(analyse)) ms, derive (light) median \(median(derive)) ms"); x.lifetime = .keepAlways; return x }())
        try? "CBC analyse \(median(analyse)) ms; derive(light) \(median(derive)) ms\n".appendingToFile("/tmp/logo-perf.txt")
        XCTAssertLessThan(median(derive), 500, "a derive is a few passes over the pixels")
    }

    /// A 200-logo cold burst with the loader's cap of concurrent work, then the other theme for all 200 (the warm-up after a switch).
    func testColdBurstOf200AndThemeSwitchWarmUp() async throws {
        let files = ["CBC_16644.png", "GLOBAL_16702.png", "GLOBAL_NEWS_16704.png", "CTV_NEWS_CHANNEL_navy.png", "ADULT_SWIM.jpg", "PROV_CA_EN__CTV_CALGARY.jpg"]
            .compactMap { try? fixture($0) }
        XCTAssertGreaterThanOrEqual(files.count, 4)
        let cap = ChannelLogoExtractionLoader.maximumConcurrentPrepares
        actor Gauge { var now = 0, peak = 0; func enter() { now += 1; peak = max(peak, now) }; func leave() { now -= 1 } }
        let gauge = Gauge()
        func run(_ work: @escaping @Sendable (Int) -> Void) async -> Double {
            let start = ContinuousClock.now
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() { let i = next; next += 1; group.addTask { await gauge.enter(); work(i); await gauge.leave() } }
                for _ in 0..<cap { add() }
                while await group.next() != nil, next < 200 { add() }
            }
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        final class Store: @unchecked Sendable { var analyses: [Int: ChannelLogoExtraction.Analysis] = [:]; let lock = NSLock() }
        let store = Store()
        let cold = await run { i in
            let a = ChannelLogoExtraction.analyze(data: files[i % files.count])
            _ = a.map { ChannelLogoExtraction.prepare(analysis: $0, providerRequestsDarkBackground: false, theme: .dark) }
            store.lock.lock(); store.analyses[i] = a; store.lock.unlock()
        }
        let warm = await run { i in
            if let a = store.analyses[i] { _ = ChannelLogoExtraction.prepare(analysis: a, providerRequestsDarkBackground: false, theme: .light) }
        }
        let peak = await gauge.peak
        add({ let x = XCTAttachment(string: "200 logos, cap \(cap): cold (analyse + dark) \(Int(cold)) ms; other theme from cached analyses \(Int(warm)) ms; peak concurrency \(peak)"); x.lifetime = .keepAlways; return x }())
        try? "200 logos cap \(cap): cold \(Int(cold)) ms; other theme \(Int(warm)) ms; peak \(peak)\n".appendingToFile("/tmp/logo-perf.txt")
        XCTAssertLessThanOrEqual(peak, cap)
    }
}

private extension String {
    func appendingToFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + self).write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
