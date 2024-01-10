//
//  PinViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 09.04.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit
import MapKit
import SwiftUI

var FOUNDIMAGE : Bool = false

let flaskURL = "http://37.120.179.15:6006/"
let imageURL = "http://37.120.179.15:8000/"

@available(iOS 13.0, *)
class PinViewController: UITableViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var updatedLabel: UILabel! // this is actually the comment label
    @IBOutlet weak var statusPicker: UISegmentedControl!
    @IBOutlet weak var websiteCell: UITableViewCell!
    @IBOutlet weak var imageview: UIImageView!
    @IBOutlet weak var submitButton: UIButton!
    @IBOutlet weak var commentTextField: UITextField!
    @IBOutlet weak var multiButton: UIButton!
    @IBOutlet weak var paywallButton: UIButton!
    @IBOutlet weak var addressLabel: UILabel!
    @IBOutlet weak var machineStatusLabel: UILabel!
    @IBOutlet weak var lastUpdatedLabel: UILabel!
    @IBOutlet weak var coordinateLabel: UILabel!
    @IBOutlet weak var machineStatusButton: UIButton!
    
    var pinData : Artwork!
    let statusChoices = ["unvisited", "visited", "marked", "retired"]
    let statusColors: [UIColor] = [.red, .green, .yellow, .gray]
    let machineStatusColors: [String:UIColor] = ["available": .white, "out-of-order": .gray, "retired": .gray]
    
    enum StatusChoice : String {
        case unvisited
        case visited
        case marked
        case retired
    }
    
    @IBOutlet weak var textLabel: UILabel!
    @IBOutlet weak var imageView: UIImageView!
    
    var imagePicker = UIImagePickerController()
    
    var artwork: Artwork? {
      didSet {
        configureView()
      }
    }
    
    // Vars for the image/comment upload
    private var activityIndicator: UIActivityIndicatorView?
    private var loadingView: UIView?
    private var loadingLabel: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
        
        imagePicker.delegate = self
        imagePicker.allowsEditing = false
        imagePicker.sourceType = .photoLibrary
        
        updatedLabel.numberOfLines = 0
        updatedLabel.contentMode = .scaleToFill

        loadComments(completionBlock:
        {
            (output) in
            DispatchQueue.main.async {
                self.updatedLabel.text = output
                self.tableView.reloadData()
            }
        })
        // textfield
        commentTextField.attributedPlaceholder = NSAttributedString(
            string: "Type your comment here")
            
        // submit button
        submitButton.addTarget(self, action: #selector(addComment), for: .touchUpInside
                               )
        // main command to ensure that the subviews are sorted
        statusPicker.layoutSubviews()
        
        // Add title, address and updated
        titleLabel.numberOfLines = 3
        titleLabel.textAlignment = NSTextAlignment.center
        titleLabel.text = self.pinData.title!
        addressLabel.numberOfLines = 3
        addressLabel.text = "Address: \(self.pinData.address)"
        lastUpdatedLabel.text = "Last updated: \(self.pinData.last_updated)"
        
        // get machine status
        machineStatusButton.setTitle("Machine \(self.pinData.machineStatus)", for: .normal)
        if #available(iOS 15.0, *) {
            machineStatusButton.configuration?.baseBackgroundColor = (machineStatusColors[self.pinData.machineStatus] ?? .white).withAlphaComponent(0.15)
            machineStatusButton.configuration?.baseForegroundColor = .black
        }
        else {
            machineStatusButton.backgroundColor = machineStatusColors[self.pinData.machineStatus] ?? .white
            machineStatusButton.setTitleColor(.black, for: .normal)
            machineStatusButton.alpha = 0.15
        }
        machineStatusButton.addTarget(self, action: #selector(statusButtonTapped), for: .touchUpInside)
        
        coordinateLabel.text = String(format : "Coordinates: %f, %f", self.pinData.coordinate.latitude, self.pinData.coordinate.longitude
        )
                
        // user status - set segment according to user default
        statusPicker.selectedSegmentIndex = statusChoices.firstIndex(of: pinData.status) ?? 0
        
        statusPicker.addTarget(self, action: #selector(PinViewController.statusChanged(_:)), for: .valueChanged)
        
        // get color of currently selected index
        let colForSegment: UIColor = statusColors[statusPicker.selectedSegmentIndex]
        // color selected segmented
        if #available(iOS 13.0, *) {
            statusPicker.selectedSegmentTintColor = colForSegment
        }
        else{
            statusPicker.tintColor = colForSegment
        }
        // color all the other segments with alpha=0.2
        for (num, col) in zip([0, 1, 2], statusColors){
            let subView = statusPicker.subviews[num] as UIView
            subView.layer.backgroundColor = col.cgColor
            subView.layer.zPosition = -1
            subView.alpha = 0.2
        }

        // load image asynchronously
        self.imageview.getImage(id: self.pinData.id)
        // initialize tap gesture to enlarge image
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(imageTapped(tapGestureRecognizer:)));
        self.imageview.isUserInteractionEnabled = true
        self.imageview.addGestureRecognizer(tapGestureRecognizer)
        
        paywallButton.isHidden = true
        multiButton.isHidden = true
        if self.pinData.paywall {
            addPaywallButton()
        }
        if self.pinData.multimachine > 1 {
            addMultimachineButton()
        }
    }
    
    func addPaywallButton() {
        paywallButton.isHidden = false
        paywallButton.addTarget(self, action: #selector(paywallButtonTapped), for: .touchUpInside)
        let paywallImage = UIImage(systemName: "dollarsign.circle")?.withTintColor(.black, renderingMode: .alwaysOriginal)
        paywallButton.setImage(paywallImage, for: .normal)
        // Scale the button's image
        let scale: CGFloat = 1.5
        paywallButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        let buttonFrame = paywallButton.frame
    }

    func addMultimachineButton() {
        multiButton.isHidden = false
        let multiImage = UIImage(systemName: "\(self.pinData.multimachine).circle")?.withTintColor(.black, renderingMode: .alwaysOriginal)
        multiButton.setImage(multiImage, for: .normal)
        let scale: CGFloat = 1.5
        multiButton.transform = CGAffineTransform(scaleX: scale, y: scale)
        multiButton.addTarget(self, action: #selector(multimachineButtonTapped), for: .touchUpInside)
    }
    
    @objc func paywallButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Paywall!", text: "You probably have to pay a fee to see this penny machine. \nPress the 'Report Change' button to update this information.")
    }
    @objc func multimachineButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Multi-machine!", text: "There are \(self.pinData.multimachine) penny machines in this location. \nPress the 'Report Change' button to update the number of machines.")
    }
    @objc func statusButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Machine status", text: "Machine can be available, out-of-order (temporarily unavailable) or retired (permanently unavailable).\nPress the 'Report Change' button to update the machine status.")
    }
    func showSimpleAlert(title: String, text: String) {
        let alertController = UIAlertController(
                title: title,
                message: text,
                preferredStyle: .alert
            )
            let okayAction = UIAlertAction(title: "Okay", style: .default, handler: nil)
            alertController.addAction(okayAction)

            present(alertController, animated: true, completion: nil)
    }
    
    func loadComments(completionBlock: @escaping (String) -> Void) -> Void {
        let urlEncodedStringRequest = imageURL + "comments/\(self.pinData.id).json"
        
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        
            if let url = URL(string: urlEncodedStringRequest){
                let session = URLSession(configuration: config)
                let task = session.dataTask(with: url) {[weak self](data, response, error) in
                    guard let data = data else { return }
                    let results = try? JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions.allowFragments)
                    if let results_ = results as? Dictionary<String, String> {
                        let sortedDates = results_.keys.sorted {$0 > $1}
                        var displayString : String = ""
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyy-MM-dd"
                        var isFirst = true
                        for date in sortedDates {
                            if let value = results_[date]{
                                let dateStringArr = date.split(separator: " ")
                                let dateString = dateStringArr.first ?? ""
                                if isFirst==false {
                                    displayString += "\n"
                                }
                                else{
                                    isFirst = false
                                }
                                displayString += "\(dateString): \(value)"
                            }
                        }
                        completionBlock(displayString ?? "No comments yet")
                    }
                }
                task.resume()
            }
        }
    
    @objc func imageTapped(tapGestureRecognizer: UITapGestureRecognizer)
    {
        if FOUNDIMAGE{
            self.performSegue(withIdentifier: "bigImage", sender: self)
        }
        else{
            chooseImage()
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
        if (indexPath.section == 3) && (indexPath.row == 0) {
            let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
            self.pinData.mapItem().openInMaps(launchOptions: launchOptions)
        }
        else if indexPath.section == 5{
            //Open the website when you click on the link.
            if !pinData.link.contains("http") {
                showConfirmationMessage(message: "Sorry! No external link available. The machine got created through this app.", duration: 2.5)
            } else {
                UIApplication.shared.open(URL(string: pinData.link)!)
            }
        }
        else if indexPath.section == 6{
            if #available(iOS 14.0, *) {
                let swiftUIViewController = UIHostingController(rootView: MachineChangedForm(pinData: pinData
                    )
                )
                present(swiftUIViewController, animated: true)
                
            }
            else {
                let mailtostring = String(
                    "mailto:wnina@ethz.ch?subject=[PennyMe] - Change of machine \(pinData.id)&body=Dear PennyMe developers,\n\n I have noted a change of machine \(pinData.title!) (ID=\(pinData.id)).\n<b>Details:</b>:\n**PLEASE PROVIDE ANY IMPORTANT DETAILS HERE, e.g. STATUS CHANGE, CORRECT ADDRESS, GEOGRAPHIC COORDINATES, etc.\n\n With best regards,"
                ).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "error"
                UIApplication.shared.open(URL(string:mailtostring )!)
            }
        }
        else if (indexPath.section ==  3) && (indexPath.row == 1) {
            // Copy coordinate section

            UIPasteboard.general.string = String(format : "%f, %f", self.pinData.coordinate.latitude, self.pinData.coordinate.longitude
            )
            showConfirmationMessage(message: "Copied!", duration: 1.5)
        }
    }

    
    func showConfirmationMessage(message: String, duration: Double) {
        let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alertController.view.alpha = 0.7
        alertController.view.layer.cornerRadius = 15
        
        present(alertController, animated: true, completion: nil)
        
        // Automatically dismiss the message after the specified duration
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            alertController.dismiss(animated: true, completion: nil)
        }
    }

    @objc func statusChanged(_ sender: UISegmentedControl) {
        let status = statusChoices[sender.selectedSegmentIndex]
        
        saveStatusChange(machineid: self.pinData.id, new_status: status)
        
        // change color for selected segment
        let colForSegment = statusColors[sender.selectedSegmentIndex]
        if #available(iOS 13.0, *) {
            statusPicker.selectedSegmentTintColor = colForSegment
        }
        else{
            statusPicker.tintColor = colForSegment
        }
    }
    
    @objc func addComment(){
        
        // Create the alert controller
        let alertController = UIAlertController(title: "Attention!", message: "Please be mindful. Your comment will be shown to all users of the app. Write as clear & concise as possible.", preferredStyle: .alert)

        // Create the OK action
        let okAction = UIAlertAction(title: "OK, add comment!", style: .default) { (_) in
            
            var comment = self.commentTextField.text
            if comment?.count ?? 0 > 0 {
                self.commentTextField.text = ""
                self.commentTextField.attributedPlaceholder = NSAttributedString(
                    string: "Your comment will be shown soon!")
                
                self.showLoadingView(withMessage: "Processing the comment...")
                self.uploadCommentWithTimeout(comment!)


            }
        }

        // Create the cancel action
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { (_) in
        }

        // Add the actions to the alert controller
        alertController.addAction(okAction)
        alertController.addAction(cancelAction)

        // Present the alert controller
        self.present(alertController, animated: true, completion: nil)
        

    }
    func uploadCommentWithTimeout(_ comment: String) {
        
        let uploadTimeout: TimeInterval = 10
        var task: URLSessionDataTask?
        
        // submit request to backend
        let requestString = "/add_comment?comment=\(comment)&id=\(self.pinData.id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        let urlEncodedStringRequest = flaskURL + requestString!
        if let url = URL(string: urlEncodedStringRequest){
            let task = URLSession.shared.dataTask(with: url) {[weak self](data, response, error) in
            // Create a URLSessionDataTask to send the request
                guard let self = self else { return }
                
                // Hide the loading view first
                DispatchQueue.main.async {
                    self.hideLoadingView()
                }
                
                // Cancel the task if it's still running
                task?.cancel()
                
                if let error = error {
                    print("Error: \(error)")
                    DispatchQueue.main.async {
                        self.handleResponse(type: "comment", success: false, error: error)
                    }
                    return
                }
                
                // If the request is successful, display the success message
                DispatchQueue.main.async {
                    self.handleResponse(type: "comment", success: true, error: nil)
                }
            }
            task.resume()
            // Set up a timer to handle the upload timeout
            var timeoutTimer: DispatchSourceTimer?
            timeoutTimer = DispatchSource.makeTimerSource()
            timeoutTimer?.schedule(deadline: .now() + uploadTimeout)
            timeoutTimer?.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.hideLoadingView() // Hide the loading view in case of timeout
                    // Display a failure message or take appropriate action
                    print("Upload timed out")
                    // You can also show an alert to the user here
                    
                    // Cancel the task if it's still running
                    task.cancel()
                }
                // Cancel the timer
                timeoutTimer?.cancel()
            }
            timeoutTimer?.resume()
        } else {
        print("Invalid URL")
        hideLoadingView()
        }
    }
    
    func chooseImage() {
        if UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum){
            // Create the alert controller
            let alertController = UIAlertController(title: "Attention!", message: "Your image will be shown to all users of the app! Please be considerate. Upload an image of the penny machine, not just an image of a coin. With the upload, you grant the PennyMe team the unrestricted right to process, alter, share, distribute and publicly expose this image.", preferredStyle: .alert)

            // Create the OK action
            let okAction = UIAlertAction(title: "OK", style: .default) { (_) in
                // Show the image picker
                let imagePicker = UIImagePickerController()
                imagePicker.delegate = self
                imagePicker.sourceType = .photoLibrary
                imagePicker.allowsEditing = false
                self.present(imagePicker, animated: true, completion: nil)
            }

            // Create the cancel action
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { (_) in
            }

            // Add the actions to the alert controller
            alertController.addAction(okAction)
            alertController.addAction(cancelAction)

            // Present the alert controller
            self.present(alertController, animated: true, completion: nil)
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.dismiss(animated: true, completion: nil)
    }
    
    func showLoadingView(withMessage message: String) {
        // Create the loading view
        loadingView = UIView(frame: CGRect(x: 0, y: 0, width: 250, height: 150))
        loadingView?.center = view.center
        loadingView?.backgroundColor = UIColor(white: 0.2, alpha: 0.8)
        loadingView?.layer.cornerRadius = 10
        // Create the loading label
        loadingLabel = UILabel(frame: CGRect(x: 0, y: 0, width: 250, height: 40))
        loadingLabel?.center = CGPoint(x: loadingView!.bounds.midX, y: loadingView!.bounds.midY - 30)
        loadingLabel?.text = message
        loadingLabel?.textColor = .white
        loadingLabel?.textAlignment = .center
        loadingLabel?.numberOfLines = 0
        loadingView?.addSubview(loadingLabel!)
        // Create and start animating the activity indicator
        activityIndicator = UIActivityIndicatorView(style: .whiteLarge)
        activityIndicator?.center = CGPoint(x: loadingView!.bounds.midX, y: loadingView!.bounds.midY + 20)
        activityIndicator?.startAnimating()
        loadingView?.addSubview(activityIndicator!)
        view.addSubview(loadingView!)
    }
    
    func hideLoadingView() {
        // Remove or hide the loading view (as in your original code)
        loadingView?.removeFromSuperview()
    }
    

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        
        showLoadingView(withMessage: "Processing the image...")
        let image = info[UIImagePickerController.InfoKey.originalImage] as! UIImage
        // Dismiss the image picker
        dismiss(animated: true) {
            // Call a function to upload the image with a timeout
            self.uploadImageWithTimeout(image)
        }
    }
        

    func uploadImageWithTimeout(_ image: UIImage) {
        let uploadTimeout: TimeInterval = 10
        var task: URLSessionDataTask?
        
        guard let imageData = image.jpegData(compressionQuality: 1.0) else {
            print("Failed to convert image to data")
            hideLoadingView()
            return
        }
    

        // call flask method to upload the image
        guard let url = URL(string: flaskURL+"/upload_image?id=\(self.pinData.id)") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add the image data to the request body
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let body = NSMutableData()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body as Data
        
        // Create a URLSessionDataTask to send the request
        task = URLSession.shared.dataTask(with: request) { [weak self] (data, response, error) in
            guard let self = self else { return }
            // Hide the loading view first
            DispatchQueue.main.async {
                self.hideLoadingView()
            }
            // Cancel the task if it's still running
            task?.cancel()

            if let error = error {
                print("Error: \(error)")
                DispatchQueue.main.async {
                    self.handleResponse(type: "image", success: false, error: error)
                }
                return
            }
            // If the request is successful, display the success message
            DispatchQueue.main.async {
                self.handleResponse(type: "image", success: true, error: nil)
            }
        }
        task?.resume()
        // Set up a timer to handle the upload timeout
        var timeoutTimer: DispatchSourceTimer?
        timeoutTimer = DispatchSource.makeTimerSource()
        timeoutTimer?.schedule(deadline: .now() + uploadTimeout)
        timeoutTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.hideLoadingView() // Hide the loading view in case of timeout
                // Display a failure message or take appropriate action
                print("Upload timed out")
                // Cancel the task if it's still running
                task?.cancel()
            }
            // Cancel the timer
            timeoutTimer?.cancel()
        }
        timeoutTimer?.resume()
    }
    
    private func handleResponse(type: String, success: Bool, error: Error?) {
        activityIndicator?.stopAnimating()
        loadingView?.removeFromSuperview()
        if success {
            showAlert(title: "Success", message: "Upload successful! Please reopen the machine view to see your \(type).")
        } else {
            var errorMessage = "An error occurred"
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    errorMessage = "Request timed out. Please check your internet connection and try again."
                case .notConnectedToInternet:
                    errorMessage = "No internet connection. Please connect to the internet and try again."
                case .cancelled:
                    errorMessage = "Request timed out. Please check your internet connection and try again."
                default:
                    errorMessage = "Network error: \(urlError.localizedDescription)"
                }
            } else {
                errorMessage = "Unknown error: \(error?.localizedDescription ?? "No additional details")"
            }
            showAlert(title: "Error", message: errorMessage)
        }
    }
    private func showAlert(title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
        alertController.addAction(okAction)
        present(alertController, animated: true, completion: nil)
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
                // remove file
                try fileManager.removeItem(atPath: jsonFilePath!.absoluteString)
            }
            catch{
                print("file already exists but could not be read", error)
            }
        }

        // update value
        currentStatusDict[0][machineid] = new_status
        
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

