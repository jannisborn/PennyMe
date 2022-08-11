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
    @IBOutlet weak var radiusSlider: UISlider!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        reportProblemButton!.titleLabel?.text = "Report a problem"
        reportProblemButton.tintColor = UIColor.black
        reportProblemButton.addTarget(self, action: #selector(reportProblem), for: .touchUpInside)
        
        // push notification button
        pushSwitch.isOn =  UserDefaults.standard.bool(forKey: "switchState")
        pushSwitch.addTarget(self, action: #selector(setPushNotifications), for: .valueChanged)
        
        // slider
        radiusSlider.value =  UserDefaults.standard.float(forKey: "radius")
        radius = Double(radiusSlider.value)
        radiusSlider.addTarget(self, action: #selector(sliderValueDidChange(_:)), for: .valueChanged)
        radiusSlider.isContinuous = false
    }
    
    @objc func reportProblem (sender: UIButton!){
        let mailtostring = String(
            "mailto:wnina@ethz.ch?subject=[PennyMe] - Problem report&body=Dear PennyMe team,\n\n I would like to inform you about the following problem in your app:\n\n"
        ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
        UIApplication.shared.openURL(URL(string:mailtostring )!)
    }
    
    @objc func sliderValueDidChange(_ sender:UISlider!)
    {
        radius =  Double(sender.value)
        UserDefaults.standard.set(sender.value, forKey: "radius")
        UserDefaults.standard.synchronize()
        self.tableView.reloadData()
    }
    
    @objc func setPushNotifications(sender:UISwitch!) {
        if sender.isOn{
            // Case 1: location access not enabled
            if CLLocationManager.authorizationStatus() != .authorizedAlways{
                showAlert()
                sender.isOn = false
            }
            // Case 2: location access enabled
            else{
                locationManager.startMonitoringSignificantLocationChanges()
                locationManager.allowsBackgroundLocationUpdates = true
            }
        }
        else{
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = false
        }
        UserDefaults.standard.set(sender.isOn, forKey: "switchState")
        UserDefaults.standard.synchronize()
    }
    @IBAction func showAlert() {

            // create the alert
            let alert = UIAlertController(title: "Location services required", message: "For this function, go to your Settings and set allow location access to 'Always' for PennyMe", preferredStyle: .alert)

            // add an action (button)
            alert.addAction(UIAlertAction(title: "OK", style: UIAlertAction.Style.default, handler: nil))

            // show the alert
            self.present(alert, animated: true, completion: nil)
        }
    
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?{

        if section == 1{
            return "Send push notification if a new penny machine is less than \(Int(self.radiusSlider.value)) km away. Location services must be set to 'Always' in settings. Attention: The app must be opened regularly to keep the location updates running."
        }
        if section == 2{
            return "Tell us if 1) there is a problem wit the app, 2) if you found a new machine that is not listed, or 3) a machine has changed"
        }
        return ""
    }
}

