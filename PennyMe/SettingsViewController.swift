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
    @IBOutlet weak var retiredSwitch: UISwitch!
    @IBOutlet weak var clusterPinsSwitch: UISwitch!
    @IBOutlet weak var markedSwitch: UISwitch!
    @IBOutlet weak var visitedSwitch: UISwitch!
    @IBOutlet weak var unvisitedSwitch: UISwitch!
    
    static var hasChanged = false
    static var clusterHasChanged = false
    private let legalIndexPath = IndexPath(row: 0, section: 4)
    private let blockedContentIndexPath = IndexPath(row: 1, section: 4)
    let default_switches: [String: Bool] = [
        "unvisitedSwitch": true,
        "visitedSwitch": true,
        "markedSwitch": true,
        "retiredSwitch": true,
        "clusterPinSwitch": false
    ]
    
    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 32
        tableView.sectionFooterHeight = UITableView.automaticDimension
        tableView.estimatedSectionFooterHeight = 60

        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
            self.navigationbar.standardAppearance = UINavigationBarAppearance()
            self.navigationbar.standardAppearance?.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.black]
        }
        var reportConfiguration = UIButton.Configuration.plain()
        reportConfiguration.title = "Report a problem"
        reportConfiguration.titleLineBreakMode = .byWordWrapping
        reportConfiguration.contentInsets = .zero
        reportProblemButton.configuration = reportConfiguration
        reportProblemButton.contentHorizontalAlignment = .leading
        reportProblemButton.tintColor = UIColor.black
        reportProblemButton.addTarget(self, action: #selector(reportProblem), for: .touchUpInside)
        
        // push notification button
        pushSwitch.isOn =  UserDefaults.standard.bool(forKey: "switchState")
        pushSwitch.addTarget(self, action: #selector(setPushNotifications), for: .valueChanged)
        
        // cluster switch
        let user_settings = UserDefaults.standard
        clusterPinsSwitch.isOn = user_settings.value(forKey: "clusterPinSwitch") as? Bool ?? default_switches["clusterPinSwitch"] as! Bool
        clusterPinsSwitch.addTarget(self, action: #selector(clusterPins), for: .valueChanged)
        // Machine status switches
        // 1) unvisited switch
        unvisitedSwitch.isOn = user_settings.value(forKey: "unvisitedSwitch") as? Bool ?? default_switches["unvisitedSwitch"] as! Bool
        unvisitedSwitch.addTarget(self, action: #selector(showUnvisitedMachines), for: .valueChanged)
        // 2) visied switch
        visitedSwitch.isOn = user_settings.value(forKey: "visitedSwitch") as? Bool ?? default_switches["visitedSwitch"] as! Bool
        visitedSwitch.addTarget(self, action: #selector(showVisitedMachines), for: .valueChanged)
        // 3) marked switch
        markedSwitch.isOn = user_settings.value(forKey: "markedSwitch") as? Bool ?? default_switches["markedSwitch"] as! Bool
        markedSwitch.addTarget(self, action: #selector(showMarkedMachines), for: .valueChanged)
        // 4) retired switch
        retiredSwitch.isOn = user_settings.value(forKey: "retiredSwitch") as? Bool ?? default_switches["retiredSwitch"] as! Bool
        retiredSwitch.addTarget(self, action: #selector(showRetiredMachines), for: .valueChanged)
    }

    @objc func reportProblem (sender: UIButton!){
        let mailtostring = String(
            "mailto:ninawiedemann999@gmail.com?subject=[PennyMe] - Problem report&body=Dear PennyMe team,\n\n I would like to inform you about the following problem in your app:\n\n"
        ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
        UIApplication.shared.open(URL(string: mailtostring)!)
    }

    private func showLegalDocuments() {
        let sheet = UIAlertController(
            title: "PennyMe Legal",
            message: "Review the documents that govern community contributions and privacy.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Terms of Use", style: .default) { _ in
            self.openLegalDocument(named: "terms_of_use", title: "Terms of Use")
        })
        sheet.addAction(UIAlertAction(title: "Privacy Policy", style: .default) { _ in
            self.openLegalDocument(named: "privacy_policy", title: "Privacy Policy")
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            let sourceView: UIView
            if let cell = tableView.cellForRow(at: legalIndexPath) {
                sourceView = cell
            } else {
                sourceView = tableView
            }
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(sheet, animated: true)
    }

    private func openLegalDocument(named name: String, title: String) {
        let controller = LegalDocumentViewController(documentName: name, title: title)
        if let navigationController = navigationController {
            navigationController.pushViewController(controller, animated: true)
        } else {
            let navigationController = UINavigationController(rootViewController: controller)
            controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(dismissPresentedController)
            )
            present(navigationController, animated: true)
        }
    }

    @objc private func dismissPresentedController() {
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        if indexPath == legalIndexPath {
            showLegalDocuments()
        } else if indexPath == blockedContentIndexPath {
            let controller = BlockedContentViewController()
            if let navigationController = navigationController {
                navigationController.pushViewController(controller, animated: true)
            } else {
                controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .done,
                    target: self,
                    action: #selector(dismissPresentedController)
                )
                present(UINavigationController(rootViewController: controller), animated: true)
            }
        } else if tableView.cellForRow(at: indexPath)?.contentView.subviews.compactMap({ $0 as? UILabel }).first?.text == "Import trip" {
            importTrip()
        }
    }

    private func importTrip() {
        let alert = UIAlertController(title: "Import trip", message: "Paste an Apple Maps or Google Maps directions link with a start and destination, without existing stops.", preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "Maps link"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Preview", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            guard let self = self else { return }
            self.dismiss(animated: true) {
                self.navigationController?.popViewController(animated: true)
                NotificationCenter.default.post(name: .tripImportRequested, object: text)
            }
        })
        present(alert, animated: true)
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
        if defaultsKey == "clusterPinSwitch" {
            SettingsViewController.clusterHasChanged = true
        }
        else {
            SettingsViewController.hasChanged = true
        }
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
            return "Notify me when within 1KM of unvisited machine. NOTE: Open app regularly to keep this active."
        }
        if section == 5{
            return "Tell us if there is a problem with the app! To update a penny machine, please use `Report Change` at the bottom of the machine view."
        }
        return nil
    }
}
