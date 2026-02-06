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


let flaskURL = "http://37.120.179.15:6006/"
let imageURL = "http://37.120.179.15:8000/"

@available(iOS 13.0, *)
class PinViewController: UITableViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var updatedLabel: UILabel! // this is actually the comment label
    @IBOutlet weak var statusPicker: UISegmentedControl!
    @IBOutlet weak var websiteCell: UITableViewCell!
    @IBOutlet weak var submitButton: UIButton!
    @IBOutlet weak var commentTextField: UITextField!
    @IBOutlet weak var multiButton: UIButton!
    @IBOutlet weak var paywallButton: UIButton!
    @IBOutlet weak var addressLabel: UILabel!
    @IBOutlet weak var machineStatusLabel: UILabel!
    @IBOutlet weak var lastUpdatedLabel: UILabel!
    @IBOutlet weak var coordinateLabel: UILabel!
    @IBOutlet weak var machineStatusButton: UIButton!
    @IBOutlet weak var scrollView: UIScrollView!
    @IBOutlet weak var pageControl: UIPageControl!
    
    var pinData : Artwork!
    let statusChoices = ["unvisited", "visited", "marked", "retired"]
    let statusColors: [UIColor] = [.red, .green, .yellow, .gray]
    let machineStatusColors: [String:UIColor] = ["available": .white, "out-of-order": .gray, "retired": .gray]

    private struct ImageItemViews {
        let container: UIView
        let imageView: UIImageView
        let toggleContainer: UIView?     // nil for idx 0
        let toggleLabel: UILabel?
        let toggleSwitch: UISwitch?
    }

    private var imageItems: [Int: ImageItemViews] = [:]
    private var collectedByIndex: [Int: Bool] = [:]
    private var collectedKey: String {
        "collectedCoins_\(pinData.id)"
    }

    enum StatusChoice : String {
        case unvisited
        case visited
        case marked
        case retired
    }
    
    @IBOutlet weak var textLabel: UILabel!
    @IBOutlet weak var imageView: UIImageView!
    
    var imagePicker = UIImagePickerController()
    
    var imageDict: [Int: UIImage] = [:]
    private var pendingImageIndex: Int?
    
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
        
        // Load user defaults (which coins are collected
        loadCollectedFromDefaults()
        
        overrideUserInterfaceStyle = .light
        
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

        statusPicker.selectedSegmentIndex = statusChoices.firstIndex(of: pinData.status) ?? 0
        statusPicker.addTarget(self, action: #selector(statusChanged(_:)), for: .valueChanged)
        applyStatusPickerStyle()

        paywallButton.isHidden = true
        multiButton.isHidden = true
        if self.pinData.paywall {
            addPaywallButton()
        }
        if self.pinData.multimachine > 1 {
            addMultimachineButton()
        }
        
        // scroll view
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        
        scrollView.contentSize = CGSize(width: scrollView.frame.width * CGFloat(pinData.numCoins + 1), height: scrollView.frame.height)
        
        // load images asynchronously
        for photoInd in Range(0...pinData.numCoins) {
            getImage(photoInd: photoInd)
        }
        
        // pageControl instead of scroll indicator
        pageControl.numberOfPages = pinData.numCoins + 1
        pageControl.currentPage = 0
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .systemGray3
        pageControl.translatesAutoresizingMaskIntoConstraints = false
        pageControl.backgroundColor = UIColor.white // .withAlphaComponent()
        pageControl.layer.cornerRadius = 10
        pageControl.layer.masksToBounds = true
        scrollView.showsHorizontalScrollIndicator = false

    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        scrollView.contentSize = CGSize(
            width: scrollView.frame.width * CGFloat(pinData.numCoins + 1),
            height: scrollView.frame.height
        )

        for idx in imageItems.keys.sorted() {
            layoutImageItem(index: idx)
        }
    }
    
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let page = Int(round(scrollView.contentOffset.x / scrollView.frame.width))
        pageControl.currentPage = page
    }

    private func applyStatusPickerStyle() {
        statusPicker.backgroundColor = .white

        // Unselected text color
        let normalAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.black
        ]
        statusPicker.setTitleTextAttributes(normalAttrs, for: .normal)

        let selectedTextColor: UIColor = (statusPicker.selectedSegmentIndex == 2) ? .black : .white
        let selectedAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: selectedTextColor
        ]
        statusPicker.setTitleTextAttributes(selectedAttrs, for: .selected)

        // Selected segment fill color
        let col = statusColors[statusPicker.selectedSegmentIndex]
        statusPicker.selectedSegmentTintColor = col
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
        showSimpleAlert(title: "Multi-machine!", text: "There are \(self.pinData.multimachine) penny machines in this location. \nPlease add new machines in the correct locations!")
    }
    @objc func statusButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Machine is \(self.pinData.machineStatus)", text: "Machine can be available, out-of-order (temporarily unavailable) or retired (permanently unavailable).\nPress the 'Report Change' button to update the machine status.")
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
                showConfirmationMessage(message: "No external link available. The machine was probably created through this app.", duration: 2.5)
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
                    "mailto:ninawiedemann999@gmail.com?subject=[PennyMe] - Change of machine \(pinData.id)&body=Dear PennyMe developers,\n\n I have noted a change of machine \(pinData.title!) (ID=\(pinData.id)).\n<b>Details:</b>:\n**PLEASE PROVIDE ANY IMPORTANT DETAILS HERE, e.g. STATUS CHANGE, CORRECT ADDRESS, GEOGRAPHIC COORDINATES, etc.\n\n With best regards,"
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
        applyStatusPickerStyle()
    }

    
    @objc func addComment(){
        
        let uploadTimeout: TimeInterval = 10
        let alertController = UIAlertController(
            title: "Attention!",
            message: "Please be mindful. Your comment will be shown to all users of the app. Write as clear & concise as possible.",
            preferredStyle: .alert
        )

        // Create the OK action
        let okAction = UIAlertAction(title: "OK, add comment!", style: .default) { (_) in
            
            var comment = self.commentTextField.text
            if comment?.count ?? 0 > 0 {
                self.commentTextField.text = ""
                self.commentTextField.attributedPlaceholder = NSAttributedString(
                    string: "Your comment will be shown soon!")
                
                let loadingMessage = "Processing comment...\nPlease wait up to \(Int(uploadTimeout)) seconds!"
                self.showLoadingView(withMessage: loadingMessage)
                self.uploadCommentWithTimeout(comment!, timeout:uploadTimeout)


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
    func uploadCommentWithTimeout(_ comment: String, timeout: TimeInterval) {
        
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
            timeoutTimer?.schedule(deadline: .now() + timeout)
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
    
    func presentUploadAlert(highlighting word: String) {
        guard UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum) else { return }

        // Choose central line depending on which word is highlighted
        let centralLine: String
        switch word.lowercased() {
        case "machine":
            centralLine = "Upload an image of the penny MACHINE, not an image of a coin."
        case "coin":
            centralLine = "Upload an image of a pressed COIN (one at a time), not an image of the machine."
        default:
            centralLine = "Upload an image related to the pressed penny machine."
        }

        // Full message
        let message = """
        Your image will be shown to all users of the app! Please be considerate.
        \(centralLine)
        With the upload, you grant the PennyMe team the unrestricted right to process, alter, share, distribute and publicly expose this image.
        """

        let alertController = UIAlertController(title: "Attention!", message: nil, preferredStyle: .alert)

        // Attributed message with the chosen word in bold
        let attributedMessage = NSMutableAttributedString(string: message)

        alertController.setValue(attributedMessage, forKey: "attributedMessage")

        // OK action → open picker
        let okAction = UIAlertAction(title: "OK", style: .default) { _ in
            let imagePicker = UIImagePickerController()
            imagePicker.delegate = self
            imagePicker.sourceType = .photoLibrary
            imagePicker.allowsEditing = false
            self.present(imagePicker, animated: true, completion: nil)
        }

        // Cancel action
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)

        alertController.addAction(okAction)
        alertController.addAction(cancelAction)

        self.present(alertController, animated: true, completion: nil)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.dismiss(animated: true, completion: nil)
    }
    
    func showLoadingView(withMessage message: String) {
        // Create the loading view
        let loadingViewFrame = CGRect(x: 0, y: 0, width: 250, height: 150)
        loadingView = UIView(frame: loadingViewFrame)
        loadingView?.backgroundColor = UIColor(white: 0.2, alpha: 0.8)
        loadingView?.layer.cornerRadius = 10

        // Calculate required height for the label
        let labelWidth: CGFloat = 230
        let maxSize = CGSize(width: labelWidth, height: CGFloat.greatestFiniteMagnitude)
        let messageString = NSString(string: message)
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let attributes = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 17)]
        let labelRect = messageString.boundingRect(with: maxSize, options: options, attributes: attributes, context: nil)
        
        // Create the loading label
        loadingLabel = UILabel(frame: CGRect(x: 10, y: 10, width: labelWidth, height: labelRect.height))
        loadingLabel?.text = message
        loadingLabel?.textColor = .white
        loadingLabel?.textAlignment = .center
        loadingLabel?.numberOfLines = 0
        loadingLabel?.lineBreakMode = .byWordWrapping
        loadingView?.addSubview(loadingLabel!)

        // Adjust the loading view frame based on label size
        let totalHeight = labelRect.height + 70 // Extra space for activity indicator and padding
        loadingView?.frame = CGRect(x: 0, y: 0, width: labelWidth + 20, height: totalHeight)

        // Create and start animating the activity indicator
        activityIndicator = UIActivityIndicatorView(style: .whiteLarge)
        activityIndicator?.center = CGPoint(x: loadingView!.bounds.midX, y: loadingLabel!.frame.maxY + 30)
        activityIndicator?.startAnimating()
        loadingView?.addSubview(activityIndicator!)
        
        // Add the loading view to the table view's superview
        if let superview = self.tableView.superview {
            superview.addSubview(loadingView!)

            // Center the loading view in the superview
            loadingView?.center = superview.center
        }

    }
    
    func hideLoadingView() {
        // Remove or hide the loading view (as in your original code)
        loadingView?.removeFromSuperview()
    }
    

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        
        let uploadTimeout: TimeInterval = 25
        let loadingMessage = "Processing image...\nPlease wait up to \(Int(uploadTimeout)) seconds"
        showLoadingView(withMessage: loadingMessage)
        let image = info[UIImagePickerController.InfoKey.originalImage] as! UIImage
        // Dismiss the image picker
        dismiss(animated: true) {
            // Call a function to upload the image with a timeout
            self.uploadImageWithTimeout(image, timeout: uploadTimeout)
        }
    }
        

    func uploadImageWithTimeout(_ image: UIImage, timeout: TimeInterval) {
        var task: URLSessionDataTask?
        
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("Failed to convert image to data")
            hideLoadingView()
            return
        }
    
        // get index of selected image
        let coinIdx = pendingImageIndex ?? -1
        
        // call flask method to upload the image
        guard let url = URL(string: flaskURL+"/upload_image?id=\(self.pinData.id)&coin_idx=\(coinIdx)") else {
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

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    self.showAlert(title: "Error", message: "Something went wrong. Please try again.")
                }
                return
            }

            let statusCode = httpResponse.statusCode
            if 200 ..< 300 ~= statusCode {
                // If the request is successful, display the success message
                DispatchQueue.main.async {
                    self.handleResponse(type: "image", success: true, error: nil)
                }
            } else {
                var backendError = "Upload failed. Please try again."
                if let responseData = data,
                   let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
                   let errorString = json?["error"] as? String {
                    backendError = errorString
                }
                DispatchQueue.main.async {
                    self.showAlert(title: "Error", message: backendError)
                }
            }
        }
        task?.resume()
        // Set up a timer to handle the upload timeout
        var timeoutTimer: DispatchSourceTimer?
        timeoutTimer = DispatchSource.makeTimerSource()
        timeoutTimer?.schedule(deadline: .now() + timeout)
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
            if let idx = pendingImageIndex {
                destinationViewController.image = imageDict[idx]
            }
        }
        
    }
    
    func getImage(photoInd: Int) {
        let urlString: String = {
            if photoInd > 0 {
                return "\(imageURL)/\(pinData.id)_coin_\(photoInd-1).png"
            } else {
                return "\(imageURL)/\(pinData.id).jpg"
            }
        }()

        guard let url = URL(string: urlString) else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let downloadedImage: UIImage? = {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return UIImage(data: data)
            }()

            DispatchQueue.main.async {
                guard let self else { return }

                let action: Selector
                let finalImage: UIImage
                if let downloadedImage {
                    finalImage = downloadedImage
                    action = #selector(self.enlargeImage(tapGestureRecognizer:))
                    self.imageDict[photoInd] = downloadedImage
                } else {
                    // pick default
                    let isCoin = urlString.contains("coin")
                    finalImage = UIImage(named: isCoin ? "coin_Image" : "machine_image")!
                    action = isCoin ? #selector(self.startNewCoinUpload(tapGestureRecognizer:)) : #selector(self.startNewMachineUpload(tapGestureRecognizer:))
                }

                self.addImageToScrollView(image: finalImage, img_idx: photoInd, action: action)
            }
        }
    }
    
    @objc private func collectedSwitchChanged(_ sender: UISwitch) {
        // handle change of "collected"-toggle
        collectedByIndex[sender.tag] = sender.isOn
        saveCollectedToDefaults()
    }

    private func loadCollectedFromDefaults() {
        let indices = (UserDefaults.standard.array(forKey: collectedKey) as? [Int]) ?? []
        collectedByIndex = Dictionary(uniqueKeysWithValues: indices.map { ($0, true) })
    }

    private func saveCollectedToDefaults() {
        let indices = collectedByIndex
            .filter { $0.value }
            .map { $0.key }
            .sorted()
        UserDefaults.standard.set(indices, forKey: collectedKey)
    }

    func addImageToScrollView(image: UIImage, img_idx: Int, action: Selector) {
        let container = UIView()
        container.tag = img_idx

        let imageView = UIImageView(image: image)
        imageView.tag = img_idx
        imageView.isUserInteractionEnabled = true
        imageView.contentMode = .scaleAspectFit
        imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
        container.addSubview(imageView)

        var toggleContainer: UIView? = nil
        var toggleLabel: UILabel? = nil
        var toggleSwitch: UISwitch? = nil

        // Only coins (idx >= 1) get a toggle row
        if img_idx >= 1 {
            let tContainer = UIView()
            tContainer.isUserInteractionEnabled = true

            let label = UILabel()
            label.text = "Collected"
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabel

            let sw = UISwitch()
            sw.tag = img_idx
            sw.isOn = collectedByIndex[img_idx] ?? false
            sw.addTarget(self, action: #selector(collectedSwitchChanged(_:)), for: .valueChanged)

            tContainer.addSubview(label)
            tContainer.addSubview(sw)

            container.addSubview(tContainer)

            toggleContainer = tContainer
            toggleLabel = label
            toggleSwitch = sw
        }

        scrollView.addSubview(container)

        imageItems[img_idx] = ImageItemViews(
            container: container,
            imageView: imageView,
            toggleContainer: toggleContainer,
            toggleLabel: toggleLabel,
            toggleSwitch: toggleSwitch
        )

        layoutImageItem(index: img_idx)
    }

    
    private func layoutImageItem(index: Int) {
        guard let item = imageItems[index] else { return }

        let pageWidth = scrollView.frame.width
        let pageHeight = scrollView.frame.height
        let xPosition = pageWidth * CGFloat(index)

        item.container.frame = CGRect(x: xPosition, y: 0, width: pageWidth, height: pageHeight)

        let toggleHeight: CGFloat = (item.toggleContainer == nil) ? 0 : 44
        let spacing: CGFloat = (toggleHeight == 0) ? 0 : 8

        // Image uses remaining height above the toggle
        item.imageView.frame = CGRect(
            x: 0,
            y: 0,
            width: pageWidth,
            height: pageHeight - toggleHeight - spacing
        )

        // Center label + switch under image
        if let tContainer = item.toggleContainer,
           let label = item.toggleLabel,
           let sw = item.toggleSwitch {

            label.sizeToFit()
            let swSize = sw.intrinsicContentSize
            let h = max(label.bounds.height, swSize.height)
            let innerSpacing: CGFloat = 10

            let totalWidth = label.bounds.width + innerSpacing + swSize.width
            let x = (pageWidth - totalWidth) * 0.5
            let y = pageHeight - toggleHeight + (toggleHeight - h) * 0.5

            tContainer.frame = CGRect(x: x, y: y, width: totalWidth, height: h)
            label.frame = CGRect(x: 0, y: (h - label.bounds.height) * 0.5, width: label.bounds.width, height: label.bounds.height)
            sw.frame = CGRect(x: label.bounds.width + innerSpacing, y: (h - swSize.height) * 0.5, width: swSize.width, height: swSize.height)
        }
    }
    
    @objc func enlargeImage(tapGestureRecognizer: UITapGestureRecognizer)
    {
        guard let tappedView = tapGestureRecognizer.view else { return }
        pendingImageIndex = tappedView.tag
        self.performSegue(withIdentifier: "bigImage", sender: self)
    }
    
    @objc func startNewCoinUpload(tapGestureRecognizer: UITapGestureRecognizer) {
        // get index of tapped image
        guard let tappedView = tapGestureRecognizer.view else { return }
        pendingImageIndex = tappedView.tag - 1
        presentUploadAlert(highlighting: "coin")
    }
    
    @objc func startNewMachineUpload(tapGestureRecognizer: UITapGestureRecognizer) {
        // get index of tapped image
        guard let tappedView = tapGestureRecognizer.view else { return }
        pendingImageIndex = tappedView.tag - 1
        presentUploadAlert(highlighting: "machine")
    }
}
