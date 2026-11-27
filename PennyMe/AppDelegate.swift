//
//  AppDelegate.swift
//  PennyMe
//
//  Created by Jannis Born on 11.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//
import Siren
import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?
    private var didStartCommunityGate = false
    private var didCheckForUpdates = false
    private lazy var coffeeTipReminder = CoffeeTipReminder { [weak self] in
        self?.presentCoffeeTipPrompt() ?? false
    }


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Create the account-free contributor identifier before any UGC request.
        _ = AppSession.anonymousUserID
        UNUserNotificationCenter.current().delegate = self
        Task { await CoffeeTips.handleTransactionUpdates() }
        return true
    }

    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme?.lowercased() == "pennyme" else { return false }
        NotificationCenter.default.post(name: .tripImportRequested, object: nil)
        return true
    }

    private func checkForUpdates() {
        guard !didCheckForUpdates else { return }
        didCheckForUpdates = true

        UIApplication.shared.registerUserNotificationSettings(
            UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
        )

        let siren = Siren.shared
        siren.rulesManager = RulesManager(
            majorUpdateRules: .critical,
            minorUpdateRules: .default,
            patchUpdateRules: .default,
            revisionUpdateRules: .default
        )
        siren.presentationManager = PresentationManager(
            alertTintColor: .systemBlue,
            appName: "PennyMe",
            alertTitle: "Update Available!",
            alertMessage: "A new version of PennyMe is available. Please update to continue.",
            updateButtonTitle: "Update",
            nextTimeButtonTitle: "Next time",
            skipButtonTitle: "Skip this version"
        )
        siren.wail()
    }
// Insert this to enable foreground notifications
//    func userNotificationCenter(_ center: UNUserNotificationCenter,
//                                willPresent notification: UNNotification,
//                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
//        completionHandler([.alert, .sound, .badge])
//    }

    func applicationWillResignActive(_ application: UIApplication) {
        coffeeTipReminder.pause()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // check whether push notifications are enabled
        if UserDefaults.standard.bool(forKey: "switchState"){
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = true
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        coffeeTipReminder.resume()
        guard !didStartCommunityGate,
              let rootViewController = window?.rootViewController else {
            return
        }
        didStartCommunityGate = true
        CommunityTermsGate.start(from: rootViewController) { [weak self] in
            self?.checkForUpdates()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        coffeeTipReminder.pause()
    }

    private func presentCoffeeTipPrompt() -> Bool {
        guard UIApplication.shared.applicationState == .active, CommunityTermsGate.hasAccepted,
              let window, window.isKeyWindow,
              let navigation = window.rootViewController as? UINavigationController,
              navigation.presentedViewController == nil,
              let map = navigation.topViewController as? ViewController,
              map.viewIfLoaded?.window === window, map.presentedViewController == nil,
              map.transitionCoordinator == nil, !map.searchController.isActive else { return false }

        let alert = UIAlertController(title: "☕️ Support PennyMe", message: CoffeeTips.supportMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: CoffeeTips.title, style: .default) { [weak navigation] _ in
            navigation?.pushViewController(CoffeeTipView.makeController(), animated: true)
        })
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        map.present(alert, animated: true)
        return true
    }
}

@MainActor
final class CoffeeTipReminder {
    private static let interval: TimeInterval = 30 * 60
    private static let elapsedKey = "coffeeTipReminder.activeSeconds"

    private let defaults: UserDefaults
    private let present: () -> Bool
    private var timer: Timer?
    private var lastCheckpoint: TimeInterval?

    init(defaults: UserDefaults = .standard, present: @escaping () -> Bool) {
        self.defaults = defaults
        self.present = present
    }

    private var elapsed: TimeInterval {
        get { defaults.double(forKey: Self.elapsedKey) }
        set { defaults.set(newValue, forKey: Self.elapsedKey) }
    }

    func resume(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard lastCheckpoint == nil else { return }
        lastCheckpoint = now
        scheduleCheck()
    }

    func pause(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        timer?.invalidate()
        timer = nil
        saveProgress(at: now)
        lastCheckpoint = nil
    }

    func check(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard lastCheckpoint != nil else { return }
        saveProgress(at: now)
        if elapsed >= Self.interval && present() {
            elapsed = 0
        }
        scheduleCheck()
    }

    private func saveProgress(at now: TimeInterval) {
        guard let lastCheckpoint else { return }
        self.lastCheckpoint = now
        // Cap at one pending prompt while another screen is in use.
        elapsed = min(Self.interval, elapsed + max(0, now - lastCheckpoint))
    }

    private func scheduleCheck() {
        timer?.invalidate()
        let remaining = Self.interval - elapsed
        // Save a checkpoint each minute and retry a deferred prompt after five seconds.
        let delay = remaining > 0 ? min(remaining, 60) : 5
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }
}
