//
//  AboutViewController.swift
//  PennyMe
//
//  Created by Jannis Born on 22.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import UIKit

class AboutViewController: UIViewController {

    
    @IBOutlet weak var label: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
        
        self.label.contentMode = .scaleToFill
        self.label.numberOfLines = 30

        self.label.text = "PennyMe makes collecting pennys easier than ever before - anywhere you travel. \n\nYou can view locations of nearby penny machines and explore your favorite destinations. Change the status of the pins and turn PennyMe into your digital penny collection. PennyMe also helps you to navigate to the next machine and provides pictures and more information about each machine. To ease your life, PennyMe can also send you push notifications if you are nearby an unvisted penny machine.  Please help growing our database by sending pictures or information about machine and feel free to send us any feedback. \n\nThis is PennyMe V1.2.\n©Jannis Born & Nina Wiedemann (2022)"
    }
}

