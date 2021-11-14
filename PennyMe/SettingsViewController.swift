//
//  SettingsViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 17.06.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit

class SettingsViewController: UITableViewController {
    
    @IBOutlet weak var reportProblemButton: UIButton!
    // @IBOutlet weak var aboutButton: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        reportProblemButton.tintColor = UIColor.black
        reportProblemButton.addTarget(self, action: #selector(reportProblem), for: .touchUpInside)
    }
    
    @objc func reportProblem (sender: UIButton!){
        UIApplication.shared.openURL(URL(string: "mailto:wnina@ethz.de")!)
    }

}
