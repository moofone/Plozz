import XCTest

/// Right from the channel column (the plate) onto the leftmost guide cell must respond as quickly as a Right between
/// two programmes. Both are measured on the same row, interleaved, on the production-wired guide (pinned navigation),
/// with the fixture's in-app `GuideNavigationRecorder`: app receipt of the press (`UIApplication.sendEvent`), the
/// native focus notification, and the first display-link frame that shows the new focus, all on `CACurrentMediaTime`.
final class LiveTVGuidePlateRightRemoteTests: XCTestCase {
    private static let frame = 1.0 / 60

    @MainActor
    func testRightFromPlateRespondsLikeRightInsideTheGuide() throws {
        let guide = try GuideTimeline(test: self)
        defer { guide.app.terminate() }
        var now = try guide.enterFirstProgramme()
        var plate: [GuideTimeline.Press] = []
        var inside: [GuideTimeline.Press] = []
        var leftBack: [GuideTimeline.Press] = []
        var leftOntoPlate: [GuideTimeline.Press] = []
        for _ in 0..<32 {
            let next = try guide.press(.right, expecting: { $0.hasPrefix("row-1:") && $0 != now })
            inside.append(next)
            let back = try guide.press(.left, expecting: { $0 == now })
            leftBack.append(back)
            now = back.destination
            leftOntoPlate.append(try guide.press(.left, expecting: { $0 == "row-1:station" }))
            // Lands where it always has: the programme on now, the one just left.
            plate.append(try guide.press(.right, expecting: { $0 == now }))
        }
        let report = guide.report([("A right from plate", plate), ("B right inside guide", inside),
                                   ("C left onto plate", leftOntoPlate), ("D left back to now", leftBack)])
        let a = GuideTimeline.Summary(plate.map(\.toFrame))
        let b = GuideTimeline.Summary(inside.map(\.toFrame))
        let aFocus = GuideTimeline.Summary(plate.map(\.toFocus))
        let bFocus = GuideTimeline.Summary(inside.map(\.toFocus))
        XCTAssertLessThanOrEqual(aFocus.median - bFocus.median, Self.frame, "Median press-to-focus gap exceeds a frame.\n\(report)")
        XCTAssertLessThanOrEqual(a.median - b.median, Self.frame, "Median press-to-frame gap exceeds a frame.\n\(report)")
        XCTAssertLessThanOrEqual(a.p95 - b.p95, Self.frame, "p95 press-to-frame gap exceeds a frame.\n\(report)")
    }

    /// After the guide was paged away from now and brought back, Right from the plate still lands on the programme on
    /// now, and leaves the timeline where it was.
    @MainActor
    func testRightFromPlateAfterPagingLandsOnTheProgrammeOnNow() throws {
        let guide = try GuideTimeline(test: self)
        defer { guide.app.terminate() }
        let now = try guide.enterFirstProgramme()
        for _ in 0..<8 { _ = try guide.press(.right, expecting: { $0.hasPrefix("row-1:") && $0 != now }) }
        let paged = guide.timelineOffset
        XCTAssertGreaterThan(paged, 1, "The guide did not page")
        var destination = ""
        for _ in 0..<8 where destination != now {
            destination = try guide.press(.left, expecting: { $0.hasPrefix("row-1:") }).destination
        }
        XCTAssertEqual(destination, now)
        _ = try guide.press(.left, expecting: { $0 == "row-1:station" })
        let atPlate = guide.timelineOffset
        _ = try guide.press(.right, expecting: { $0 == now })
        XCTAssertEqual(guide.timelineOffset, atPlate, accuracy: 1, "Right from the plate moved the timeline")
        // And once more from the plate, with the timeline left where the first entry put it.
        _ = try guide.press(.left, expecting: { $0 == "row-1:station" })
        _ = try guide.press(.right, expecting: { $0 == now })
        XCTAssertEqual(guide.timelineOffset, atPlate, accuracy: 1, "Right from the plate moved the timeline")
    }
}

