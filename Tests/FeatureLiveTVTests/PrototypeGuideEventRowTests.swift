import XCTest
@testable import FeatureLiveTV

/// An event slot's row draws only its one programme (as the mockup does); linear rows keep their "No guide information" gap cell.
final class PrototypeGuideEventRowTests: XCTestCase {
    func testEventSlotRowDrawsNoCellForTheTimeAroundItsEvent() {
        XCTAssertFalse(PrototypeGuideRow.drawsGapCell(isEventSlot: true))
    }

    func testLinearRowKeepsItsNoGuideInformationGap() {
        XCTAssertTrue(PrototypeGuideRow.drawsGapCell(isEventSlot: false))
    }
}
