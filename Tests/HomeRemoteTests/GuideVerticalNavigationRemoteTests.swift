import UIKit
import XCTest

@MainActor
final class GuideVerticalNavigationRemoteTests: XCTestCase {
    func testHorizontalRouteReversesEveryBoundaryAndHeadingDownUsesFirstVisiblePlate() {
        let app = launchGuide(showsHorizontalRoute: true)
        defer { app.terminate() }
        continueAfterFailure = true
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let offsetProbe = app.staticTexts["guide-offset-probe"]
        var trace: [String] = []
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "guide-horizontal-focus-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        @discardableResult
        func step(_ press: XCUIRemote.Button?, _ expected: String) -> Int {
            if let press {
                XCUIRemote.shared.press(press)
                Thread.sleep(forTimeInterval: 0.65)
            }
            // Plate styles sometimes expose focus on an AX child, not on the Button itself.
            let focusedID = focused.exists ? focused.identifier : focusedButtonAncestor(in: app.debugDescription)
            let actual = focusedID.map { app.buttons[$0] }
            let visible = actual.map { $0.exists && app.frame.intersects($0.frame) } ?? false
            let identifier = visible ? focusedID ?? "" : "No visible focused button"
            let offsetText = offsetProbe.label
            let direction = press.map { [XCUIRemote.Button.left: "Left", .right: "Right", .down: "Down"][$0] ?? "Other" }
            let entry = "GUIDE_HORIZONTAL \(direction ?? "Initial") expected=\(expected) actual=\(identifier) offset/viewport=\(offsetText)"
            print(entry)
            trace.append(entry)
            XCTAssertEqual(identifier, expected, entry)
            return Int(offsetText.components(separatedBy: " / ").first ?? "") ?? -1
        }

        let now = "live-tv-programme-current-1"
        let plate = "live-tv-channel-channels-1"
        let heading = "live-tv-heading"
        let sidebar = "navigation-rail-liveTV"
        step(nil, "live-tv-channel-channels-0")
        step(.right, "live-tv-programme-current-0")
        step(.down, now)
        for index in 0..<4 {
            let offset = step(.right, "live-tv-programme-future-1-\(index)")
            if index == 3 { XCTAssertGreaterThan(offset, 0, "Must browse a panned future viewport") }
        }
        for index in (0..<3).reversed() { step(.left, "live-tv-programme-future-1-\(index)") }
        XCTAssertEqual(step(.left, now), 0)
        step(.left, plate)
        step(.left, heading)
        step(.left, sidebar)
        step(.right, heading)
        step(.right, plate)
        step(.right, now)
        step(.right, "live-tv-programme-future-1-0")
        step(.left, now)
        step(.left, plate)
        step(.left, heading)
        step(.down, "live-tv-channel-channels-0")
        step(.right, "live-tv-programme-current-0")
    }

    private func focusedButtonAncestor(in hierarchy: String) -> String? {
        var ancestors: [(depth: Int, identifier: String)] = []
        for line in hierarchy.split(separator: "\n") {
            let depth = line.prefix(while: { $0 == " " }).count
            while let ancestor = ancestors.last, ancestor.depth >= depth { ancestors.removeLast() }
            if line.dropFirst(depth).hasPrefix("Button,"), let marker = line.range(of: "identifier: '") {
                let id = line[marker.upperBound...].prefix(while: { $0 != "'" })
                ancestors.append((depth, String(id)))
            }
            if line.hasSuffix(", Focused"), let ancestor = ancestors.last { return ancestor.identifier }
        }
        return nil
    }

