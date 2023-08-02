import Foundation
import UIKit

class VersionManager {
    
    static let shared = VersionManager()
    
    private let userDefaults = UserDefaults.standard
    
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    
    private let lastVersionKey = "last_version"
    
    func shouldShowVersionInfo() -> Bool {
        if let lastVersion = userDefaults.string(forKey: lastVersionKey) {
            print(lastVersion)
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
            let alert = UIAlertController(title: "PennyMe v\(currentVersion ?? "")", message: "Add new machines! \n This version allows you to submit a request to add a new machine to the map. Simply press longer on the map, at the location where you found a machine. You can then input some information about the machine. You will have to upload a picture as a “proof”. Help to complete the PennyMe database with your contributions!\n In addition, this version exposes the GPS coordinates of each machine.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            UIApplication.shared.windows.first?.rootViewController?.present(alert, animated: true, completion: nil)
        }
    }
    
}

