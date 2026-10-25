//
//  PennyMeTests.swift
//  PennyMeTests
//
//  Created by Jannis Born on 11.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import XCTest
import UIKit
import SwiftUI
import MapKit
@testable import PennyMe

class PennyMeTests: XCTestCase {

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// User movement updates the form; programmatic changes must not feed back.
    @MainActor
    func testCoordinatePickerSynchronizesSelection() {
        let initial = CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54)
        var selection = initial
        let coordinator = CoordinatePickerMap.Coordinator(
            selectedLocation: Binding(get: { selection }, set: { selection = $0 })
        )
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let moved = CLLocationCoordinate2D(latitude: 47.38, longitude: 8.55)
        map.setRegion(MKCoordinateRegion(
            center: moved, latitudinalMeters: 500, longitudinalMeters: 500
        ), animated: false)
        coordinator.isUpdating = true
        coordinator.mapView(map, regionDidChangeAnimated: false)
        XCTAssertEqual(selection, initial)

        coordinator.isUpdating = false
        coordinator.mapView(map, regionDidChangeAnimated: false)
        XCTAssertEqual(selection.latitude, moved.latitude, accuracy: 0.00001)
        XCTAssertEqual(selection.longitude, moved.longitude, accuracy: 0.00001)
    }

    func testTextModerationBlocksObjectionableLanguageWithoutSubstringFalsePositive() {
        XCTAssertNotNil(TextModeration.blockReason("This is fucking awful"))
        XCTAssertNil(TextModeration.blockReason("Classic brass machine"))
    }

    func testContributionDiffShowsOnlyChangedTextWithContext() {
        let segments = ContributionDiff.segments(
            old: "1737 Post Street, West Mall, #326, San Francisco",
            new: "1737 Post Street, West Mall, San Francisco"
        )

        XCTAssertTrue(segments.prefix.hasPrefix("…"))
        XCTAssertTrue(segments.prefix.contains("West Mall"))
        XCTAssertEqual(segments.removed, "#326, ")
        XCTAssertEqual(segments.added, "")
        XCTAssertTrue(segments.suffix.contains("San Francisco"))
        XCTAssertFalse(segments.prefix.contains("1737 Post"))

        let whitespace = ContributionDiff.segments(
            old: "Fisherman's Wharf ",
            new: "Fisherman's Wharf"
        )
        XCTAssertEqual(whitespace.removed, " ")
        XCTAssertEqual(ContributionDiff.visibleChange(whitespace.removed), "␠")
    }

    func testLegalMarkdownRendersFormattingAndMailLink() {
        let rendered = LegalMarkdownRenderer.attributedText(
            from: "# Terms\n\nContact [support@example.com](mailto:support@example.com). Accept **these terms**.",
            baseTextStyle: .body
        )

        XCTAssertFalse(rendered.string.contains("# "))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("[support@example.com]"))

        let emailRange = (rendered.string as NSString).range(of: "support@example.com")
        let link = rendered.attribute(.link, at: emailRange.location, effectiveRange: nil)
            as? URL
        XCTAssertEqual(link?.absoluteString, "mailto:support@example.com")
    }

    func testContributorBlockAppliesToOtherContentFromSameContributor() {
        let suiteName = "BlockedContributorsStoreTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlockedContributorsStore(defaults: defaults)
        store.block(contributorID: "contributor-a", contentKey: "image:machine")

        XCTAssertTrue(
            store.isBlocked(contributorID: "contributor-a", contentKey: "image:coin_0")
        )
        XCTAssertFalse(
            store.isBlocked(contributorID: "contributor-b", contentKey: "image:coin_0")
        )
    }

    func testContributorCanBeUnblocked() {
        let suiteName = "BlockedContributorsUnblockTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlockedContributorsStore(defaults: defaults)
        store.block(contributorID: "contributor-a", contentKey: "42:image:machine")
        store.unblock(contributorID: "contributor-a")

        XCTAssertFalse(
            store.isBlocked(
                contributorID: "contributor-a",
                contentKey: "42:image:machine"
            )
        )
        XCTAssertTrue(store.blockedContributorIDs().isEmpty)
        XCTAssertTrue(store.blockedContentKeys().isEmpty)
    }

    func testAllBlocksCanBeCleared() {
        let suiteName = "BlockedContributorsUnblockAllTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlockedContributorsStore(defaults: defaults)
        store.block(contributorID: "contributor-a", contentKey: "42:image:machine")
        store.block(contributorID: nil, contentKey: "43:image:coin_0")
        store.unblockAll()

        XCTAssertTrue(store.blockedContributorIDs().isEmpty)
        XCTAssertTrue(store.blockedContentKeys().isEmpty)
    }

    func testPerformanceExample() {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
