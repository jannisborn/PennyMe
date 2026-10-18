import Foundation

/// One pending import shared between the Share extension and the main app.
enum SharedTrip {
    static let group = "group.de.pennyme.trips"
    static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("pending-trip.txt")
    }

    static func supports(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return ["maps.apple.com", "maps.apple", "maps.app.goo.gl"].contains(host)
            || (host == "goo.gl" && url.path.hasPrefix("/maps/"))
            || host.range(of: "^(www\\.|maps\\.)?google\\.(com|[a-z]{2}|co\\.[a-z]{2}|com\\.[a-z]{2})$", options: .regularExpression) != nil
    }

    static func url(in text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        guard let url = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url,
              supports(url) else {
            throw NSError(domain: "TripImport", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Share or paste an Apple Maps or Google Maps directions link."])
        }
        return url
    }

    static func save(_ text: String) throws {
        let url = try url(in: text)
        guard let file = file else {
            throw NSError(domain: "TripImport", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Trip sharing is unavailable. Copy the link and use Import trip in PennyMe."])
        }
        try url.absoluteString.write(to: file, atomically: true, encoding: .utf8)
    }
}

extension Notification.Name {
    static let tripImportRequested = Notification.Name("tripImportRequested")
}
