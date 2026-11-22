import XCTest
@testable import CoreUI

@MainActor
final class TVBackConsumptionTests: XCTestCase {
    override func setUp() async throws { TVBackConsumption.reset() }
    override func tearDown() async throws { TVBackConsumption.reset() }

    func testNothingIsConsumedUntilAPanelSpendsAPress() {
        XCTAssertFalse(TVBackConsumption.wasJustConsumed(at: 100))
    }

    func testAPressSpentByAPanelIsSpentForTheOuterHandlerOnly() {
        TVBackConsumption.consume(at: 100)
        XCTAssertTrue(TVBackConsumption.wasJustConsumed(at: 100.01), "the same press reaching the sidebar is ignored")
        XCTAssertFalse(TVBackConsumption.wasJustConsumed(at: 100 + TVBackConsumption.window + 0.01), "a later, second Back is the sidebar's")
    }
}
