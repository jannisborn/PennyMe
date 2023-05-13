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
    
    @IBOutlet weak var navigationbar: UINavigationItem!
    @IBOutlet weak var pushSwitch: UISwitch!
    @IBOutlet weak var reportProblemButton: UIButton!
    @IBOutlet weak var radiusSlider: UISlider!
    @IBOutlet weak var retiredSwitch: UISwitch!
    @IBOutlet weak var clusterPinsSwitch: UISwitch!
    @IBOutlet weak var markedSwitch: UISwitch!
    @IBOutlet weak var visitedSwitch: UISwitch!
    @IBOutlet weak var unvisitedSwitch: UISwitch!
    
    static var hasChanged = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
            self.navigationbar.standardAppearance = UINavigationBarAppearance()
            self.navigationbar.standardAppearance?.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.black]
        }
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
        
        // cluster switch
        clusterPinsSwitch.isOn = UserDefaults.standard.bool(forKey: "clusterPinSwitch")
        clusterPinsSwitch.addTarget(self, action: #selector(clusterPins), for: .valueChanged)
        // Machine status switches
        // 1) unvisited switch
        unvisitedSwitch.isOn = UserDefaults.standard.bool(forKey: "unvisitedSwitch")
        unvisitedSwitch.addTarget(self, action: #selector(showUnvisitedMachines), for: .valueChanged)
        // 2) visied switch
        visitedSwitch.isOn = UserDefaults.standard.bool(forKey: "visitedSwitch")
        visitedSwitch.addTarget(self, action: #selector(showVisitedMachines), for: .valueChanged)
        // 3) marked switch
        markedSwitch.isOn = UserDefaults.standard.bool(forKey: "markedSwitch")
        markedSwitch.addTarget(self, action: #selector(showMarkedMachines), for: .valueChanged)
        // 4) retired switch
        retiredSwitch.isOn = UserDefaults.standard.bool(forKey: "retiredSwitch")
        retiredSwitch.addTarget(self, action: #selector(showRetiredMachines), for: .valueChanged)
        
    }
    
    @objc func reportProblem (sender: UIButton!){
        let mailtostring = String(
            "mailto:wnina@ethz.ch?subject=[PennyMe] - Problem report&body=Dear PennyMe team,\n\n I would like to inform you about the following problem in your app:\n\n"
        ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
        UIApplication.shared.openURL(URL(string:mailtostring )!)
    }
    // Functions for Switches
    @objc func showUnvisitedMachines(sender:UISwitch!) {
        userdefauls_helper(defaultsKey: "unvisitedSwitch", isOn: sender.isOn)
    }
    @objc func showVisitedMachines(sender:UISwitch!) {
        userdefauls_helper(defaultsKey: "visitedSwitch", isOn: sender.isOn)
    }
    @objc func showMarkedMachines(sender:UISwitch!) {
        userdefauls_helper(defaultsKey: "markedSwitch", isOn: sender.isOn)
    }
    @objc func showRetiredMachines(sender:UISwitch!) {
        userdefauls_helper(defaultsKey: "retiredSwitch", isOn: sender.isOn)
    }
    @objc func clusterPins(sender:UISwitch!) {
        userdefauls_helper(defaultsKey: "clusterPinSwitch", isOn: sender.isOn)
    }
    func userdefauls_helper(defaultsKey: String, isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
        SettingsViewController.hasChanged = true
    }
    
    // Function for radius slider for push notifications
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

