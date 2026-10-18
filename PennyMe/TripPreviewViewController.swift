import MapKit
import UIKit

/// A trip preview with local geodesic matching and optional MapKit road legs.
final class TripPreviewViewController: UIViewController, MKMapViewDelegate {
    private let link: String
    private let machines: [Artwork]
    private let map = MKMapView()
    private let status = UILabel()
    private let routeNote = UILabel()
    private let google = UIButton(type: .system)
    private let apple = UIButton(type: .system)
    private let remove = UIButton(type: .system)
    private var trip: Trip?
    private var matches: [(machine: Artwork, extra: CLLocationDistance)] = []
    private var extras: [String: CLLocationDistance] = [:]
    private var selected: Artwork?
    private var selectedStops: [Artwork] = []
    private var baseline: MKPolyline?
    private var roadRoutes: [MKRoute] = []
    private var connection: MKPolyline?
    private var directions: MKDirections?
    private var roadRequestID = 0
    private var directRoadDistance: CLLocationDistance?
    private var roadPreviewComplete = false
    private var roadPreviewLoading = false
    private var importTask: Task<Void, Never>?

    init(link: String, machines: [Artwork]) {
        self.link = link
        self.machines = machines
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(link:machines:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Trip preview"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        map.delegate = self
        map.showsUserLocation = true
        for label in [status, routeNote] {
            label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
        }
        routeNote.textColor = .secondaryLabel
        status.text = "Reading trip…"
        google.setTitle("Open in Google Maps", for: .normal)
        apple.setTitle("Open in Apple Maps", for: .normal)
        remove.setTitle("Remove stop", for: .normal)
        google.addTarget(self, action: #selector(exportGoogle), for: .touchUpInside)
        apple.addTarget(self, action: #selector(exportApple), for: .touchUpInside)
        remove.addTarget(self, action: #selector(removeStop), for: .touchUpInside)
        for button in [google, apple, remove] {
            button.isEnabled = false
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        if #available(iOS 18.4, *) {} else { apple.isHidden = true }
        let controls = UIStackView(arrangedSubviews: [status, routeNote, remove, google, apple])
        controls.axis = .vertical
        controls.spacing = 8
        controls.isLayoutMarginsRelativeArrangement = true
        controls.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let stack = UIStackView(arrangedSubviews: [map, controls])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        importTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let trip = try await TripLink.importTrip(from: self.link)
                try Task.checkCancellation()
                await MainActor.run { self.display(trip) }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { self.status.text = error.localizedDescription }
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            importTask?.cancel()
            directions?.cancel()
        }
    }

    private func display(_ trip: Trip) {
        self.trip = trip
        matches = trip.matches(in: machines)
        extras = Dictionary(uniqueKeysWithValues: matches.map { ($0.machine.id, $0.extra) })
        map.addAnnotations(machines)
        for (name, item) in [("Start", trip.start), ("Destination", trip.end)] {
            let pin = MKPointAnnotation()
            pin.coordinate = item.placemark.coordinate
            pin.title = name
            pin.subtitle = item.name
            map.addAnnotation(pin)
        }
        let points = [trip.start.placemark.coordinate, trip.end.placemark.coordinate]
        let fallback = MKGeodesicPolyline(coordinates: points, count: points.count)
        baseline = fallback
        map.addOverlay(fallback)
        updateSelection()
        fitTrip()
        refreshRoadPreview()
    }

    private func fitTrip() {
        var rect = roadRoutes.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
        if let connection { rect = rect.union(connection.boundingMapRect) }
        if rect.isNull { rect = baseline?.boundingMapRect ?? connection?.boundingMapRect ?? .null }
        guard !rect.isNull else { return }
        let machines = selectedStops.isEmpty ? matches.prefix(1).map { $0.machine } : selectedStops
        for machine in machines {
            let point = MKMapPoint(machine.coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 50, left: 45, bottom: 50, right: 45), animated: true)
    }

    private var extraDrivingDistance: CLLocationDistance? {
        guard roadPreviewComplete, !selectedStops.isEmpty, let directRoadDistance else { return nil }
        let total = roadRoutes.reduce(0) { $0 + $1.distance }
        return max(0, total - directRoadDistance)
    }

    private func updateStatus() {
        if let machine = selected, let geodesic = extras[machine.id] {
            let detail: String
            if let driving = extraDrivingDistance {
                detail = "\(Trip.formatDistance(driving)) extra driving distance."
            } else if roadPreviewLoading {
                detail = "Calculating extra driving distance…"
            } else {
                detail = "\(Trip.formatDistance(geodesic)) extra geodesic distance (road preview unavailable)."
            }
            status.text = "\(selectedStops.count) stop\(selectedStops.count == 1 ? "" : "s") · \(machine.title ?? "Penny machine") selected · \(detail)"
        } else if !matches.isEmpty {
            status.text = "\(matches.count) matches within \(Trip.formatDistance(Trip.maximumExtraDistance)) extra geodesic distance. The star is the best match. Tap colored machines to add stops."
        } else {
            status.text = "No penny machines within the \(Trip.formatDistance(Trip.maximumExtraDistance)) extra geodesic distance limit."
        }
    }

    private func updateSelection() {
        updateStatus()
        for button in [google, apple, remove] { button.isEnabled = !selectedStops.isEmpty }
        for annotation in map.annotations {
            if let marker = map.view(for: annotation) as? MKMarkerAnnotationView {
                style(marker, annotation: annotation)
            }
        }
        if let connection = connection { map.removeOverlay(connection) }
        connection = nil
        if !selectedStops.isEmpty, let trip = trip {
            let points = [trip.start.placemark.coordinate] + selectedStops.map(\.coordinate) + [trip.end.placemark.coordinate]
            let line = MKGeodesicPolyline(coordinates: points, count: points.count)
            connection = line
            map.addOverlay(line)
        }
    }

    private func refreshRoadPreview() {
        guard let trip else { return }
        directions?.cancel()
        roadRequestID += 1
        let requestID = roadRequestID
        roadPreviewComplete = false
        roadPreviewLoading = true
        for route in roadRoutes { map.removeOverlay(route.polyline) }
        roadRoutes.removeAll()
        if selectedStops.isEmpty, let baseline {
            map.removeOverlay(baseline)
            map.addOverlay(baseline)
        }
        routeNote.text = "Loading road preview. Distances are geodesic estimates, not driving detours."
        updateStatus()
        let stops = selectedStops.map { MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate)) }
        calculateRoadLegs([trip.start] + stops + [trip.end], requestID: requestID, index: 0, routes: [], failures: 0)
    }

    private func calculateRoadLegs(_ points: [MKMapItem], requestID: Int, index: Int,
                                   routes: [MKRoute], failures: Int) {
        guard index + 1 < points.count else {
            roadRoutes = routes
            roadPreviewComplete = failures == 0
            roadPreviewLoading = false
            if selectedStops.isEmpty, let route = routes.first {
                directRoadDistance = route.distance
            }
            for route in routes { map.addOverlay(route.polyline, level: .aboveLabels) }
            if failures == 0 {
                if let baseline { map.removeOverlay(baseline) }
                if let connection { map.removeOverlay(connection) }
                routeNote.text = "Road preview may differ from your original route. Distances use MapKit driving routes."
            } else {
                routeNote.text = "Road preview unavailable for part of this trip. Lines and distances are geodesic estimates, not driving detours."
            }
            updateStatus()
            if #available(iOS 18.4, *) {} else {
                routeNote.text! += " Export with a stop requires Google Maps on this iOS version."
            }
            fitTrip()
            return
        }
        let request = MKDirections.Request()
        request.source = points[index]
        request.destination = points[index + 1]
        request.transportType = .automobile
        let directions = MKDirections(request: request)
        self.directions = directions
        directions.calculate { [weak self] response, error in
            guard let self, self.roadRequestID == requestID else { return }
            if let route = response?.routes.first, route.polyline.pointCount > 1 {
                print("Trip road leg \(index + 1) loaded: \(route.polyline.pointCount) points, \(route.distance) m")
                self.calculateRoadLegs(points, requestID: requestID, index: index + 1,
                                       routes: routes + [route], failures: failures)
            } else {
                print("Trip road leg \(index + 1) unavailable: response=\(String(describing: response)), error=\(String(describing: error))")
                self.calculateRoadLegs(points, requestID: requestID, index: index + 1,
                                       routes: routes, failures: failures + 1)
            }
        }
    }

    private func style(_ marker: MKMarkerAnnotationView, annotation: MKAnnotation) {
        marker.canShowCallout = true
        marker.glyphImage = nil
        marker.glyphText = nil
        if let machine = annotation as? Artwork {
            let best = machine.id == matches.first?.machine.id
            marker.accessibilityIdentifier = best ? "trip-best" : "trip-machine-\(machine.id)"
            marker.markerTintColor = extras[machine.id] == nil ? .systemGray : machine.markerTintColor
            marker.displayPriority = best ? .required : .defaultHigh
            marker.zPriority = best || selectedStops.contains(where: { $0.id == machine.id }) ? .max : .defaultUnselected
            if best { marker.glyphImage = UIImage(systemName: "star.fill") }
            if selectedStops.contains(where: { $0.id == machine.id }) {
                marker.markerTintColor = .systemBlue
                marker.glyphImage = UIImage(systemName: "checkmark")
                marker.displayPriority = .required
            }
        }
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard !(annotation is MKUserLocation) else { return nil }
        if !(annotation is Artwork) {
            // Small endpoint badges stay visible without covering a machine's marker above them.
            let badge = MKAnnotationView(annotation: annotation, reuseIdentifier: nil)
            let symbol = annotation.title == "Start" ? "a.circle.fill" : "b.circle.fill"
            badge.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24))?
                .withTintColor(.darkGray, renderingMode: .alwaysOriginal)
            badge.canShowCallout = true
            badge.displayPriority = .required
            badge.zPriority = .min
            return badge
        }
        let marker = mapView.dequeueReusableAnnotationView(withIdentifier: "trip") as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "trip")
        marker.annotation = annotation
        style(marker, annotation: annotation)
        return marker
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let machine = view.annotation as? Artwork, extras[machine.id] != nil else { return }
        if !selectedStops.contains(where: { $0.id == machine.id }) {
            selectedStops.append(machine)
        }
        selected = machine
        updateSelection()
        refreshRoadPreview()
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        let isRoadRoute = !(line is MKGeodesicPolyline)
        renderer.strokeColor = line === connection || isRoadRoute ? .systemBlue : .systemGray
        renderer.lineWidth = isRoadRoute ? 6 : 4
        if line is MKGeodesicPolyline { renderer.lineDashPattern = [6, 5] }
        return renderer
    }

    @objc private func removeStop() {
        if let selected {
            selectedStops.removeAll { $0.id == selected.id }
        }
        selected = selectedStops.last
        for annotation in map.selectedAnnotations { map.deselectAnnotation(annotation, animated: false) }
        updateSelection()
        refreshRoadPreview()
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func exportGoogle() { export(appleMaps: false) }
    @objc private func exportApple() {
        if #available(iOS 18.4, *) { export(appleMaps: true) }
    }

    private func export(appleMaps: Bool) {
        guard let trip = trip, !selectedStops.isEmpty else { return }
        UIApplication.shared.open(trip.exportURL(appleMaps: appleMaps, stops: selectedStops.map(\.coordinate))) { [weak self] opened in
            if !opened { self?.status.text = "Couldn’t open Maps. Please try again." }
        }
    }
}
