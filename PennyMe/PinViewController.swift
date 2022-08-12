//
//  PinViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 09.04.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit
import MapKit

var FOUNDIMAGE : Bool = false

class PinViewController: UITableViewController {

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var addressLabel: UILabel!
    @IBOutlet weak var updatedLabel: UILabel!
    @IBOutlet weak var statusPicker: UISegmentedControl!
    @IBOutlet weak var websiteCell: UITableViewCell!
    @IBOutlet weak var imageview: UIImageView!
    
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
        
        // Add title, address and updated
        titleLabel.numberOfLines = 3
        titleLabel.textAlignment = NSTextAlignment.center
        titleLabel.text = self.pinData.title!
        addressLabel.numberOfLines = 3
        addressLabel.text = self.pinData.locationName
        updatedLabel.text = self.pinData.last_updated
        
        // default status
        statusPicker.selectedSegmentIndex = statusChoices.firstIndex(of: pinData.status) ?? 0
        
        statusPicker.addTarget(self, action: #selector(PinViewController.statusChanged(_:)), for: .valueChanged)
        
        // load image asynchronously
        self.imageview.getImage(id: self.pinData.id)
        // initialize tap gesture to enlarge image
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(imageTapped(tapGestureRecognizer:)));
        self.imageview.isUserInteractionEnabled = true
        self.imageview.addGestureRecognizer(tapGestureRecognizer)
        
        }
    
    @objc func imageTapped(tapGestureRecognizer: UITapGestureRecognizer)
    {
        if FOUNDIMAGE{
            self.performSegue(withIdentifier: "bigImage", sender: self)
        }
        else{
            //open mailto url
            let mailtostring = String(
                "mailto:wnina@ethz.ch?subject=[PennyMe] - Picture of machine \(pinData.id)&body=Dear PennyMe developers,\n\n Please find enclosed a picture of the machine at \(pinData.title!) (ID=\(pinData.id)).\n<b>Details of machine</b>:\n**PLEASE FILL IN ANY IMPORTANT DETAILS HERE. NOTE: Please send a sharp picture in <b>landscape</b> orientation. The penny motives should be visible, otherwise sent multiple images**\n\nWith sending this mail, I grant the PennyMe team the unrestricted right to process, alter, share, distribute and publicly expose this image.\n\n With best regards,"
            ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
            UIApplication.shared.openURL(URL(string: mailtostring)!)
        }
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
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
        {
        // Website is section 4 of the table view currently
        if indexPath.section == 4
            {
                //Open the website when you click on the link.
                UIApplication.shared.openURL(URL(string: pinData.link)!)
            }
            else if indexPath.section == 2 {
                let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
                self.pinData.mapItem().openInMaps(launchOptions: launchOptions)
            }
        if indexPath.section == 5{
            let mailtostring = String(
                "mailto:wnina@ethz.ch?subject=[PennyMe] - Change of machine \(pinData.id)&body=Dear PennyMe developers,\n\n I have noted a change of machine \(pinData.title!) (ID=\(pinData.id)).\n<b>Details:</b>:\n**PLEASE PROVIDE ANY IMPORTANT DETAILS HERE, e.g. STATUS CHANGE, CORRECT ADDRESS, GEOGRAPHIC COORDINATES, etc.\n\n With best regards,"
            ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
            UIApplication.shared.openURL(URL(string:mailtostring )!)
            }
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
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if (segue.identifier == "bigImage") {
            let destinationViewController = segue.destination as! ZoomViewController
            destinationViewController.image = self.imageview.image
        }
        
    }
    
}

extension UIImageView {
    func loadURL(url: URL) {
        FOUNDIMAGE = false
        DispatchQueue.global().async { [weak self] in
            if let data = try? Data(contentsOf: url) {
                if let image = UIImage(data: data) {
                    DispatchQueue.main.async {
                        self?.image = image
                    }
                    FOUNDIMAGE = true
                }
            }
        }
        // If link cannot be found, show default image
        if !FOUNDIMAGE {
            self.image = UIImage(named: "default_image")
        }
    }
    
    func getImage(id: String){
        let link_to_image = "http://37.120.179.15:8000/\(id).jpg"
        guard let imageUrl = URL(string: link_to_image) else { return }
        self.loadURL(url: imageUrl)
    }
}

