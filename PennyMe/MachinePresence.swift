import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct PresenceMachine: Decodable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    var numCoins: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude
        case numCoins = "num_coins"
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

struct PresenceCandidates: Decodable {
    let machines: [PresenceMachine]
    let nearbyMachines: [PresenceMachine]?

    enum CodingKeys: String, CodingKey {
        case machines
        case nearbyMachines = "nearby_machines"
    }

    func neighbors(of machine: PresenceMachine, at location: CLLocation) -> [PresenceMachine] {
        MachinePresencePolicy.neighbors(in: nearbyMachines ?? machines, excluding: machine, at: location)
    }
}

enum PresenceConfirmationSource: String {
    case automatic, manual

    var radius: CLLocationDistance { self == .manual ? 100 : 20 }
}

enum MachinePresencePolicy {
    static func neighbors(in machines: [PresenceMachine], excluding machine: PresenceMachine,
                          at location: CLLocation) -> [PresenceMachine] {
        machines.filter {
            $0.id != machine.id && CLLocationCoordinate2DIsValid($0.location.coordinate)
                && $0.location.distance(from: location) <= 100
        }.sorted { $0.location.distance(from: location) < $1.location.distance(from: location) }
    }

    static func isPreciseAndFresh(_ location: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy.isFinite
            && (0...10).contains(location.horizontalAccuracy)
            && (-5...15).contains(age)
    }

    static func canConfirm(_ machine: PresenceMachine, at location: CLLocation,
                           source: PresenceConfirmationSource = .automatic, now: Date = Date()) -> Bool {
        isPreciseAndFresh(location, now: now) && location.distance(from: machine.location) <= source.radius
    }

    static func rediscoveredMachine(from data: Data?) -> Artwork? {
        guard let data = data,
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let response = decoded as? [String: Any],
              let machine = response["machine"] as? [String: Any],
              let properties = machine["properties"] as? [String: Any],
              let status = properties["machine_status"] as? String,
              ["out-of-order", "retired"].contains(status),
              properties["id"] is Int,
              ["name", "address", "area", "external_url", "last_updated"].allSatisfy({ properties[$0] is String }),
              let encoded = try? JSONSerialization.data(withJSONObject: machine),
              let objects = try? MKGeoJSONDecoder().decode(encoded),
              let feature = objects.first as? MKGeoJSONFeature else { return nil }
        return Artwork(feature: feature)
    }
}

