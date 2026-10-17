import MapKit

/// A two-endpoint Maps link. Other trip shapes are rejected rather than truncated.
struct TripLink {
    let start: String
    let end: String

    enum Failure: String, LocalizedError {
        case unsupported = "Share an Apple Maps or Google Maps directions link."
        case endpoints = "The link must contain a start and destination. Choose an explicit starting place in Maps, then share again."
        case stops = "Trips with existing stops aren’t supported. Share a trip with only a start and destination."
        case location = "A trip endpoint couldn’t be located. Try sharing the route with more specific addresses."
        var errorDescription: String? { rawValue }
    }

    init(url: URL) throws {
        guard SharedTrip.supports(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.unsupported
        }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            items.first { $0.name == key }?.value
        }
        guard !items.contains(where: {
            $0.name.hasPrefix("waypoint") && !($0.value ?? "").isEmpty
        }) else { throw Failure.stops }
        for key in ["source", "destination", "origin", "saddr", "daddr"] {
            guard items.filter({ $0.name == key }).count <= 1 else { throw Failure.stops }
        }
        var origin = value("source") ?? value("origin") ?? value("saddr")
        var destination = value("destination") ?? value("daddr")
        if let range = components.percentEncodedPath.range(of: "/maps/dir/") {
            let path = components.percentEncodedPath[range.upperBound...]
            var places = path.components(separatedBy: "/").prefix {
                !$0.hasPrefix("@") && !$0.hasPrefix("data=")
            }.map { $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? $0 }
            while places.last == "" { places.removeLast() }
            guard places.count <= 2 else { throw Failure.stops }
            if origin == nil && destination == nil && places.count == 2 {
                origin = places[0]
                destination = places[1]
            }
        }
        guard let a = origin?.trimmingCharacters(in: .whitespacesAndNewlines),
              let b = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !a.isEmpty, !b.isEmpty,
              ![a.lowercased(), b.lowercased()].contains(where: {
                  ["my location", "current location", "your location"].contains($0)
              }) else { throw Failure.endpoints }
        guard ![a, b].contains(where: { $0.range(of: "\\bto:", options: .regularExpression) != nil }) else {
            throw Failure.stops
        }
        start = a
        end = b
    }

    /// Expands provider short links; endpoint lookup is the only geocoding performed.
    static func importTrip(from text: String) async throws -> Trip {
        var url = try SharedTrip.url(in: text)
        if ["maps.app.goo.gl", "goo.gl", "maps.apple"].contains(url.host?.lowercased() ?? "") {
            let session = URLSession(configuration: .ephemeral, delegate: MapRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
            guard let expanded = response.url, SharedTrip.supports(expanded) else { throw Failure.unsupported }
            url = expanded
        }
        let link = try TripLink(url: url)
        let start = try await locate(link.start)
        try Task.checkCancellation()
        let end = try await locate(link.end)
        try Task.checkCancellation()
        return Trip(start: start, end: end)
    }

    private static func locate(_ text: String) async throws -> MKMapItem {
        let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if text.components(separatedBy: ",").count == 2 && numbers.count == 2 {
            let coordinate = CLLocationCoordinate2D(latitude: numbers[0], longitude: numbers[1])
            guard CLLocationCoordinate2DIsValid(coordinate) else { throw Failure.location }
            return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        guard let place = try await CLGeocoder().geocodeAddressString(text).first,
              place.location != nil else { throw Failure.location }
        let item = MKMapItem(placemark: MKPlacemark(placemark: place))
        item.name = text
        return item
    }
}

/// Coordinates shared by the local distance filter and both export formats.
struct Trip {
    let start: MKMapItem
    let end: MKMapItem
    static let defaultMaximumExtraDistance: CLLocationDistance = 10_000
    static let maximumExtraDistanceKey = "tripMaximumExtraDistance"
    static var maximumExtraDistance: CLLocationDistance {
        let saved = UserDefaults.standard.double(forKey: maximumExtraDistanceKey)
        return saved > 0 ? saved : defaultMaximumExtraDistance
    }

    static func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1_000 {
            return "\(Int((meters / 100).rounded()) * 100) m"
        }
        return String(format: "%.1f km", meters / 1_000)
    }

    /// Scores every machine before sorting, so input order never determines the best match.
    func matches(in machines: [Artwork]) -> [(machine: Artwork, extra: CLLocationDistance)] {
        machines.map { ($0, extraDistance(via: $0.coordinate)) }
            .filter { $0.1 <= Trip.maximumExtraDistance }
            .sorted { $0.1 < $1.1 }
    }

    func extraDistance(via coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let a = CLLocation(latitude: start.placemark.coordinate.latitude, longitude: start.placemark.coordinate.longitude)
        let b = CLLocation(latitude: end.placemark.coordinate.latitude, longitude: end.placemark.coordinate.longitude)
        let p = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return max(0, a.distance(from: p) + p.distance(from: b) - a.distance(from: b))
    }

    /// Exports selected stops while retaining the imported start and destination.
    func exportURL(appleMaps: Bool, stops: [CLLocationCoordinate2D]) -> URL {
        func location(_ coordinate: CLLocationCoordinate2D) -> String {
            "\(coordinate.latitude),\(coordinate.longitude)"
        }
        var url = URLComponents(string: appleMaps ? "https://maps.apple.com/directions" : "https://www.google.com/maps/dir/")!
        url.queryItems = [
            URLQueryItem(name: appleMaps ? "source" : "origin", value: location(start.placemark.coordinate)),
            URLQueryItem(name: "destination", value: location(end.placemark.coordinate)),
            URLQueryItem(name: appleMaps ? "mode" : "travelmode", value: "driving")
        ]
        if appleMaps {
            url.queryItems?.insert(contentsOf: stops.map { URLQueryItem(name: "waypoint", value: location($0)) }, at: 2)
        } else if !stops.isEmpty {
            url.queryItems?.insert(URLQueryItem(name: "waypoints", value: stops.map(location).joined(separator: "|")), at: 2)
        }
        if !appleMaps { url.queryItems?.append(URLQueryItem(name: "api", value: "1")) }
        return url.url!
    }

    func exportURL(appleMaps: Bool, stop: CLLocationCoordinate2D) -> URL {
        exportURL(appleMaps: appleMaps, stops: [stop])
    }
}

/// Short-link resolution stays on Maps hosts rather than following arbitrary redirects.
private final class MapRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(SharedTrip.supports) == true ? request : nil)
    }
}
