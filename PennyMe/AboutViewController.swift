//
//  AboutViewController.swift
//  PennyMe
//
//  Created by Jannis Born on 22.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import UIKit

class AboutViewController: UIViewController, UITextViewDelegate {

    
    @IBOutlet weak var aboutscreen: UITextView!
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
        // Set properties for the UITextView
        aboutscreen.isEditable = false
        aboutscreen.font = UIFont.systemFont(ofSize: 16)
        aboutscreen.textColor = UIColor.black
        aboutscreen.backgroundColor = UIColor.lightGray.withAlphaComponent(0.1)
        aboutscreen.text = """
            PennyMe makes collecting pennys easier than ever before - anywhere you travel. \n\nView locations of nearby penny machines and explore your favorite destinations. Change the status of the pins and turn PennyMe into your digital penny collection. PennyMe also helps you to navigate to the next machine and provides pictures and more information about each machine. To ease your life, PennyMe can also send you push notifications if you are nearby an unvisted penny machine.  Please help growing our database by uploading pictures, commenting about your experience or adding new machines (long tap on the map). Feel free to send us any feedback, we are two free time developers :) \n\nThis is PennyMe v\(currentVersion ?? "").\n©Jannis Born & Nina Wiedemann (2026).\n\nKudos to open-source contributors:\nZain Malik 
        
        """
        // Implement UITextViewDelegate methods if needed
        aboutscreen.delegate = self
        }
    func textViewDidChange(_ textView: UITextView) {
           // Respond to text changes here
       }
}

