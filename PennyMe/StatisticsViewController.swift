//
//  StatisticsViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 02.10.24.
//  Copyright © 2024 Jannis Born. All rights reserved.
//

import UIKit

class StatisticsViewController: UIViewController {

    
    @IBOutlet weak var totalMachinesLabel: UILabel!
    @IBOutlet weak var countriesLabel: UILabel!
    @IBOutlet weak var visitedMachinesLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        totalMachinesLabel.text = "Total machines: \(totalMachines)"
        visitedMachinesLabel.text = "Visited machines: \(visitedCount)"
        countriesLabel.text = "Collected from \(visitedByArea.count) different countries"
        
        // Disable autoresizing masks to use Auto Layout
        totalMachinesLabel.translatesAutoresizingMaskIntoConstraints = false
        visitedMachinesLabel.translatesAutoresizingMaskIntoConstraints = false
        countriesLabel.translatesAutoresizingMaskIntoConstraints = false

    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destination.
        // Pass the selected object to the new view controller.
    }
    */

}
