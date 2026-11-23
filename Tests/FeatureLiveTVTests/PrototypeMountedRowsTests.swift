import FeatureLiveTVCore
import XCTest
@testable import FeatureLiveTV

final class PrototypeMountedRowsTests: XCTestCase {
    /// A recycled guide cell shows the row in its new cell before the old cell reports it gone. The row must stay
    /// mounted, or a plate focus request (Left from the current programme, Down from the heading) waits forever.
    func testARowShownInANewCellBeforeTheOldCellLetsGoStaysMounted() {
        let row = LiveTVGuideRowID(channelID: "cbc-edmonton")
        var rows = PrototypeMountedRows()
        rows.insert(row)
        rows.insert(row)
        rows.remove(row)
        XCTAssertTrue(rows.contains(row))
        rows.remove(row)
        XCTAssertFalse(rows.contains(row))
    }

    func testRemovingAnUnmountedRowIsHarmless() {
        let row = LiveTVGuideRowID(channelID: "one")
        var rows = PrototypeMountedRows()
        rows.remove(row)
        rows.insert(row)
        XCTAssertTrue(rows.contains(row))
        XCTAssertFalse(rows.contains(LiveTVGuideRowID(channelID: "one", section: .favorites)))
    }
}
