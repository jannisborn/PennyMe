import Foundation
import UIKit

class VersionManager {
    
    static let shared = VersionManager()
    
    private let userDefaults = UserDefaults.standard
    
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    
    private let lastVersionKey = "last_version"
    
    func shouldShowVersionInfo() -> Bool {
        if let lastVersion = userDefaults.string(forKey: lastVersionKey) {
            if lastVersion != currentVersion {
                userDefaults.set(currentVersion, forKey: lastVersionKey)
                return true
            }
        } else {
            userDefaults.set(currentVersion, forKey: lastVersionKey)
            return true
        }
        return false
    }
    
    func showVersionInfoAlertIfNeeded() {
        if shouldShowVersionInfo() {
            let alert = UIAlertController(title: "PennyMe v\(currentVersion ?? "")", message: "Let's start crowdsourcing!\nAnything wrong or missing with a machine? Just hit the 'Report change' button and edit any information.\nIn addition, we have added the machine status 'out-of-order'.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
        }
    }
    
}

