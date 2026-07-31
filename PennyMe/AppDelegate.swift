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


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Create the account-free contributor identifier before any UGC request.
        _ = AppSession.anonymousUserID
        UNUserNotificationCenter.current().delegate = self
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
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
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
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }


}
