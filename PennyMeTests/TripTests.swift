import XCTest
import MapKit
@testable import PennyMe

final class TripTests: XCTestCase {
    func testSupportedDirectionsFormats() throws {
        let cases = [
            ("https://maps.apple.com/?saddr=Zurich&daddr=Basel&dirflg=d", "Zurich", "Basel"),
            ("https://maps.apple.com/?saddr=Zurich&daddr=Basel&dirflg=r", "Zurich", "Basel"),
            ("https://maps.apple.com/directions?source=47.37,8.54&destination=47.56,7.59&mode=driving", "47.37,8.54", "47.56,7.59"),
            ("https://www.google.com/maps/dir/?api=1&origin=New+York&destination=Boston&travelmode=walking", "New York", "Boston"),
            ("https://www.google.ch/maps/dir/New+York/Boston/@42,-71,8z/data=!4m2!4m1!3e0", "New York", "Boston"),
            ("https://www.google.com/maps/dir/A/B/data=!3e2", "A", "B"),
            ("https://www.google.com/maps/dir/47.37,8.54/47.56,7.59/", "47.37,8.54", "47.56,7.59")
        ]
        for (text, start, end) in cases {
            let link = try TripLink(url: XCTUnwrap(URL(string: text)))
            XCTAssertEqual(link.start, start)
            XCTAssertEqual(link.end, end)
        }
    }

    func testRejectsExistingStopsAndMissingEndpoints() {
        let rejected = [
            "https://maps.apple.com/directions?source=A&destination=B&waypoint=C",
            "https://www.google.com/maps/dir/?origin=A&destination=B&waypoints=C",
            "https://www.google.com/maps/dir/A/C/B/",
            "https://maps.google.com/?saddr=A&daddr=B+to:C",
            "https://maps.apple.com/?saddr=A&daddr=B&daddr=C",
            "https://www.google.com/maps/dir//Boston/",
            "https://maps.apple.com/?daddr=Boston",
            "https://maps.apple.com/?saddr=My%20Location&daddr=Boston",
            "https://example.com/maps/dir/A/B/"
        ]
        for text in rejected {
            XCTAssertThrowsError(try TripLink(url: URL(string: text)!), text)
        }
    }

    func testSharedTextAndHostValidation() throws {
        XCTAssertEqual(try SharedTrip.url(in: "My trip: https://maps.app.goo.gl/example").host, "maps.app.goo.gl")
        for text in ["https://maps.apple.com.evil.example/", "https://google.com@evil.example/",
                     "file:///tmp/maps", "https://google.com:1234/maps", "https://goo.gl/other"] {
            XCTAssertFalse(SharedTrip.supports(URL(string: text)!))
        }
    }

    func testPendingImportStorage() throws {
        let file = try XCTUnwrap(SharedTrip.file)
        let previous = try? Data(contentsOf: file)
        defer {
            if let previous = previous { try? previous.write(to: file) }
            else { try? FileManager.default.removeItem(at: file) }
        }
        let link = "https://maps.apple.com/?saddr=0,0&daddr=0,1"
        try SharedTrip.save("My route: \(link)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), link)
    }

    func testGeodesicFilteringAndExportPreserveEndpoints() async throws {
        let trip = try await TripLink.importTrip(from: "https://maps.apple.com/?saddr=0,0&daddr=0,1")
        let middle = CLLocationCoordinate2D(latitude: 0, longitude: 0.5)
        let near = CLLocationCoordinate2D(latitude: 0.1, longitude: 0.5)
        let far = CLLocationCoordinate2D(latitude: 1, longitude: 0.5)
        XCTAssertEqual(trip.extraDistance(via: middle), 0, accuracy: 1)
        XCTAssertGreaterThan(trip.extraDistance(via: near), trip.extraDistance(via: middle))
        XCTAssertLessThan(trip.extraDistance(via: near), Trip.maximumExtraDistance)
        XCTAssertGreaterThan(trip.extraDistance(via: far), Trip.maximumExtraDistance)
        func machine(_ id: Int, at coordinate: CLLocationCoordinate2D) -> Artwork {
            Artwork(title: "Test \(id)", address: "", link: "", status: "unvisited", coordinate: coordinate,
                    id: id, last_updated: "", multimachine: 1, paywall: false, machineStatus: "available", area: "", numCoins: 4)
        }
        let matches = trip.matches(in: [machine(1, at: far), machine(2, at: near), machine(3, at: middle)])
        XCTAssertEqual(matches.map { $0.machine.id }, ["3", "2"])
        XCTAssertTrue(trip.matches(in: [machine(1, at: far)]).isEmpty)
        for apple in [true, false] {
            let url = trip.exportURL(appleMaps: apple, stop: near)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == (apple ? "source" : "origin") }?.value, "0.0,0.0")
            XCTAssertEqual(items.first { $0.name == "destination" }?.value, "0.0,1.0")
            XCTAssertEqual(items.first { $0.name == (apple ? "waypoint" : "waypoints") }?.value, "0.1,0.5")
            XCTAssertEqual(items.filter { $0.name.hasPrefix("waypoint") }.count, 1)

            let second = CLLocationCoordinate2D(latitude: 0.2, longitude: 0.6)
            let multi = trip.exportURL(appleMaps: apple, stops: [near, second])
            let multiItems = try XCTUnwrap(URLComponents(url: multi, resolvingAgainstBaseURL: false)?.queryItems)
            if apple {
                XCTAssertEqual(multiItems.filter { $0.name == "waypoint" }.count, 2)
            } else {
                XCTAssertEqual(multiItems.first { $0.name == "waypoints" }?.value, "0.1,0.5|0.2,0.6")
            }
        }
    }

    func testInvalidCoordinatesFailWithoutGeocoding() async {
        do {
            _ = try await TripLink.importTrip(from: "https://maps.apple.com/?saddr=1000,0&daddr=0,1")
            XCTFail("Invalid latitude must be rejected")
        } catch {
            XCTAssertEqual(error as? TripLink.Failure, .location)
        }
    }
}