    func testVerticalBrowsingCrossesViewportOfContinuousLoops() {
        let app = launchGuide(showsLoopRun: true)
        defer { app.terminate() }
        continueAfterFailure = true
        let focusedButton = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        var trace: [String] = []
        var mismatches: [String] = []
        let screen = app.frame
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "guide-loop-focus-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func check(row: Int, press: XCUIRemote.Button? = nil) {
            if let press {
                XCUIRemote.shared.press(press)
                // Read native focus and its browser callback after the same settled tap window.
                Thread.sleep(forTimeInterval: 0.35)
            }
            let exists = focusedButton.exists
            let label = exists ? focusedButton.label : "No focused button"
            let value = exists ? focusedButton.value as? String : nil
            let frame = exists ? focusedButton.frame : .null
            let channel = app.staticTexts["guide-channel-probe"].label
            let offset = app.staticTexts["guide-offset-probe"].label
            let entry = "GUIDE_VERTICAL \(String(describing: press)) expected=channel-\(row) actual=\(channel) button=\(label) value=\(value ?? "") y=\(frame.midY) offset/viewport=\(offset)"
            trace.append(entry)
            print(entry)
            let isLoop = (2...15).contains(row)
            if label != (isLoop ? "Loop \(row)" : "Current \(row)")
                || (isLoop && value != "24/7")
                || channel != "channel-\(row)"
                || !screen.intersects(frame)
                || offset.components(separatedBy: " / ").first != "0" {
                mismatches.append(entry)
            }
        }

