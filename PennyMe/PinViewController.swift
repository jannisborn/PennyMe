//
//  PinViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 09.04.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit

class PinViewController: UIViewController {

    @IBOutlet weak var scrollView: UIScrollView!
    @IBOutlet weak var statusPicker: UISegmentedControl!
    @IBOutlet weak var websiteButton: UIButton!
    @IBOutlet weak var titleLabel: UILabel!
    var pinData : Artwork!
    let statusChoices = ["unvisited", "visited", "collected", "retired"]
    
    
    enum StatusChoice : String {
            case Free
            case Collected
            case Marked
            case Retired
        }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let contentWidth = UIScreen.main.bounds.width
        
        addTitle(title: self.pinData.title!)
        statusPicker.selectedSegmentIndex = statusChoices.firstIndex(of: pinData.status) ?? 0
        
        statusPicker.addTarget(self, action: #selector(PinViewController.statusChanged(_:)), for: .valueChanged)
        
        // Website Button
        websiteButton.setTitle("Website", for: .normal)
        websiteButton.backgroundColor = .lightGray
        websiteButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        websiteButton.setTitleColor(.black, for: .normal)
        websiteButton.addTarget(self, action: #selector(PinViewController.goToWebsite(_:)), for:.touchUpInside)

        }
    @objc func goToWebsite(_ sender: UIButton){
        //Open the website when you click on the link.
        UIApplication.shared.openURL(URL(string: pinData.link)!)
    }
    
    @objc func statusChanged(_ sender: UISegmentedControl) {
        let status = StatusChoice(rawValue: sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "unvisited") ?? .Collected
        
        print("changed status", status)
        // TODO
//        let defaults = UserDefaults.standard
//        defaults.set(status, forKey: self.pinData.title!)
//        defaults.synchronize()
        self.pinData.status = status.rawValue
    }
    
    func addTitle(title: String){
        let titleHeight = 100
        let contentWidth = UIScreen.main.bounds.width

        titleLabel.numberOfLines = 3
        titleLabel.textAlignment = NSTextAlignment.center
        titleLabel.text = title
        titleLabel.font = UIFont(name: "Halvetica", size: 20.0)
        scrollView.addSubview(titleLabel)
    }

}
