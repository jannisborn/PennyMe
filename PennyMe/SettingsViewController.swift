//
//  SettingsViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 17.06.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit
import MapKit
import CoreLocation
import Contacts

class SettingsViewController: UITableViewController {
    
    @IBOutlet weak var pushSwitch: UISwitch!
    @IBOutlet weak var reportProblemButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        reportProblemButton!.titleLabel?.text = "Report a problem"
        reportProblemButton.tintColor = UIColor.black
        reportProblemButton.addTarget(self, action: #selector(reportProblem), for: .touchUpInside)
        
        // push notification button
        pushSwitch.isOn =  UserDefaults.standard.bool(forKey: "switchState")
        pushSwitch.addTarget(self, action: #selector(setPushNotifications), for: .valueChanged)
    }
    
    @objc func reportProblem (sender: UIButton!){
        let mailtostring = String(
            "mailto:wnina@ethz.ch?subject=[PennyMe] - Problem report&body=Dear PennyMe team,\n\n I would like to inform you about the following problem in your app:\n\n"
        ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
        UIApplication.shared.openURL(URL(string:mailtostring )!)
    }
    
    @objc func setPushNotifications(sender:UISwitch!) {
        UserDefaults.standard.set(sender.isOn, forKey: "switchState")
        UserDefaults.standard.synchronize()
        if sender.isOn{
            print("Push notifications On")
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = true
        }
        else{
            print("Push notifications Off")
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = false
        }
    }

}