/// Foreground-only checks, independent of the optional background notifications.
final class MachinePresenceMonitor: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let session: URLSession
    private let isActive: () -> Bool
    private let hasNearbyMachine: (CLLocation) -> Bool
    private let isBlocked: (Int) -> Bool
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    private var lastQueryLocation: CLLocation?
    private var suppressed: [Int: PresenceMachine] = [:]
    private var waitingForFix: (machine: PresenceMachine, after: Date, source: PresenceConfirmationSource, showPrompt: Bool)?
    private weak var prompt: PresenceConfirmationController?
    private var promptedMachine: PresenceMachine?
    private var promptSource: PresenceConfirmationSource = .automatic
    private var pendingRediscovery: Artwork?
    private var pendingChangeEditor: Artwork?

    init(hasNearbyMachine: @escaping (CLLocation) -> Bool, isBlocked: @escaping (Int) -> Bool,
         manager: CLLocationManager = CLLocationManager(), session: URLSession = .shared,
         isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.hasNearbyMachine = hasNearbyMachine
        self.isBlocked = isBlocked
        self.manager = manager
        self.session = session
        self.isActive = isActive
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
                                             name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pause),
                                             name: UIApplication.willResignActiveNotification, object: nil)
        resume()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        task?.cancel()
        manager.stopUpdatingLocation()
    }

    @objc private func resume() {
        guard isActive() else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        manager.startUpdatingLocation()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkLocation()
            }
        }
    }

    @objc private func pause() {
        generation = UUID()
        manager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        waitingForFix = nil
        // Keep the sheet and photo viewer through temporary app interruptions.
        prompt?.updateLocation(nil, source: promptSource)
        lastAttempt = .distantPast
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        pause()
        resume()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        checkLocation(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Core Location continues trying after a temporary inability to locate us.
        if (error as? CLError)?.code == .locationUnknown { return }
        if let pending = waitingForFix {
            waitingForFix = nil
            showFailure("A fresh, precise location is needed. Please try again while at the machine.", machine: pending.machine,
                        source: pending.source, showPrompt: pending.showPrompt)
        }
    }

    private func checkLocation(_ update: CLLocation? = nil) {
        guard isActive() else { return }
        if presentPendingRediscovery() { return }
        if let pending = waitingForFix, Date().timeIntervalSince(pending.after) > 15 {
            waitingForFix = nil
            showFailure("Could not get a fresh location. Please try again while at the machine.", machine: pending.machine,
                        source: pending.source, showPrompt: pending.showPrompt)
            return
        }
        let latest = update ?? manager.location
        prompt?.updateLocation(latest, source: promptSource)
        guard let location = latest, MachinePresencePolicy.isPreciseAndFresh(location) else { return }
        // Hysteresis avoids repeated prompts when GPS drifts around the 20 m boundary.
        suppressed = suppressed.filter { location.distance(from: $0.value.location) <= 50 }
        if let pending = waitingForFix {
            waitingForFix = nil
            guard !isBlocked(pending.machine.id) else { return }
            guard MachinePresencePolicy.canConfirm(pending.machine, at: location, source: pending.source) else {
                if pending.source == .manual {
                    showMessage(title: "Can't validate", message: "Please move closer. You need to be within 100 metres of the machine.")
                } else {
                    showFailure("You need to be within 20 metres of the machine to confirm it.", machine: pending.machine)
                }
                return
            }
            if pending.showPrompt {
                loadManualPrompt(for: pending.machine, location: location)
            } else {
                confirm(pending.machine, location: location, source: pending.source)
            }
            return
        }
        guard task == nil, prompt == nil, CommunityTermsGate.hasAccepted,
              Date().timeIntervalSince(lastAttempt) >= 30
                || (lastQueryLocation.map { location.distance(from: $0) >= 10 } ?? true),
              hasNearbyMachine(location), availablePresenter() != nil else { return }
        lastAttempt = Date()
        lastQueryLocation = location
        send(path: "machines/nearby-confirmations", location: location) { [weak self] data, status in
            guard let self = self, status == 200, let data = data,
                  let candidates = try? JSONDecoder().decode(PresenceCandidates.self, from: data),
                  let current = self.manager.location,
                  let machine = candidates.machines.first(where: {
                      self.suppressed[$0.id] == nil && !self.isBlocked($0.id)
                          && MachinePresencePolicy.canConfirm($0, at: current)
                  }) else { return }
            self.askAbout(machine, neighbors: candidates.neighbors(of: machine, at: current).filter { !self.isBlocked($0.id) },
                          location: current)
        }
    }

    private func askAbout(_ machine: PresenceMachine, neighbors: [PresenceMachine], location: CLLocation,
                          source: PresenceConfirmationSource = .automatic) {
        guard let presenter = availablePresenter() else { return }
        let sheet = PresenceConfirmationController(machine: machine, neighbors: neighbors, location: location, session: session) { [weak self] confirmed in
            guard let self = self, self.promptedMachine?.id == machine.id else { return }
            self.suppressed[machine.id] = machine
            let controller = self.prompt
            self.prompt = nil
            self.promptedMachine = nil
            controller?.dismiss(animated: true) { [weak self] in
                if confirmed { self?.requestFreshConfirmation(machine, source: source) }
            }
        }
        promptedMachine = machine
        promptSource = source
        prompt = sheet
        presenter.present(sheet, animated: true)
    }

    func requestManualConfirmation(_ machine: PresenceMachine) {
        guard isActive(), prompt == nil, waitingForFix == nil else { return }
        if let running = task {
            // A tap takes priority over an automatic lookup, never over a save.
            guard running.currentRequest?.url?.path.hasSuffix("/nearby-confirmations") == true else { return }
            generation = UUID()
            running.cancel()
            task = nil
        }
        let authorization = manager.authorizationStatus
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            showMessage(title: "Location needed", message: "Please allow precise location access for PennyMe in Settings, then try again.")
            return
        }
        requestFreshConfirmation(machine, source: .manual, showPrompt: true)
    }

    private func loadManualPrompt(for machine: PresenceMachine, location: CLLocation) {
        send(path: "machines/nearby-confirmations", location: location) { [weak self] data, status in
            guard let self = self else { return }
            guard status == 200, let data = data,
                  let candidates = try? JSONDecoder().decode(PresenceCandidates.self, from: data) else {
                self.showFailure("Could not load the machine. Please try again.", machine: machine, source: .manual, showPrompt: true)
                return
            }
            let current = self.manager.location ?? location
            guard let target = (candidates.nearbyMachines ?? candidates.machines).first(where: { $0.id == machine.id }),
                  MachinePresencePolicy.canConfirm(target, at: current, source: .manual), !self.isBlocked(target.id) else {
                self.showMessage(title: "Can't validate", message: "Please move closer and try again with a fresh, precise location.")
                return
            }
            self.askAbout(target, neighbors: candidates.neighbors(of: target, at: current).filter { !self.isBlocked($0.id) },
                          location: current, source: .manual)
        }
    }

    func requestFreshConfirmation(_ machine: PresenceMachine, source: PresenceConfirmationSource = .automatic, showPrompt: Bool = false) {
        guard isActive() else { return }
        waitingForFix = (machine, Date(), source, showPrompt)
        // Reuse an already fresh fix; otherwise wait for continuous updates.
        manager.startUpdatingLocation()
        checkLocation()
    }

    private func confirm(_ machine: PresenceMachine, location: CLLocation, source: PresenceConfirmationSource) {
        send(path: "machines/\(machine.id)/confirm-presence", location: location, source: source) { [weak self] data, status in
            guard let self = self else { return }
            if status == 200 {
                if let rediscovered = MachinePresencePolicy.rediscoveredMachine(from: data) {
                    self.pendingRediscovery = rediscovered
                    self.presentPendingRediscovery()
                } else {
                    self.showMessage(title: "Thank you!", message: "Your sighting of \(machine.name) was saved.")
                }
            } else {
                let response = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let message = response?["error"] as? String
                    ?? "Your sighting could not be saved. Please try again while at the machine."
                self.showFailure(message, machine: machine, source: source)
            }
        }
    }

    /// Wait for other alerts to close before handing off to the regular change form.
    @discardableResult
    private func presentPendingRediscovery() -> Bool {
        guard pendingRediscovery != nil || pendingChangeEditor != nil else { return false }
        guard let presenter = availablePresenter() else { return true }
        if let machine = pendingChangeEditor {
            pendingChangeEditor = nil
            let form = MachineChangedForm(pinData: machine, suggestedStatus: "available")
            presenter.present(UIHostingController(rootView: form), animated: true)
        } else if let machine = pendingRediscovery {
            pendingRediscovery = nil
            let status = machine.machineStatus.replacingOccurrences(of: "-", with: " ")
            let alert = UIAlertController(
                title: "Great, you found it!",
                message: "This machine was previously marked as \(status). Let's submit a status change so it can be shown as active again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.pendingChangeEditor = machine
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.presentPendingRediscovery()
                }
            })
            presenter.present(alert, animated: true)
        }
        return true
    }

    private func send(path: String, location: CLLocation, source: PresenceConfirmationSource = .automatic,
                      completion: @escaping (Data?, Int) -> Void) {
        guard let url = URL(string: path, relativeTo: URL(string: flaskURL)) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.addAnonymousUserHeader()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "measured_at": location.timestamp.timeIntervalSince1970,
            "source": source.rawValue
        ])
        let currentGeneration = generation
        task = session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration,
                      self.isActive() else { return }
                self.task = nil
                completion(data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        }
        task?.resume()
    }

    private func availablePresenter() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
        // The current app also supports the AppDelegate lifecycle without scenes.
        let window = windows.first(where: { $0.isKeyWindow })
            ?? (UIApplication.shared.delegate as? AppDelegate)?.window
        guard isActive(),
              var controller = window?.rootViewController else { return nil }
        while true {
            if let presented = controller.presentedViewController { controller = presented }
            else if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController { controller = visible }
            else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { controller = selected }
            else { break }
        }
        guard !(controller is UIAlertController), !(controller is UIImagePickerController),
              !(controller is PresenceConfirmationController),
              !(controller is UIHostingController<MachineChangedForm>),
              !controller.isBeingPresented, !controller.isBeingDismissed,
              controller.viewIfLoaded?.window != nil else { return nil }
        return controller
    }

    private func showFailure(_ message: String, machine: PresenceMachine,
                             source: PresenceConfirmationSource = .automatic, showPrompt: Bool = false) {
        showMessage(title: "Could not confirm", message: message, retry: { [weak self] in
            self?.requestFreshConfirmation(machine, source: source, showPrompt: showPrompt)
        })
    }

    private func showMessage(title: String, message: String, retry: (() -> Void)? = nil) {
        guard let presenter = availablePresenter() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if let retry = retry { alert.addAction(UIAlertAction(title: "Try again", style: .default) { _ in retry() }) }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: true)
    }
}
