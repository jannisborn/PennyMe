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
    func testScrollingPinDetailsDoesNotChangeTheReportedImage() {
        let controller = PinViewController(style: .grouped)
        let photos = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pages = UIPageControl()
        pages.numberOfPages = 5
        controller.scrollView = photos
        controller.pageControl = pages
        let details = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        for page in 1...4 {
            photos.contentOffset.x = CGFloat(page) * photos.bounds.width
            controller.scrollViewDidScroll(photos)
            XCTAssertEqual(pages.currentPage, page)
            details.contentOffset.y = CGFloat(page) * 100
            controller.scrollViewDidScroll(details)
            XCTAssertEqual(pages.currentPage, page, "Vertical scrolling must preserve the selected coin")
        }
        photos.frame.size.width = 0
        controller.scrollViewDidScroll(photos)
        XCTAssertEqual(pages.currentPage, 4)
    }

    @MainActor
    func testPresencePromptSurvivesLocationLossDriftAndAppInterruptions() async throws {
        let appDelegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let originalWindow = appDelegate.window
        let window = UIWindow(frame: originalWindow?.bounds ?? UIScreen.main.bounds)
        let presenter = UIViewController()
        window.rootViewController = presenter
        appDelegate.window = window
        window.makeKeyAndVisible()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let machine = PresenceMachine(id: 42, name: "Zoo · Machine 6", latitude: 0, longitude: 0)
        let data = try JSONSerialization.data(withJSONObject: ["machines": [], "nearby_machines": [
            ["id": 42, "name": machine.name, "latitude": 0, "longitude": 0, "num_coins": 0],
            ["id": 43, "name": "Zoo · Machine 7", "latitude": 0, "longitude": 0, "num_coins": 0]
        ]])
        PresenceTestURLProtocol.response = { request in
            request.url?.path == "/machines/nearby-confirmations" ? (200, data) : (404, Data())
        }
        defer {
            presenter.dismiss(animated: false)
            PresenceTestURLProtocol.response = nil
            session.invalidateAndCancel()
            window.isHidden = true
            appDelegate.window = originalWindow
            originalWindow?.makeKeyAndVisible()
        }
        let manager = PresenceTestLocationManager()
        let fix = CLLocation(coordinate: machine.location.coordinate, altitude: 0,
                             horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        manager.testLocation = fix
        var active = true
        let monitor = MachinePresenceMonitor(hasNearbyMachine: { _ in false }, isBlocked: { _ in false },
                                             manager: manager, session: session, isActive: { active })
        monitor.requestManualConfirmation(machine)
        let presented = expectation(for: NSPredicate { _, _ in
            guard let prompt = presenter.presentedViewController as? PresenceConfirmationController else { return false }
            return !prompt.isBeingPresented
        }, evaluatedWith: nil)
        await fulfillment(of: [presented], timeout: 4)
        let prompt = try XCTUnwrap(presenter.presentedViewController as? PresenceConfirmationController)
        XCTAssertTrue(prompt.isModalInPresentation)
        if #available(iOS 16.0, *) {
            let initialHeight = prompt.view.bounds.height
            prompt.rootView.onCompareNearby()
            let expanded = expectation(for: NSPredicate { _, _ in
                prompt.view.bounds.height > initialHeight
            }, evaluatedWith: nil)
            await fulfillment(of: [expanded], timeout: 3)
        }

        let viewer = UIViewController()
        viewer.modalPresentationStyle = .fullScreen
        prompt.present(viewer, animated: false)
        for location in [
            CLLocation(coordinate: machine.location.coordinate, altitude: 0, horizontalAccuracy: 5,
                       verticalAccuracy: -1, timestamp: Date().addingTimeInterval(-20)),
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 120 / 111319.49),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        ] {
            manager.testLocation = location
            monitor.locationManager(manager, didUpdateLocations: [location])
            XCTAssertTrue(presenter.presentedViewController === prompt)
            XCTAssertTrue(prompt.presentedViewController === viewer)
            XCTAssertFalse(prompt.isBeingDismissed)
            XCTAssertNotNil(prompt.rootView.locationMessage)
            if MachinePresencePolicy.isPreciseAndFresh(location) {
                XCTAssertEqual(prompt.rootView.location.coordinate.longitude, location.coordinate.longitude)
            }
        }
        active = false
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(presenter.presentedViewController === prompt)
        XCTAssertTrue(prompt.presentedViewController === viewer)
        active = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        manager.testLocation = fix
        monitor.locationManager(manager, didUpdateLocations: [fix])
        XCTAssertNil(prompt.rootView.locationMessage)
        XCTAssertTrue(prompt.presentedViewController === viewer)
    }

    func testPresenceComparisonUsesOneHundredMetresAroundUserAndSupportsOlderResponses() throws {
        func machine(_ id: Int, metres: Double) -> [String: Any] {
            ["id": id, "name": "Machine \(id)", "latitude": 0, "longitude": metres / 111319.49, "num_coins": 6]
        }
        let target = machine(1, metres: 20)
        let context = [target, machine(2, metres: 119.9), machine(3, metres: -80.1), machine(4, metres: 20)]
        let data = try JSONSerialization.data(withJSONObject: ["machines": [target], "nearby_machines": context])
        let candidates = try JSONDecoder().decode(PresenceCandidates.self, from: data)
        let selected = try XCTUnwrap(candidates.machines.first)
        XCTAssertEqual(selected.numCoins, 6)
        let location = CLLocation(latitude: 0, longitude: 0)
        // Count other machines around the user, including recently confirmed ones.
        XCTAssertEqual(candidates.neighbors(of: selected, at: location).map(\.id), [4, 3])
        XCTAssertTrue(candidates.neighbors(of: selected, at: CLLocation(latitude: 1, longitude: 1)).isEmpty)

        let legacyData = Data("{\"machines\":[{\"id\":1,\"name\":\"Zoo\",\"latitude\":0,\"longitude\":0}]}".utf8)
        let legacy = try JSONDecoder().decode(PresenceCandidates.self, from: legacyData)
        XCTAssertNil(legacy.machines[0].numCoins)
        XCTAssertTrue(legacy.neighbors(of: legacy.machines[0], at: location).isEmpty)
    }

    @MainActor
    func testPresenceComparisonDisappearsWhenOnlySelfOrDistantMachinesRemain() {
        let target = PresenceMachine(id: 1, name: "Target", latitude: 0, longitude: 0)
        let nearby = PresenceMachine(id: 2, name: "Nearby", latitude: 0, longitude: 99.9 / 111319.49)
        let distant = PresenceMachine(id: 3, name: "Distant", latitude: 0, longitude: 100.1 / 111319.49)
        let controller = PresenceConfirmationController(machine: target, neighbors: [target, nearby, distant],
                                                       location: target.location, finish: { _ in })
        XCTAssertEqual(controller.rootView.comparisonMachines.map(\.id), [2])
        let moved = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        controller.updateLocation(moved, source: .manual)
        XCTAssertTrue(controller.rootView.comparisonMachines.isEmpty)
        let isolated = PresenceConfirmationView(machine: target, neighbors: [target, distant],
                                               location: target.location, finish: { _ in })
        XCTAssertTrue(isolated.comparisonMachines.isEmpty)
    }

    @MainActor
    func testPresencePhotosPreferMachineThenAllAvailableCoinsAndRespectBlocks() async throws {
        let suiteName = "PresencePhotoBlocksTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let blocked = BlockedContributorsStore(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData())
        let machine = PresenceMachine(id: 42, name: "Zoo", latitude: 0, longitude: 0, numCoins: 3)
        defer {
            PresenceTestURLProtocol.response = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
        }
        for scenario in ["machine", "coins", "blocked", "missing"] {
            blocked.unblockAll()
            if scenario == "blocked" {
                blocked.block(contributorID: "hidden", contentKey: "99:image:machine")
                blocked.block(contributorID: nil, contentKey: "42:image:coin_2")
            }
            PresenceTestURLProtocol.response = { request in
                let path = request.url!.path
                if path.contains("moderation/manifest") {
                    return (200, Data("{\"owners\":{\"image:machine\":\"hidden\",\"image:coin_0\":\"hidden\"}}".utf8))
                }
                if scenario == "blocked" {
                    XCTAssertFalse(path.hasSuffix("42.jpg"))
                    XCTAssertFalse(path.hasSuffix("coin_0.png"))
                    XCTAssertFalse(path.hasSuffix("coin_2.png"))
                }
                if scenario == "machine" {
                    XCTAssertFalse(path.contains("coin_"), "Coins are only a fallback")
                    return (200, png)
                }
                if scenario == "coins", path.hasSuffix("coin_0.png") || path.hasSuffix("coin_2.png") {
                    return (200, png)
                }
                if scenario == "blocked", path.hasSuffix("coin_1.png") { return (200, png) }
                return (404, Data())
            }
            let photos = PresencePhotos()
            await photos.load(machine: machine, session: session, blocked: blocked)
            let expected: [String]
            switch scenario {
            case "machine": expected = ["image:machine"]
            case "coins": expected = ["image:coin_0", "image:coin_2"]
            case "blocked": expected = ["image:coin_1"]
            default: expected = []
            }
            XCTAssertEqual(photos.photos.map(\.id), expected, scenario)
            XCTAssertFalse(photos.isLoading)
        }
    }

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

    @MainActor
    func testManualPresenceUsesOneHundredMetresAndSendsTheManualSource() async throws {
        let now = Date()
        let machine = PresenceMachine(id: 42, name: "Zoo", latitude: 0, longitude: 0)
        func fix(metres: Double, age: Double = 0, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: metres / 111319.49),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 99.9), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 100.1), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 75, age: 16), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 75, accuracy: 11), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 75), now: now))
        let manager = PresenceTestLocationManager()
        manager.testLocation = fix(metres: 75)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sent = expectation(description: "Manual confirmation sent beyond the automatic radius")
        PresenceTestURLProtocol.onRequest = { request in
            XCTAssertEqual(request.url?.path, "/machines/42/confirm-presence")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            XCTAssertEqual(body?["source"] as? String, "manual")
            sent.fulfill()
        }
        defer {
            PresenceTestURLProtocol.onRequest = nil
            session.invalidateAndCancel()
        }
        let monitor = MachinePresenceMonitor(hasNearbyMachine: { _ in false }, isBlocked: { _ in false },
                                             manager: manager, session: session, isActive: { true })
        monitor.requestFreshConfirmation(machine, source: .manual)
        await fulfillment(of: [sent], timeout: 3)
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
    static var response: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onRequest?(request)
        let (status, data) = Self.response?(request) ?? (200, Data("{}".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
