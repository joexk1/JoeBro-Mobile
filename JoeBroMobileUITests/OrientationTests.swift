import XCTest

final class OrientationTests: XCTestCase {
    func testFourTabsInPortraitAndLandscape() {
        let app = XCUIApplication()
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.buttons["JoeBro"].waitForExistence(timeout: 15))
        XCTAssertTrue(tabs.buttons["Chats"].waitForExistence(timeout: 15))
        XCTAssertTrue(tabs.buttons["Agents"].exists)
        XCTAssertTrue(tabs.buttons["Workspace"].exists)

        tabs.buttons["Agents"].tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5))
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "Portrait agents tab"
        portrait.lifetime = .keepAlways
        add(portrait)

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.frame.width > window.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(tabs.buttons["Chats"].exists)
        XCTAssertTrue(tabs.buttons["JoeBro"].exists)
        XCTAssertTrue(tabs.buttons["Agents"].exists)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "Landscape agents tab"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCUIDevice.shared.orientation = .portrait
    }
}
