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

    @MainActor
    func testRediscoveryUsesServerStatusAndOnlyPresetsTheProposedStatus() throws {
        for status in ["available", "out-of-order", "retired"] {
            let feature: [String: Any] = [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [8.54, 47.37]],
                "properties": ["id": 42, "name": "Current server title", "address": "Current address",
                               "area": "Germany", "external_url": "null", "last_updated": "2026-11-01",
                               "machine_status": status, "num_coins": 8, "paywall": true]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["machine": feature])
            let rediscovered = MachinePresencePolicy.rediscoveredMachine(from: data)
            XCTAssertEqual(rediscovered != nil, status != "available")
            let encoded = try JSONSerialization.data(withJSONObject: feature)
            let geoFeature = try XCTUnwrap(MKGeoJSONDecoder().decode(encoded).first as? MKGeoJSONFeature)
            let machine = try XCTUnwrap(Artwork(feature: geoFeature))
            let regular = MachineChangedForm(pinData: machine)
            XCTAssertEqual(regular.proposedMachineStatus, status)
            XCTAssertFalse(regular.requiresStatusExplanation)
            let suggested = MachineChangedForm(pinData: machine, suggestedStatus: "available")
            XCTAssertEqual(suggested.proposedMachineStatus, "available")
            XCTAssertEqual(suggested.requiresStatusExplanation, status != "available")
            XCTAssertEqual(machine.machineStatus, status)
            XCTAssertEqual(suggested.pinDataStored.address, "Current address")
            XCTAssertEqual(suggested.pinDataStored.numCoins, 8)
        }
        XCTAssertNil(MachinePresencePolicy.rediscoveredMachine(from: Data("{}".utf8)))
        XCTAssertNil(MachinePresencePolicy.rediscoveredMachine(from: Data("{\"machine\":{\"properties\":{\"machine_status\":\"retired\"}}}".utf8)))
    }

    func testStatusChangeReasonRequiresTenTrimmedCharacters() {
        XCTAssertFalse(MachineChangedForm.isValidStatusReason("          "))
        XCTAssertFalse(MachineChangedForm.isValidStatusReason("123456789"))
        XCTAssertTrue(MachineChangedForm.isValidStatusReason(" 1234567890 "))
        XCTAssertFalse(MachineChangedForm.isValidStatusReason(String(repeating: "x", count: 2001)))
    }

    @MainActor
    func testPresenceConfirmsWithExistingFreshFixAndAfterTemporaryError() async {
        for temporaryError in [false, true] {
            let sent = expectation(description: "Live confirmation sent (temporary error: \(temporaryError))")
            let manager = PresenceTestLocationManager()
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                 timestamp: Date().addingTimeInterval(-2))
            manager.testLocation = temporaryError ? nil : fix
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PresenceTestURLProtocol.self]
            let session = URLSession(configuration: configuration)
            PresenceTestURLProtocol.onRequest = { request in
                XCTAssertEqual(request.url?.path, "/machines/42/confirm-presence")
                sent.fulfill()
            }
            let monitor = MachinePresenceMonitor(
                hasNearbyMachine: { _ in false }, isBlocked: { _ in false },
                manager: manager, session: session, isActive: { true }
            )
            let stopsBeforeConfirming = manager.stops
            monitor.requestFreshConfirmation(PresenceMachine(id: 42, name: "Test", latitude: 0, longitude: 0))
            if temporaryError {
                monitor.locationManager(manager, didFailWithError: CLError(.locationUnknown))
                // The delegate fix can precede the tap and the manager's cached property can be nil.
                monitor.locationManager(manager, didUpdateLocations: [fix])
            }
            XCTAssertEqual(manager.stops, stopsBeforeConfirming, "Confirming must not restart GPS")
            await fulfillment(of: [sent], timeout: 3)
            session.invalidateAndCancel()
        }
        PresenceTestURLProtocol.onRequest = nil
    }

    func testPresenceRequiresFreshPreciseLocationWithinTwentyMetres() {
        let now = Date()
        let machine = PresenceMachine(id: 1, name: "Test", latitude: 0, longitude: 0)
        func fix(metres: Double = 0, accuracy: Double = 5, age: Double = 0) -> CLLocation {
            let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: metres / 111319.49)
            return CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy,
                              verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 19.9), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 20.1), now: now))
        XCTAssertTrue(MachinePresencePolicy.canConfirm(machine, at: fix(accuracy: 10, age: 15), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(accuracy: -1), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(accuracy: 10.1), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(age: 15.1), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(age: -5.1), now: now))
    }

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

private final class PresenceTestLocationManager: CLLocationManager {
    var testLocation: CLLocation?
    var stops = 0
    private weak var testDelegate: CLLocationManagerDelegate?
    override var delegate: CLLocationManagerDelegate? {
        get { testDelegate }
        set { testDelegate = newValue }
    }
    override var location: CLLocation? { testLocation }
    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func startUpdatingLocation() {}
    override func stopUpdatingLocation() { stops += 1 }
}

private final class PresenceTestURLProtocol: URLProtocol {
    static var onRequest: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onRequest?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                            httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
