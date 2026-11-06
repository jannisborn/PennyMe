import CoreLocation
import UIKit

struct PresenceMachine: Decodable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

enum MachinePresencePolicy {
    static func isPreciseAndFresh(_ location: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy.isFinite
            && (0...10).contains(location.horizontalAccuracy)
            && (-5...15).contains(age)
    }

    static func canConfirm(_ machine: PresenceMachine, at location: CLLocation, now: Date = Date()) -> Bool {
        isPreciseAndFresh(location, now: now) && location.distance(from: machine.location) <= 20
    }
}

/// Foreground-only checks, independent of the optional background notifications.
final class MachinePresenceMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let hasNearbyMachine: (CLLocation) -> Bool
    private let isBlocked: (Int) -> Bool
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    private var lastQueryLocation: CLLocation?
    private var suppressed: [Int: PresenceMachine] = [:]
    private var waitingForFix: (machine: PresenceMachine, after: Date)?
    private weak var prompt: UIAlertController?
    private var promptedMachine: PresenceMachine?

    init(hasNearbyMachine: @escaping (CLLocation) -> Bool, isBlocked: @escaping (Int) -> Bool) {
        self.hasNearbyMachine = hasNearbyMachine
        self.isBlocked = isBlocked
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
        guard UIApplication.shared.applicationState == .active else { return }
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
        prompt?.dismiss(animated: false)
        prompt = nil
        promptedMachine = nil
        lastAttempt = .distantPast
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        pause()
        resume()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        checkLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let pending = waitingForFix {
            waitingForFix = nil
            showFailure("A fresh, precise location is needed. Please try again while at the machine.", machine: pending.machine)
        }
    }

    private func checkLocation() {
        guard UIApplication.shared.applicationState == .active else { return }
        if let pending = waitingForFix, Date().timeIntervalSince(pending.after) > 15 {
            waitingForFix = nil
            showFailure("Could not get a fresh location. Please try again while at the machine.", machine: pending.machine)
            return
        }
        guard let location = manager.location,
              MachinePresencePolicy.isPreciseAndFresh(location) else {
            prompt?.dismiss(animated: true)
            prompt = nil
            promptedMachine = nil
            return
        }
        // Hysteresis avoids repeated prompts when GPS drifts around the 20 m boundary.
        suppressed = suppressed.filter { location.distance(from: $0.value.location) <= 50 }
        if let machine = promptedMachine, !MachinePresencePolicy.canConfirm(machine, at: location) {
            prompt?.dismiss(animated: true)
            prompt = nil
            promptedMachine = nil
        }
        if let pending = waitingForFix {
            guard location.timestamp >= pending.after else { return }
            waitingForFix = nil
            guard MachinePresencePolicy.canConfirm(pending.machine, at: location), !isBlocked(pending.machine.id) else {
                showFailure("You need to be within 20 metres of the machine to confirm it.", machine: pending.machine)
                return
            }
            confirm(pending.machine, location: location)
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
                  let machines = try? JSONDecoder().decode(Candidates.self, from: data).machines,
                  let current = self.manager.location,
                  let machine = machines.first(where: {
                      self.suppressed[$0.id] == nil && !self.isBlocked($0.id)
                          && MachinePresencePolicy.canConfirm($0, at: current)
                  }) else { return }
            self.askAbout(machine)
        }
    }

    private struct Candidates: Decodable { let machines: [PresenceMachine] }

    private func askAbout(_ machine: PresenceMachine) {
        guard let presenter = availablePresenter() else { return }
        let alert = UIAlertController(
            title: "Is this machine still here?",
            message: "You're near \(machine.name). Can you confirm the machine is still here?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Yes, it's here", style: .default) { [weak self] _ in
            self?.suppressed[machine.id] = machine
            self?.prompt = nil
            self?.promptedMachine = nil
            self?.requestFreshConfirmation(machine)
        })
        alert.addAction(UIAlertAction(title: "I can't confirm", style: .cancel) { [weak self] _ in
            self?.suppressed[machine.id] = machine
            self?.prompt = nil
            self?.promptedMachine = nil
        })
        promptedMachine = machine
        prompt = alert
        presenter.present(alert, animated: true)
    }

    private func requestFreshConfirmation(_ machine: PresenceMachine) {
        guard UIApplication.shared.applicationState == .active else { return }
        waitingForFix = (machine, Date())
        // Force a new fix even when the user is standing still at the machine.
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    private func confirm(_ machine: PresenceMachine, location: CLLocation) {
        send(path: "machines/\(machine.id)/confirm-presence", location: location) { [weak self] data, status in
            guard let self = self else { return }
            if status == 200 {
                self.showMessage(title: "Thank you!", message: "Your sighting of \(machine.name) was saved.")
            } else {
                let response = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let message = response?["error"] as? String
                    ?? "Your sighting could not be saved. Please try again while at the machine."
                self.showFailure(message, machine: machine)
            }
        }
    }

    private func send(path: String, location: CLLocation, completion: @escaping (Data?, Int) -> Void) {
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
            "measured_at": location.timestamp.timeIntervalSince1970
        ])
        let currentGeneration = generation
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == currentGeneration,
                      UIApplication.shared.applicationState == .active else { return }
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
        guard UIApplication.shared.applicationState == .active,
              var controller = window?.rootViewController else { return nil }
        while true {
            if let presented = controller.presentedViewController { controller = presented }
            else if let navigation = controller as? UINavigationController, let visible = navigation.visibleViewController { controller = visible }
            else if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { controller = selected }
            else { break }
        }
        guard !(controller is UIAlertController), !(controller is UIImagePickerController),
              !controller.isBeingPresented, !controller.isBeingDismissed,
              controller.viewIfLoaded?.window != nil else { return nil }
        return controller
    }

    private func showFailure(_ message: String, machine: PresenceMachine) {
        showMessage(title: "Could not confirm", message: message, retry: { [weak self] in
            self?.requestFreshConfirmation(machine)
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
