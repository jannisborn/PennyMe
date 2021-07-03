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
    @IBOutlet weak var addressLabel: UILabel!
    var pinData : Artwork!
    let statusChoices = ["unvisited", "visited", "marked", "retired"]
    
    
    enum StatusChoice : String {
            case unvisited
            case visited
            case marked
            case retired
        }
    
    @IBOutlet weak var textLabel: UILabel!
    @IBOutlet weak var imageView: UIImageView!
    
    
    var artwork: Artwork? {
      didSet {
        configureView()
      }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let contentWidth = UIScreen.main.bounds.width
        
        addTitle(title: self.pinData.title!)
        addAddress(address: self.pinData.locationName)
        
        statusPicker.selectedSegmentIndex = statusChoices.firstIndex(of: pinData.status) ?? 0
        
        statusPicker.addTarget(self, action: #selector(PinViewController.statusChanged(_:)), for: .valueChanged)
        
        // Website Button
        websiteButton.setTitle("Website", for: .normal)
        websiteButton.backgroundColor = .lightGray
        websiteButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        websiteButton.setTitleColor(.black, for: .normal)
        websiteButton.addTarget(self, action: #selector(PinViewController.goToWebsite(_:)), for:.touchUpInside)

        }
    
    func configureView() {
      if let artwork = artwork,
        let textLabel = textLabel,
        let imageView = imageView {
        textLabel.text = artwork.title
        imageView.image = UIImage(named: "maps")
        title = artwork.title
      }
    }
    
    @objc func goToWebsite(_ sender: UIButton){
        //Open the website when you click on the link.
        UIApplication.shared.openURL(URL(string: pinData.link)!)
    }
    
    @objc func statusChanged(_ sender: UISegmentedControl) {
        let status = StatusChoice(rawValue: sender.titleForSegment(at: sender.selectedSegmentIndex) ?? "unvisited") ?? .unvisited
        
        saveStatusChange(machineid: self.pinData.id, new_status: status.rawValue)
    }
    
    func saveStatusChange(machineid: String, new_status: String){
        // find directory in documents folder corresponding to app data
        let documentsDirectoryPathString = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let documentsDirectoryPath = NSURL(string: documentsDirectoryPathString)!

        // set output file path
        let jsonFilePath = documentsDirectoryPath.appendingPathComponent("pin_status.json")
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        // creating a .json file in the Documents folder
        // first check whether file exists
        var currentStatusDict = [[String: String]()]
        // Load the json data
        if fileManager.fileExists(atPath: jsonFilePath!.absoluteString, isDirectory: &isDirectory) {
            do{
                let data = try Data(contentsOf: URL(fileURLWithPath: jsonFilePath!.absoluteString), options:.mappedIfSafe)
                let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
                currentStatusDict = jsonResult as! [[String:String]]
//                print("Read json successfully for changing status", jsonResult)
                // remove file
                try fileManager.removeItem(atPath: jsonFilePath!.absoluteString)
            }
            catch{
                print("file already exists but could not be read", error)
            }
        }
//        print("loaded / new status dictionary", currentStatusDict)
        // update value
        currentStatusDict[0][machineid] = new_status
//        print("after update value", currentStatusDict)
        
        // creating JSON out of the above array
        var jsonData: NSData!
        do {
            // setup json encoder
            jsonData = try JSONSerialization.data(withJSONObject: currentStatusDict, options: JSONSerialization.WritingOptions()) as NSData
            let jsonString = String(data: jsonData as Data, encoding: String.Encoding.utf8)
        } catch let error as NSError {
            print("Array to JSON conversion failed: \(error.localizedDescription)")
        }

        // Write that JSON
        do {
            // Bug fix: create new file each time to prevent that file is only partly overwritten
            let created = fileManager.createFile(atPath: jsonFilePath!.absoluteString, contents: nil, attributes: nil)
            if !created {
                print("Couldn't create file for some reason")
            }
            let file = try FileHandle(forWritingTo: jsonFilePath!)
            file.write(jsonData as Data)
//            print("JSON data was written to teh file successfully!")
        } catch let error as NSError {
            print("Couldn't write to file: \(error.localizedDescription)")
        }
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
    
    func addAddress(address: String){
        let titleHeight = 100
        let contentWidth = UIScreen.main.bounds.width

        addressLabel.numberOfLines = 3
        addressLabel.textAlignment = NSTextAlignment.center
        addressLabel.text = address
        addressLabel.font = UIFont(name: "Halvetica", size: 13.0)
        scrollView.addSubview(addressLabel)
    }
}
