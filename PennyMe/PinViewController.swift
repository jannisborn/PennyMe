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


let flaskURL = "https://pennyme-backend.duckdns.org/"
let imageURL = "https://pennyme.duckdns.org/"

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

    private let titleIndexPath = IndexPath(row: 0, section: 0)
    private let addressIndexPath = IndexPath(row: 0, section: 3)
    private let coordinateIndexPath = IndexPath(row: 1, section: 3)
    private let lastUpdatedIndexPath = IndexPath(row: 2, section: 3)
    private struct ConsumedLongPress {
        let indexPath: IndexPath
        let time: CFTimeInterval
    }
    private var consumedLongPress: ConsumedLongPress?
    private let copyFeedback = UINotificationFeedbackGenerator()
    private let blockedContributors = BlockedContributorsStore()
    private var contentOwners: [String: String] = [:]
    private var hasLoadedModerationManifest = false
    private var needsBlockedContentRefresh = false

    private enum ModerationTarget {
        case visibleImage(Int)
        case comments
        case listing

        var kind: String {
            switch self {
            case .visibleImage: return "image"
            case .comments: return "comment"
            case .listing: return "machine"
            }
        }

        var identifier: String {
            switch self {
            case .visibleImage(let page):
                return page == 0 ? "machine" : "coin_\(page - 1)"
            case .comments:
                return "all"
            case .listing:
                return "listing"
            }
        }

        var contentKey: String {
            return "\(kind):\(identifier)"
        }
    }

    private enum ReportReason: String, CaseIterable {
        case spamScam = "Spam / Scam"
        case harassment = "Harassment"
        case sexualContent = "Sexual content"
        case hate = "Hate speech"
        case violence = "Violence or threats"
        case other = "Other objectionable content"

        var apiValue: String {
            switch self {
            case .spamScam: return "spam_scam"
            case .harassment: return "harassment"
            case .sexualContent: return "sexual_content"
            case .hate: return "hate"
            case .violence: return "violence"
            case .other: return "other"
            }
        }
    }

    private func localContentKey(_ serverContentKey: String) -> String {
        return "\(pinData.id):\(serverContentKey)"
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

        let reportButton = UIBarButtonItem(
            image: reportFlagIcon(),
            style: .plain,
            target: self,
            action: #selector(showContentSafetyActions)
        )
        reportButton.tintColor = .red
        reportButton.accessibilityLabel = "Report content"
        reportButton.accessibilityIdentifier = "reportContentButton"
        navigationItem.rightBarButtonItem = reportButton
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(blockedContentDidChange),
            name: .blockedContentDidChange,
            object: nil
        )
        
        // Load user defaults (which coins are collected
        loadCollectedFromDefaults()
        
        overrideUserInterfaceStyle = .light
        
        imagePicker.delegate = self
        imagePicker.allowsEditing = false
        imagePicker.sourceType = .photoLibrary
        
        updatedLabel.numberOfLines = 0
        updatedLabel.contentMode = .scaleToFill

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

        copyFeedback.prepare()

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressToCopy(_:)))
        longPress.minimumPressDuration = 0.5
        tableView.addGestureRecognizer(longPress)
        
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

        loadModerationManifestAndContent()

    }

    private func reportFlagIcon() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 29, height: 29))
        let image = renderer.image { _ in
            UIColor.black.setFill()

            // A heavier pole stays legible at navigation-bar size.
            let pole = UIBezierPath(
                roundedRect: CGRect(x: 4, y: 2, width: 4, height: 25),
                cornerRadius: 2
            )
            pole.fill()

            let flag = UIBezierPath()
            flag.move(to: CGPoint(x: 7.5, y: 4.5))
            flag.addCurve(
                to: CGPoint(x: 25, y: 6),
                controlPoint1: CGPoint(x: 13, y: 3),
                controlPoint2: CGPoint(x: 20, y: 7.2)
            )
            flag.addLine(to: CGPoint(x: 22, y: 10.8))
            flag.addLine(to: CGPoint(x: 25, y: 16))
            flag.addCurve(
                to: CGPoint(x: 7.5, y: 14.5),
                controlPoint1: CGPoint(x: 19.5, y: 17.5),
                controlPoint2: CGPoint(x: 13, y: 13)
            )
            flag.close()
            flag.fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func blockedContentDidChange() {
        guard isDisplayingMachine else {
            needsBlockedContentRefresh = true
            return
        }
        loadCommunityContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard needsBlockedContentRefresh, hasLoadedModerationManifest else { return }
        needsBlockedContentRefresh = false
        loadCommunityContent()
    }

    private var isDisplayingMachine: Bool {
        guard isViewLoaded, view.window != nil else { return false }
        guard let navigationController = navigationController else { return true }
        return navigationController.visibleViewController === self
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

    private func loadModerationManifestAndContent() {
        guard let url = URL(string: flaskURL + "moderation/manifest/\(pinData.id)") else {
            hasLoadedModerationManifest = true
            if isDisplayingMachine {
                loadCommunityContent()
            } else {
                needsBlockedContentRefresh = true
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.addAnonymousUserHeader()
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            let owners: [String: String]
            if let data,
               let json = try? JSONSerialization.jsonObject(
                   with: data,
                   options: []
               ) as? [String: Any],
               let responseOwners = json?["owners"] as? [String: String] {
                owners = responseOwners
            } else {
                owners = [:]
            }
            DispatchQueue.main.async {
                self.contentOwners = owners
                self.hasLoadedModerationManifest = true
                if self.isDisplayingMachine {
                    self.needsBlockedContentRefresh = false
                    self.loadCommunityContent()
                } else {
                    self.needsBlockedContentRefresh = true
                }
            }
        }
        task.resume()
    }

    private func loadCommunityContent() {
        loadComments { [weak self] output in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updatedLabel.text = output
                self.tableView.reloadData()
            }
        }
        for photoIndex in 0...pinData.numCoins {
            getImage(photoInd: photoIndex)
        }
    }

    @objc private func showContentSafetyActions() {
        let page = max(0, min(pageControl.currentPage, pinData.numCoins))
        let imageTarget = ModerationTarget.visibleImage(page)
        let sheet = UIAlertController(
            title: "Content Safety",
            message: "Report objectionable content or block the contributor of an image.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Report Visible Image", style: .default) { _ in
            self.chooseReportReason(for: imageTarget, blockContributor: false)
        })
        sheet.addAction(UIAlertAction(title: "Report Public Comments", style: .default) { _ in
            self.chooseReportReason(for: .comments, blockContributor: false)
        })
        sheet.addAction(UIAlertAction(title: "Report Machine Listing", style: .default) { _ in
            self.chooseReportReason(for: .listing, blockContributor: false)
        })
        sheet.addAction(UIAlertAction(title: "Block Contributor", style: .destructive) { _ in
            self.chooseImageContributorToBlock()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(sheet, animated: true)
    }

    private func chooseImageContributorToBlock() {
        let imageIndices = imageDict.keys.sorted()
        guard !imageIndices.isEmpty else {
            showAlert(
                title: "No Image Available",
                message: "A contributed image must finish loading before its contributor can be blocked."
            )
            return
        }

        let sheet = UIAlertController(
            title: "Select an Image",
            message: "Choose the submitted image whose contributor you want to block.",
            preferredStyle: .actionSheet
        )
        for index in imageIndices {
            let title = index == 0 ? "Machine image" : "Coin image \(index)"
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                self.chooseReportReason(
                    for: ModerationTarget.visibleImage(index),
                    blockContributor: true
                )
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(sheet, animated: true)
    }

    private func chooseReportReason(for target: ModerationTarget, blockContributor: Bool) {
        let sheet = UIAlertController(
            title: blockContributor ? "Why are you blocking this contributor?" : "Why are you reporting this content?",
            message: "Reports are reviewed within several working days.",
            preferredStyle: .actionSheet
        )
        for reason in ReportReason.allCases {
            sheet.addAction(UIAlertAction(title: reason.rawValue, style: .default) { _ in
                if blockContributor {
                    self.confirmBlock(target: target, reason: reason)
                } else {
                    self.submitModerationReport(target: target, reason: reason, blockContributor: false)
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(sheet, animated: true)
    }

    private func confirmBlock(target: ModerationTarget, reason: ReportReason) {
        let alert = UIAlertController(
            title: "Block Contributor?",
            message: "All attributed machine listings, images, and comments from this contributor will be hidden throughout PennyMe on this device. While content is not deleted, useful information may appear missing to you! You can reverse this in Settings → Blocked content. PennyMe will also receive a report for review within several working days.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Block & Report", style: .destructive) { _ in
            self.submitModerationReport(target: target, reason: reason, blockContributor: true)
        })
        present(alert, animated: true)
    }

    private func submitModerationReport(
        target: ModerationTarget,
        reason: ReportReason,
        blockContributor: Bool
    ) {
        if blockContributor {
            blockedContributors.block(
                contributorID: contentOwners[target.contentKey],
                contentKey: localContentKey(target.contentKey)
            )
            applyBlockedContent()
        }

        guard let url = URL(string: flaskURL + "report_content") else { return }
        let payload: [String: Any] = [
            "machine_id": pinData.id,
            "target_kind": target.kind,
            "target_id": target.identifier,
            "reason": reason.apiValue,
            "block_contributor": blockContributor
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addAnonymousUserHeader()
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, 200..<300 ~= statusCode else {
                DispatchQueue.main.async {
                    let message = self.reportDeliveryFailureMessage(
                        statusCode: statusCode,
                        data: data,
                        error: error,
                        contentWasBlocked: blockContributor
                    )
                    self.showAlert(title: "Report Not Sent", message: message)
                }
                return
            }

            if blockContributor,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let contributorID = json?["contributor_id"] as? String {
                self.contentOwners[target.contentKey] = contributorID
                self.blockedContributors.block(
                    contributorID: contributorID,
                    contentKey: self.localContentKey(target.contentKey)
                )
            }

            DispatchQueue.main.async {
                if blockContributor {
                    self.showAlert(
                        title: "Contributor Blocked",
                        message: "Their content is hidden and the report was sent to PennyMe."
                    )
                } else {
                    self.showAlert(
                        title: "Report Sent",
                        message: "Thank you. PennyMe will review this report within several working days."
                    )
                }
            }
        }
        task.resume()
    }

    private func reportDeliveryFailureMessage(
        statusCode: Int,
        data: Data?,
        error: Error?,
        contentWasBlocked: Bool
    ) -> String {
        let prefix = contentWasBlocked
            ? "The content is hidden on this device, but the report was not delivered. "
            : "The report was not delivered. "

        if statusCode == 404 {
            return prefix + "PennyMe's reporting service is currently unavailable (HTTP 404). Please try again later."
        }
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
           let backendMessage = json?["error"] as? String {
            return prefix + backendMessage
        }
        if statusCode > 0 {
            return prefix + "The server returned HTTP \(statusCode). Please try again later."
        }
        if let error = error {
            return prefix + error.localizedDescription
        }
        return prefix + "Please try again later."
    }

    private func applyBlockedContent() {
        let blockedContent = blockedContributors.snapshot()
        for index in imageItems.keys {
            let key = ModerationTarget.visibleImage(index).contentKey
            guard blockedContent.isBlocked(
                contributorID: contentOwners[key],
                contentKey: localContentKey(key)
            ) else { continue }

            showBlockedImagePlaceholder(at: index)
        }

        loadComments { [weak self] output in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updatedLabel.text = output
                self.tableView.reloadData()
            }
        }
    }
    
    func loadComments(completionBlock: @escaping (String) -> Void) -> Void {
        let urlEncodedStringRequest = imageURL + "comments/\(self.pinData.id).json"
        let blockedContent = blockedContributors.snapshot()
        let owners = contentOwners
        let machineID = pinData.id
        
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        
            if let url = URL(string: urlEncodedStringRequest){
                let session = URLSession(configuration: config)
                let task = session.dataTask(with: url) {[weak self](data, response, error) in
                    guard let self = self else { return }
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
                                let key = "comment:\(date)"
                                if blockedContent.isBlocked(
                                    contributorID: owners[key],
                                    contentKey: "\(machineID):\(key)"
                                ) {
                                    continue
                                }
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
                        if displayString.isEmpty {
                            displayString = results_.isEmpty
                                ? "No comments yet"
                                : "Comments from blocked contributors are hidden."
                        }
                        completionBlock(displayString)
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
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        if let consumed = consumedLongPress,
           consumed.indexPath == indexPath,
           (CFAbsoluteTimeGetCurrent() - consumed.time) < 1.0 {
            // A long-press already handled this cell (avoid double actions).
            consumedLongPress = nil
            return
        }

        if indexPath == titleIndexPath {
            // Copy title on any tap
            let title = (self.pinData.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            copyToPasteboard(title)
        }
        else if indexPath == addressIndexPath {
            // Tap address opens Maps; copy is via long-press.
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
        else if indexPath == coordinateIndexPath {
            // Copy coordinates on any tap
            let coords = String(
                format : "%f, %f",
                self.pinData.coordinate.latitude,
                self.pinData.coordinate.longitude
            )
            copyToPasteboard(coords)
        }
    }

    @objc private func handleLongPressToCopy(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }

        let location = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: location) else { return }

        if indexPath == addressIndexPath {
            let address = self.pinData.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { return }
            copyToPasteboard(address)
            consumeLongPress(at: indexPath)
        } else if indexPath == lastUpdatedIndexPath {
            let lastUpdated = self.pinData.last_updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lastUpdated.isEmpty else { return }
            copyToPasteboard(lastUpdated)
            consumeLongPress(at: indexPath)
        } else if indexPath == coordinateIndexPath {
            // Coordinates are copyable on any press (tap or long-press).
            let coords = String(
                format : "%f, %f",
                self.pinData.coordinate.latitude,
                self.pinData.coordinate.longitude
            )
            copyToPasteboard(coords)
            consumeLongPress(at: indexPath)
        }
    }

    private func copyToPasteboard(_ string: String) {
        UIPasteboard.general.string = string
        copyFeedback.notificationOccurred(.success)
        copyFeedback.prepare()
        showConfirmationMessage(message: "Copied!", duration: 1.5)
    }

    private func consumeLongPress(at indexPath: IndexPath) {
        let now = CFAbsoluteTimeGetCurrent()
        consumedLongPress = ConsumedLongPress(indexPath: indexPath, time: now)

        // Clear automatically in case the table view doesn't emit a selection callback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard let consumed = self.consumedLongPress else { return }
            if consumed.indexPath == indexPath && (CFAbsoluteTimeGetCurrent() - consumed.time) >= 1.0 {
                self.consumedLongPress = nil
            }
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
        let comment = (commentTextField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return }
        if let reason = TextModeration.blockReason(comment) {
            showAlert(title: "Comment Not Submitted", message: reason)
            return
        }

        let uploadTimeout: TimeInterval = 10
        let alertController = UIAlertController(
            title: "Attention!",
            message: "Please be mindful. Your comment will be shown to all users of the app. Write as clear & concise as possible.",
            preferredStyle: .alert
        )

        // Create the OK action
        let okAction = UIAlertAction(title: "OK, add comment!", style: .default) { (_) in
            self.commentTextField.text = ""
            self.commentTextField.attributedPlaceholder = NSAttributedString(
                string: "Your comment will be shown soon!")

            let loadingMessage = "Processing comment...\nPlease wait up to \(Int(uploadTimeout)) seconds!"
            self.showLoadingView(withMessage: loadingMessage)
            self.uploadCommentWithTimeout(comment, timeout:uploadTimeout)
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
            var request = URLRequest(url: url)
            request.addAnonymousUserHeader()
            let task = URLSession.shared.dataTask(with: request) {[weak self](data, response, error) in
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

                guard let httpResponse = response as? HTTPURLResponse,
                      200..<300 ~= httpResponse.statusCode else {
                    var message = "The comment could not be submitted."
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                       let backendMessage = json?["error"] as? String {
                        message = backendMessage
                    }
                    DispatchQueue.main.async {
                        self.showAlert(title: "Comment Not Submitted", message: message)
                    }
                    return
                }

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
        request.addAnonymousUserHeader()

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
        let contentKey = ModerationTarget.visibleImage(photoInd).contentKey
        if blockedContributors.isBlocked(
            contributorID: contentOwners[contentKey],
            contentKey: localContentKey(contentKey)
        ) {
            addImageToScrollView(
                image: UIImage(systemName: "eye.slash")!,
                img_idx: photoInd,
                action: nil
            )
            showBlockedImagePlaceholder(at: photoInd)
            return
        }

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

                if self.blockedContributors.isBlocked(
                    contributorID: self.contentOwners[contentKey],
                    contentKey: self.localContentKey(contentKey)
                ) {
                    self.addImageToScrollView(
                        image: UIImage(systemName: "eye.slash")!,
                        img_idx: photoInd,
                        action: nil
                    )
                    self.showBlockedImagePlaceholder(at: photoInd)
                    return
                }

                let action: Selector?
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

    func addImageToScrollView(image: UIImage, img_idx: Int, action: Selector?) {
        imageItems[img_idx]?.container.removeFromSuperview()
        let container = UIView()
        container.tag = img_idx

        let imageView = UIImageView(image: image)
        imageView.tag = img_idx
        imageView.isUserInteractionEnabled = true
        imageView.contentMode = .scaleAspectFit
        if let action = action {
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
        } else {
            imageView.tintColor = .secondaryLabel
            imageView.contentMode = .center
            imageView.backgroundColor = .secondarySystemBackground
        }
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

    private func showBlockedImagePlaceholder(at index: Int) {
        guard let item = imageItems[index] else { return }

        item.imageView.gestureRecognizers?.forEach {
            item.imageView.removeGestureRecognizer($0)
        }
        item.imageView.image = UIImage(systemName: "eye.slash")
        item.imageView.tintColor = .secondaryLabel
        item.imageView.contentMode = .center
        item.imageView.backgroundColor = .secondarySystemBackground
        imageDict.removeValue(forKey: index)

        if !item.container.subviews.contains(where: {
            $0.accessibilityIdentifier == "blockedContentMessage"
        }) {
            let label = UILabel()
            label.text = "You blocked this content"
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
            label.accessibilityIdentifier = "blockedContentMessage"
            item.container.addSubview(label)
        }

        layoutImageItem(index: index)
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

        if let label = item.container.subviews
            .compactMap({ $0 as? UILabel })
            .first(where: { $0.accessibilityIdentifier == "blockedContentMessage" }) {
            let horizontalPadding: CGFloat = 16
            let labelHeight = label.sizeThatFits(
                CGSize(width: pageWidth - 2 * horizontalPadding, height: .greatestFiniteMagnitude)
            ).height
            label.frame = CGRect(
                x: horizontalPadding,
                y: item.imageView.frame.midY + 24,
                width: pageWidth - 2 * horizontalPadding,
                height: labelHeight
            )
        }

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