        check(row: 0)
        for row in 1...19 { check(row: row, press: .down) }
        for row in (0..<19).reversed() { check(row: row, press: .up) }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    func testUpFromFullWidthNoGuideAt2213FocusesLiveProgramme() {
        let app = launchGuide(showsUpToNow: true)
        defer { app.terminate() }
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let channelProbe = app.staticTexts["guide-channel-probe"]
        let initialFocus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            channelProbe.exists && channelProbe.label == "global-edmonton"
                && focused.exists && focused.identifier.hasSuffix("-2-whole")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [initialFocus], timeout: 8), .completed,
                       "The initial focus must be Edmonton's full-width no-guide cell")
        continueAfterFailure = true
        let offsetProbe = app.staticTexts["guide-offset-probe"]
        let initialOffset = offsetProbe.label
        let viewport = Int(initialOffset.components(separatedBy: " / ").last ?? "") ?? 0
        XCTAssertGreaterThan(viewport, 0)
        XCTAssertTrue(initialOffset.hasPrefix("0 / "), "The fixture starts at Now: \(initialOffset)")
        var trace: [String] = []
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "guide-up-now-focus-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func check(_ step: String, press: XCUIRemote.Button? = nil, channelID: String,
                   label: String, programmeID: String? = nil, emptyRowNumber: Int? = nil,
                   progress: Double? = nil) {
            if let press {
                XCUIRemote.shared.press(press)
                // Sample the committed viewport after the scroll settle window, not animation timing.
                Thread.sleep(forTimeInterval: 0.65)
            }
            let visible = focused.exists && app.frame.intersects(focused.frame)
            let actualChannel = channelProbe.label
            let actualProgramme = app.staticTexts["guide-programme-id-probe"].label
            let actualLabel = visible ? focused.label : "No visible focused button"
            let identifier = visible ? focused.identifier : ""
            let offset = offsetProbe.label
            var fraction: Double?
            if progress != nil, visible, actualLabel == label {
                let capture = app.screenshot()
                let attachment = XCTAttachment(screenshot: capture)
                attachment.name = "guide-up-now-\(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
                do { fraction = try renderedProgress(in: capture, card: focused.frame, screen: app.frame) }
                catch { XCTFail("\(step): Could not read the focused card's progress: \(error)") }
            }
            let entry = "GUIDE_UP_NOW \(step) channel=\(actualChannel) programme=\(actualProgramme) "
                + "button=\(actualLabel) identifier=\(identifier) offset/viewport=\(offset) "
                + "renderedProgress=\(fraction.map { String($0) } ?? "n/a")"
            trace.append(entry)
            print(entry)
            XCTAssertTrue(visible, entry)
            XCTAssertEqual(actualLabel, label, entry)
            XCTAssertEqual(actualChannel, channelID, entry)
            XCTAssertEqual(actualProgramme, programmeID ?? "No programme", entry)
            XCTAssertEqual(offset, initialOffset, entry)
            if let emptyRowNumber {
                XCTAssertTrue(identifier.hasPrefix("live-tv-channel-content-"), entry)
                XCTAssertTrue(identifier.hasSuffix("-\(emptyRowNumber)-whole"), entry)
                XCTAssertGreaterThan(focused.frame.width, CGFloat(viewport) * 0.95, entry)
            }
            if let progress {
                // The listing starts at the window edge; the cell's small trailing gutter is not painted.
                XCTAssertEqual(fraction ?? -1, progress, accuracy: 0.02, entry)
            }
        }

        check("edmonton", channelID: "global-edmonton", label: "Global News Edmonton", emptyRowNumber: 2)
        check("up-elsbeth", press: .up, channelID: "global-calgary", label: "Elsbeth",
              programmeID: "elsbeth-live", progress: 13.0 / 52)
        check("down-edmonton", press: .down, channelID: "global-edmonton", label: "Global News Edmonton", emptyRowNumber: 2)
        check("up-elsbeth-again", press: .up, channelID: "global-calgary", label: "Elsbeth",
              programmeID: "elsbeth-live", progress: 13.0 / 52)
        check("down-edmonton-again", press: .down, channelID: "global-edmonton", label: "Global News Edmonton", emptyRowNumber: 2)
        check("down-windsor", press: .down, channelID: "cbc-windsor", label: "CBC News Windsor", programmeID: "cbc-live")
        check("down-toronto", press: .down, channelID: "city-toronto", label: "City News Toronto ON", emptyRowNumber: 4)
        check("up-windsor", press: .up, channelID: "cbc-windsor", label: "CBC News Windsor",
              programmeID: "cbc-live", progress: 13.0 / 39)
    }

    /// Read a scanline above the title: played grey, then the white remainder of the focused card.
    /// This tests the real painted track, not a second progress calculation in the fixture.
    private func renderedProgress(in screenshot: XCUIScreenshot, card: CGRect, screen: CGRect) throws -> Double {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let sx = CGFloat(image.width) / screen.width
        let sy = CGFloat(image.height) / screen.height
        let left = ((card.minX - screen.minX) * sx).rounded()
        let y = ((card.minY + card.height * 0.22 - screen.minY) * sy).rounded()
        let width = (card.width * sx).rounded(.down)
        let strip = try XCTUnwrap(image.cropping(to: CGRect(x: left, y: y, width: width, height: 1)))
        var bytes = [UInt8](repeating: 0, count: strip.width * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: strip.width, height: 1, bitsPerComponent: 8,
                bytesPerRow: strip.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: 1))
        }
        func lightness(_ x: Int) -> UInt8 { bytes[x * 4] }
        let grey = lightness(strip.width / 10)
        let white = lightness(strip.width * 3 / 4)
        XCTAssertTrue((190...245).contains(grey) && white >= 248 && Int(white) - Int(grey) >= 10,
                      "Expected grey elapsed fill and a white remainder; got \(grey) / \(white)")
        let midpoint = (Int(grey) + Int(white)) / 2
        let edge = try XCTUnwrap((strip.width / 10..<strip.width * 3 / 4).first { Int(lightness($0)) > midpoint })
        return Double(edge) / Double(strip.width)
    }

    func testVerticalBrowsingKeepsCurrentProgramsDespiteWideMovies() {
        let app = launchGuide()
        defer { app.terminate() }
        for row in 1..<7 {
            XCUIRemote.shared.press(.down)
            assertSelected("Current \(row)", in: app)
        }
        XCUIRemote.shared.press(.down)
        assertSelected("channel-7", in: app)
        for row in (0..<7).reversed() {
            XCUIRemote.shared.press(.up)
            assertSelected("Current \(row)", in: app)
        }
    }

    func testHorizontalBrowsingHandsOffToNativeUntilNowResetsIt() {
        let app = launchGuide()
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        assertSelected("Current 1", in: app)
        XCUIRemote.shared.press(.right)
        assertSelected("Future 1.1", in: app)
        XCUIRemote.shared.press(.down)
        assertSelected("Future 2.1", in: app)
        for _ in 0..<12 where !app.buttons["guide-now"].hasFocus {
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(app.buttons["guide-now"].hasFocus)
        XCUIRemote.shared.press(.select)
        assertSelected("Current 0", in: app)
        XCUIRemote.shared.press(.down)
        assertSelected("Current 1", in: app)
    }

    func testHorizontalBrowsingExtendsPastTheFirstSixHours() {
        // Reaches 28 hours in: past the first six hours and past a day.
        let app = launchGuide()
        defer { app.terminate() }
        for title in ["Future 0.1", "Future 0.2", "Future 0.3"] {
            XCUIRemote.shared.press(.right)
            assertSelected(title, in: app)
        }
        // Each step lands on the next hour, well beyond the initial window.
        for hour in 1...22 {
            XCUIRemote.shared.press(.right)
            assertSelected("Later 0.\(hour)", in: app)
        }
        XCUIRemote.shared.press(.down)
        assertSelected("Later 1.22", in: app)
        XCUIRemote.shared.press(.left)
        assertSelected("Later 1.21", in: app)
        XCUIRemote.shared.press(.up)
        assertSelected("Later 0.21", in: app)
    }

    func testLongProgrammeScrollsOneViewportAtATime() throws {
        let app = launchGuide(showsLongProgramme: true)
        defer { app.terminate() }
        let long = "Future 2.1"
        let next = "Future 2.2"
        var trace: [String] = []
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "guide-long-programme-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func sample(_ phase: String, press button: XCUIRemote.Button? = nil) throws -> GuideSample {
            let start = Date().timeIntervalSince1970
            if let button {
                XCUIRemote.shared.press(button)
                // The binding is published after 200 ms without scroll geometry changes.
                // Wait outside the remote call and keep AX queries out of the motion window.
                Thread.sleep(forTimeInterval: 0.65)
            }
            let time = Date().timeIntervalSince1970
            let title = app.staticTexts["guide-focus-probe"].label
            let reading = app.staticTexts["guide-offset-probe"].label
            let values = reading.components(separatedBy: " / ").compactMap(Int.init)
            let entry = "GUIDE_LONG \(phase) pressAt=\(start) sampleAt=\(time) title=\(title) offset/viewport=\(reading)"
            trace.append(entry)
            print(entry)
            let offset = try XCTUnwrap(values.first, "Missing guide offset: \(reading)")
            let viewport = try XCTUnwrap(values.dropFirst().first, "Missing guide viewport: \(reading)")
            return GuideSample(title: title, offset: offset, viewport: viewport)
        }

        let initial = try sample("initial")
        let above = try sample("normal-row", press: .down)
        let current = try sample("long-row", press: .down)
        let entry = try sample("right-enter", press: .right)
        let advance = try sample("right-single", press: .right)
        var forward = [advance]
        for step in 1...5 where forward.last?.title != next {
            forward.append(try sample("right-repeat-\(step)", press: .right))
        }
        let exit = try XCTUnwrap(forward.last)
        let reverse = try sample("left-reverse", press: .left)
        let reverseAgain = try sample("left-repeat", press: .left)

        // Assert after collecting the entire replay, even when baseline is red.
        continueAfterFailure = true
        XCTAssertEqual(above.title, "Current 1")
        XCTAssertLessThanOrEqual(abs(above.offset - initial.offset), 2)
        XCTAssertEqual(current.title, "Current 2")
        XCTAssertGreaterThan(entry.viewport, 0)
        XCTAssertEqual(entry.title, long)
        XCTAssertLessThanOrEqual(entry.offset - current.offset, entry.viewport + 2,
                                 "Entering the wide card must not leap past a viewport")
        XCTAssertEqual(advance.title, long, "Right should browse the oversized card before leaving it")
        XCTAssertGreaterThan(advance.offset, entry.offset, "Right should reveal more of the card")
        XCTAssertLessThanOrEqual(advance.offset - entry.offset, entry.viewport + 2)
        for (before, after) in zip([entry] + forward, forward) {
            XCTAssertGreaterThanOrEqual(after.offset, before.offset - 2, "Right should not scroll backwards")
            XCTAssertLessThanOrEqual(after.offset - before.offset, entry.viewport + 2,
                                     "One Right must not skip more than a viewport")
        }
        XCTAssertEqual(exit.title, next, "Repeated Right must eventually reach the next programme")
        XCTAssertEqual(reverse.title, long)
        XCTAssertEqual(reverseAgain.title, long, "Left should also browse the interior of the oversized card")
        for (before, after) in [(exit, reverse), (reverse, reverseAgain)] {
            XCTAssertLessThanOrEqual(after.offset, before.offset + 2, "Left should not scroll forwards")
            XCTAssertLessThanOrEqual(before.offset - after.offset, entry.viewport + 2,
                                     "One Left must not skip more than a viewport")
        }
        XCTAssertLessThan(reverseAgain.offset, reverse.offset, "Left should reveal more of the card")
    }

    func testLongProgrammePagingDurationBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["PLOZZ_GUIDE_PAGING_BENCHMARK"] == "1",
                          "Select the paging-duration runner explicitly")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--guide-navigation-fixture", "--guide-paging-duration"]
        app.launch()
        defer { app.terminate() }
        assertSelected("Current 0", in: app)
        let geometry = app.staticTexts["guide-paging-geometry-probe"].label
        let fields = geometry.components(separatedBy: " / ")
        print("GUIDE_PAGING geometry=\(geometry)")
        XCTAssertEqual(fields.last, "default", "Default-motion replay only; check Reduce Motion separately")
        let minutes = try XCTUnwrap(fields.first.flatMap(Int.init))
        XCTAssertTrue([120, 180].contains(minutes), geometry)
        if environment["PLOZZ_GUIDE_PAGING_REQUIRE_4K"] == "1" {
            XCTAssertEqual(geometry, "180 / 3840 / 2160 / default")
        }

        let offsetProbe = app.staticTexts["guide-offset-probe"]
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let plates = (1...3).map { app.buttons["live-tv-channel-channels-\($0)"] }
        let programme = "live-tv-programme-paging-marathon"
        var trace = ["geometry=\(geometry)"]
        defer {
            let attachment = XCTAttachment(string: trace.joined(separator: "\n"))
            attachment.name = "guide-paging-duration-trace"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func log(_ line: String) {
            trace.append(line)
            print("GUIDE_PAGING \(line)")
        }
        func position() throws -> (offset: Int, viewport: Int) {
            let label = offsetProbe.label
            let readings = label.components(separatedBy: " / ").compactMap(Int.init)
            XCTAssertEqual(readings.count, 2, label)
            let viewport = try XCTUnwrap(readings.last)
            XCTAssertGreaterThan(viewport, 0, label)
            return (try XCTUnwrap(readings.first), viewport)
        }
        func press(_ button: XCUIRemote.Button, wait: TimeInterval = 1.0) {
            XCUIRemote.shared.press(button)
            // No AX queries or screenshots during motion. Keep idle margins in the video.
            Thread.sleep(forTimeInterval: wait)
        }
        func sample(_ phase: String) throws -> (offset: Int, viewport: Int, focus: String, pins: [CGRect]) {
            let position = try position()
            let identifier = focused.exists ? focused.identifier : focusedButtonAncestor(in: app.debugDescription)
            let id = identifier ?? ""
            let button = app.buttons[id]
            let actual = !id.isEmpty && button.exists && app.frame.intersects(button.frame) ? id : "no visible focus"
            let pins = plates.map { $0.exists ? $0.frame : .null }
            log("\(phase) offset=\(position.offset) viewport=\(position.viewport) focus=\(actual) pins=\(pins)")
            return (position.offset, position.viewport, actual, pins)
        }

        // Warm the scrollable span in a normal row, using native moves only. At
        // +08:15 both layouts have passed the threshold for an 18-hour window.
        press(.down)
        assertSelected("Current 1", in: app)
        var warm = try position()
        let warmOffset = 495.0 * Double(warm.viewport) / Double(minutes)
        for step in 1...25 where Double(warm.offset) < warmOffset {
            press(.right, wait: 0.75)
            warm = try position()
            log("warm-right-\(step) offset=\(warm.offset) viewport=\(warm.viewport)")
        }
        XCTAssertGreaterThanOrEqual(Double(warm.offset), warmOffset, "Warmup never reached the interior")
        press(.down)
        let entry = try sample("interior-entry")
        XCTAssertEqual(entry.focus, programme)
        XCTAssertEqual(Double(entry.offset), Double(warm.offset), accuracy: 2)
        XCTAssertEqual(entry.viewport, warm.viewport)
        XCTAssertTrue(entry.pins.allSatisfy { !$0.isEmpty && app.frame.contains($0) }, "Pinned rows must be visible")
        // Right must reach beyond the old 12-hour geometry cap; both resulting
        // viewport edges must be inside the programme, not at its clipped end.
        let entryMinutes = Double(entry.offset) / Double(entry.viewport) * Double(minutes)
        XCTAssertGreaterThan(entryMinutes + 2 * Double(minutes), 720)
        XCTAssertLessThan(entryMinutes + 2 * Double(minutes), 900)

        // Collect all six moves even on a red baseline, keeping raw endpoints.
        continueAfterFailure = true
        for pair in 1...3 {
            Thread.sleep(forTimeInterval: 0.3)
            press(.right)
            let right = try sample("right-\(pair)")
            Thread.sleep(forTimeInterval: 0.3)
            press(.left)
            let left = try sample("left-\(pair)")
            for reading in [right, left] {
                XCTAssertEqual(reading.focus, programme)
                XCTAssertEqual(reading.viewport, entry.viewport)
                for (pin, original) in zip(reading.pins, entry.pins) {
                    XCTAssertFalse(pin.isEmpty)
                    XCTAssertEqual(pin.minX, original.minX, accuracy: 1)
                    XCTAssertEqual(pin.minY, original.minY, accuracy: 1)
                    XCTAssertEqual(pin.width, original.width, accuracy: 1)
                    XCTAssertEqual(pin.height, original.height, accuracy: 1)
                }
            }
            XCTAssertEqual(Double(right.offset - entry.offset), Double(entry.viewport), accuracy: 2)
            XCTAssertEqual(Double(right.offset - left.offset), Double(entry.viewport), accuracy: 2)
            XCTAssertEqual(Double(left.offset), Double(entry.offset), accuracy: 2)
        }
    }

    private struct GuideSample {
        let title: String
        let offset: Int
        let viewport: Int
    }

    private func launchGuide(
        showsLongProgramme: Bool = false, showsLoopRun: Bool = false, showsUpToNow: Bool = false,
        showsHorizontalRoute: Bool = false
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--guide-navigation-fixture"]
        if showsLongProgramme { app.launchArguments.append("--guide-long-programme") }
        if showsLoopRun { app.launchArguments.append("--guide-loop-run") }
        if showsUpToNow { app.launchArguments.append("--guide-up-now") }
        if showsHorizontalRoute { app.launchArguments.append("--guide-horizontal-route") }
        app.launch()
        assertSelected(showsHorizontalRoute ? "channel-0" : showsUpToNow ? "global-edmonton" : "Current 0", in: app)
        return app
    }

    private func assertSelected(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let probe = app.staticTexts["guide-focus-probe"]
        let predicate = NSPredicate { _, _ in probe.exists && probe.label == title }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "unexpected-guide-focus"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected \(title)", file: file, line: line)
    }
}
