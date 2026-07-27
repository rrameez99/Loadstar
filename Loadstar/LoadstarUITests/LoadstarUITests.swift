//
//  LoadstarUITests.swift
//  LoadstarUITests
//
//  UI tests drive the app through the accessibility layer, which makes them slow
//  and brittle compared to the unit tests in LoadstarTests. The logic worth
//  protecting lives in the engines and is covered there instead.
//
//  Xcode's template also generated a launch-performance test. It's been removed:
//  `measure(metrics: [XCTApplicationLaunchMetric()])` collects no metrics when
//  run on a physical device from Xcode, so it fails every run with "Received
//  unexpected number of metrics: 0". A test that always fails trains you to
//  ignore failures, which is worse than having no test.
//

import XCTest

final class LoadstarUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesToTheTodayTab() throws {
        let app = XCUIApplication()
        app.launch()

        // A smoke test: proves the app starts, the SwiftData container builds,
        // and the tab bar renders. Catches a crash-on-launch from a bad schema
        // migration, which is the failure most likely to slip past unit tests.
        XCTAssertTrue(app.tabBars.buttons["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Workouts"].exists)
        XCTAssertTrue(app.tabBars.buttons["Library"].exists)
    }
}
