//
//  PennyMeUITests.swift
//  PennyMeUITests
//
//  Created by Jannis Born on 11.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import XCTest

class PennyMeUITests: XCTestCase {

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // UI tests must launch the application that they test. Doing this in setup will make sure it happens for each test method.
        XCUIApplication().launch()

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() {
        // Use recording to get started writing UI tests.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testTripImportAndStopSelection() {
        let app = XCUIApplication()
        app.buttons["Settings"].tap()
        let importButton = app.staticTexts["Import trip"]
        app.swipeUp()
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        let prompt = app.alerts["Import trip"]
        prompt.textFields.firstMatch.tap()
        prompt.textFields.firstMatch.typeText("https://maps.apple.com/?saddr=47.37,8.54&daddr=47.56,7.59")
        prompt.buttons["Preview"].tap()
        XCTAssertTrue(app.navigationBars["Trip preview"].waitForExistence(timeout: 10))
        let best = app.descendants(matching: .any)["trip-best"].firstMatch
        XCTAssertTrue(best.waitForExistence(timeout: 10))
        let export = app.buttons["Open in Google Maps"]
        XCTAssertFalse(export.isEnabled)
        best.tap()
        let selection = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: export)
        wait(for: [selection], timeout: 5)
        XCTAssertTrue(export.isEnabled, app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Remove stop"].tap()
        XCTAssertFalse(export.isEnabled)
        app.buttons["Done"].tap()
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
    }

}