/// Drives the fixture guide one press at a time and reads the recorder's timeline after each.
@MainActor
private final class GuideTimeline {
    struct Press {
        let destination: String
        /// App receipt of the press to its native focus notification.
        let toFocus: Double
        /// App receipt of the press to the first display-link frame showing the new focus.
        let toFrame: Double
        /// How long the remote button was held.
        let hold: Double
        /// App receipt of the press to the guide's own focus request (`requestRowFocus`), when it made one.
        let toRequest: Double
    }

    struct Summary {
        let median: Double
        let p95: Double
        let max: Double
        init(_ values: [Double]) {
            let sorted = values.sorted()
            func rank(_ q: Double) -> Double {
                sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int((q * Double(sorted.count)).rounded(.up)) - 1)]
            }
            median = rank(0.5)
            p95 = rank(0.95)
            max = sorted.last ?? .nan
        }
    }

    /// A click as a person makes it on the remote: down, then up a moment later. The same for every press.
    static let click: TimeInterval = 0.12

    let app: XCUIApplication
    private let dir: URL
    private unowned let test: XCTestCase
    private var part = 0
    private var lastSamples = ""

    init(test: XCTestCase) throws {
        self.test = test
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plate-right-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--live-root-fixture", "--visual-focus-fixture", "--live-root-pinned-guide"]
        app.launchEnvironment["PLOZZ_GUIDE_PROFILE_DIR"] = dir.path
        app.launch()
    }

    /// Focus the programme on now in row 1 and return its recorder name.
    func enterFirstProgramme() throws -> String {
        let first = app.buttons["live-tv-channel-channels-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        var current = destination(try checkpoint())
        if app.buttons["live-tv-heading"].hasFocus {
            XCUIRemote.shared.press(.down)
            current = destination(try settle { $0 == "row-1:station" })
        }
        if current == "row-1:station" {
            XCUIRemote.shared.press(.right)
            current = destination(try settle { $0.hasPrefix("row-1:") && $0 != "row-1:station" })
        }
        let start = try XCTUnwrap(current, "No guide focus")
        guard start.hasPrefix("row-1:"), start != "row-1:station" else {
            throw NSError(domain: "No programme focus on row 1: \(start)", code: 1)
        }
        return start
    }

    var timelineOffset: Double {
        var offset = Double.nan
        for line in lastSamples.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count >= 12, fields[0] == "frame", let x = Double(fields[11]) { offset = x }
        }
        return offset
    }

    func press(_ button: XCUIRemote.Button, expecting accepts: (String) -> Bool,
               file: StaticString = #filePath, line: UInt = #line) throws -> Press {
        XCUIRemote.shared.press(button, forDuration: Self.click)
        let samples = try settle(accepts)
        let landed = destination(samples) ?? "missing"
        XCTAssertTrue(accepts(landed), "\(button) landed on \(landed)", file: file, line: line)
        return try measure(samples, landed: landed)
    }

    func report(_ series: [(String, [Press])]) -> String {
        var text = "series\tn\tfocus_median_ms\tfocus_p95_ms\tframe_median_ms\tframe_p95_ms\tframe_max_ms\thold_median_ms"
            + "\trequest_median_ms\n"
        for (name, presses) in series {
            let focus = Summary(presses.map(\.toFocus))
            let frame = Summary(presses.map(\.toFrame))
            let hold = Summary(presses.map(\.hold))
            let request = Summary(presses.map(\.toRequest).filter { !$0.isNaN })
            text += [name, String(presses.count)].joined(separator: "\t") + "\t" + [
                focus.median, focus.p95, frame.median, frame.p95, frame.max, hold.median, request.median
            ].map { String(format: "%.1f", $0 * 1_000) }.joined(separator: "\t") + "\n"
        }
        var raw = "series\tindex\tdestination\tto_focus_ms\tto_frame_ms\thold_ms\tto_request_ms\n"
        for (name, presses) in series {
            for (index, press) in presses.enumerated() {
                raw += "\(name)\t\(index)\t\(press.destination)\t" + [press.toFocus, press.toFrame, press.hold, press.toRequest]
                    .map { String(format: "%.2f", $0 * 1_000) }.joined(separator: "\t") + "\n"
            }
        }
        for (name, body) in [("plate-right-latency-summary", text), ("plate-right-latency-presses", raw)] {
            let attachment = XCTAttachment(string: body)
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        print("PLATE_RIGHT_LATENCY\n\(text)")
        return text
    }

    /// Stages for the last press in this batch, from the recorder's lines: `press <t> <seq> <dir> <phase> <ts>`,
    /// `vertical-route <t> <seq> <route>`, `native <t> <seq> <nseq> …`, `frame <t> <ts> <target ts> <seq> <nseq> <dest> <visible> …`.
    private func measure(_ samples: String, landed: String) throws -> Press {
        var began: Double?
        var ended: Double?
        var focus: (time: Double, sequence: Int)?
        var shown: Double?
        var request: Double?
        for line in samples.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let time = f.count > 1 ? Double(f[1]) : nil else { continue }
            switch f[0] {
            case "press" where f.count >= 6:
                // Only the last press of the batch is measured.
                if f[4] == "0" { began = time; ended = nil; focus = nil; shown = nil; request = nil }
                if f[4] == "3" { ended = time }
            case "vertical-route" where f.count >= 4 && began != nil:
                if request == nil, f[3].hasPrefix("request ") { request = time }
            case "native" where f.count >= 7 && began != nil:
                // The last native update of the press is the one that landed (a refused move can bounce first).
                focus = (time, Int(f[3]) ?? -1)
                shown = nil
            case "frame" where f.count >= 11:
                // The first display-link frame after the update that shows the landed item focused and on screen. The
                // callback time, not its target timestamp: under load a late callback's target can precede the press.
                if let focus, shown == nil, Int(f[5]) ?? -1 >= focus.sequence, f[6] == landed, f[7] == "1" { shown = time }
            default: break
            }
        }
        guard let began, let focus, let shown else {
            throw NSError(domain: "Incomplete press timeline (landed \(landed)):\n\(samples)", code: 2)
        }
        return Press(destination: landed, toFocus: focus.time - began, toFrame: shown - began,
                     hold: ended.map { $0 - began } ?? .nan, toRequest: request.map { $0 - began } ?? .nan)
    }

    /// This press's recorder lines, read until a frame shows an accepted destination: under load, a checkpoint can
    /// land between the focus update and the frame that draws it.
    private func settle(_ accepts: (String) -> Bool) throws -> String {
        var samples = try checkpoint()
        for _ in 0..<10 where !(destination(samples).map(accepts) ?? false) {
            Thread.sleep(forTimeInterval: 0.1)
            samples += try checkpoint()
        }
        lastSamples = samples
        return samples
    }

    private func destination(_ samples: String) -> String? {
        for line in samples.split(separator: "\n").reversed() {
            let fields = line.split(separator: "\t")
            if fields.count >= 11 && fields[0] == "frame" { return String(fields[6]) }
        }
        return nil
    }

    private func checkpoint() throws -> String {
        part += 1
        try String(part).write(to: dir.appendingPathComponent("checkpoint-request"), atomically: true, encoding: .utf8)
        let url = dir.appendingPathComponent("app-\(part).tsv")
        let deadline = CACurrentMediaTime() + 30
        repeat {
            if let data = try? String(contentsOf: url, encoding: .utf8) {
                lastSamples = data
                return data
            }
            Thread.sleep(forTimeInterval: 0.025)
        } while CACurrentMediaTime() < deadline
        throw NSError(domain: "Guide recorder checkpoint \(part) missing", code: 1)
    }
}
