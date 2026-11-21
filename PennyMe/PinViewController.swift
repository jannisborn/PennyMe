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
import CoreImage


let flaskURL = "https://pennyme-backend.duckdns.org/"
let imageURL = "https://pennyme.duckdns.org/"

@available(iOS 13.0, *)
class PinViewController: UITableViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    
    let titleLabel = UILabel()
    let updatedLabel = UILabel() // Public comments, retained for the upload flow.
    let submitButton = UIButton(type: .system)
    let commentTextField = UITextField()
    let multiButton = UIButton(type: .system)
    let paywallButton = UIButton(type: .system)
    let addressLabel = UILabel()
    let reportButton = UIButton(type: .system)
    let lastUpdatedLabel = UILabel()
    let lastSeenLabel = UILabel()
    let machineStatusButton = UIButton(type: .system)
    var scrollView: UIScrollView! = UIScrollView()
    var pageControl: UIPageControl! = UIPageControl()
    var contentSession: URLSession = .shared
    var areaChoices: [String] = []
    
    var pinData : Artwork!
    var presenceMonitor: MachinePresenceMonitor?
    let statusChoices = ["unvisited", "visited", "marked", "retired"]
    let statusColors: [UIColor] = [.systemRed, .systemGreen, .systemYellow, .systemGray]

    private struct ImageItemViews {
        let container: UIView
        let imageView: UIImageView
        let photoViewport: MachinePhotoViewport?
        let toggleContainer: UIView?     // nil for idx 0
        let toggleLabel: UILabel?
        let toggleSwitch: UISwitch?
        let spinner: UIActivityIndicatorView
    }

    private var imageItems: [Int: ImageItemViews] = [:]
    private var coinThumbnails: [Int: CoinPreviewView] = [:]
    private var coinButtons: [Int: UIButton] = [:]
    private var coinSpinners: [Int: UIActivityIndicatorView] = [:]
    private var pendingImageIndices: Set<Int> = []
    private var confirmedImageIndices: Set<Int>?
    private var imageTasks: [Int: (id: UUID, task: URLSessionDataTask)] = [:]
    private static let machinePlaceholder = UIImage(named: "machine_image")!

    private func imageIndices(for keys: [String]) -> Set<Int> {
        Set((0...max(0, pinData.numCoins)).filter { keys.contains(ModerationTarget.visibleImage($0).identifier) })
    }
    private var collectionButtons: [UIButton] = []
    private let coinProgressLabel = UILabel()
    private let coinStrip = UIScrollView()
    private let coinStripStack = UIStackView()
    private let coinMoreLabel = UILabel()
    private var coinWidthConstraints: [NSLayoutConstraint] = []
    private let activityStack = UIStackView()
    private var editedWidthConstraint: NSLayoutConstraint?
    private let titleStack = UIStackView()
    private let summaryHeader = UIView()
    private let coinHeadingStack = UIStackView()
    private let collectionChoiceStack = UIStackView()
    private var lastEdited: String = ""
    private var detailsExpanded = false
    private var commentExpanded = false
    private var activityTask: URLSessionDataTask?
    private var activityGeneration = UUID()
    private enum Row: Hashable {
        case photos, coins, collection, comments, addComment, composer
        case edit, details, coordinates, website, info
    }
    private var cells: [Row: UITableViewCell] = [:]
    private var sections: [[Row]] {
        let comments: [Row] = (updatedLabel.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.comments]
        return [[], [.photos], pinData.numCoins > 0 ? [.coins] : [], [.collection],
                comments + [.addComment] + (commentExpanded ? [.composer] : []),
                [.edit, .details] + (detailsExpanded ? [.coordinates, .website, .info] : [])]
    }
    private var collectedByIndex: [Int: Bool] = [:]
    private var collectedKey: String {
        "collectedCoins_\(pinData.id)"
    }

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
        case wrongContent = "Wrong content"
        case spam = "Spam"
        case abuse = "Harassment, hate speech or violence"
        case inappropriate = "Inappropriate content"

        var apiValue: String {
            switch self {
            case .wrongContent: return "wrong_content"
            case .spam: return "spam"
            case .abuse: return "abuse"
            case .inappropriate: return "inappropriate"
            }
        }
    }

    private func localContentKey(_ serverContentKey: String) -> String {
        return "\(pinData.id):\(serverContentKey)"
    }

    var imageDict: [Int: UIImage] = [:]
    private var pendingImageIndex: Int?
    
    // Vars for the image/comment upload
    private var activityIndicator: UIActivityIndicatorView?
    private var loadingView: UIView?
    private var loadingLabel: UILabel?

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.rightBarButtonItems = nil
        navigationItem.largeTitleDisplayMode = .never
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(blockedContentDidChange),
            name: .blockedContentDidChange,
            object: nil
        )
        
        NotificationCenter.default.addObserver(self, selector: #selector(presenceDidChange(_:)),
                                               name: .machinePresenceDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshVisibleActivity),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        if presenceMonitor == nil {
            presenceMonitor = MachinePresenceMonitor(hasNearbyMachine: { _ in false }, isBlocked: { [weak self] id in
                self?.blockedContributors.isBlocked(contributorID: nil, contentKey: "\(id):machine:listing") ?? true
            })
        }
        loadCollectedFromDefaults()
        pendingImageIndices = imageIndices(for: pinData.availableImages ?? [])
        overrideUserInterfaceStyle = .light
        lastEdited = pinData.last_updated
        buildPinLayout()
        loadModerationManifestAndContent()
    }

    deinit {
        activityTask?.cancel()
        imageTasks.values.forEach { $0.task.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func confirmMachinePresence() {
        guard let id = Int(pinData.id) else { return }
        CommunityTermsGate.start(from: self) { [weak self] in
            guard let self = self else { return }
            let machine = PresenceMachine(id: id, name: self.pinData.title ?? "Penny machine",
                                          latitude: self.pinData.coordinate.latitude, longitude: self.pinData.coordinate.longitude,
                                          numCoins: self.pinData.numCoins)
            self.presenceMonitor?.requestManualConfirmation(machine)
        }
    }

    @objc private func blockedContentDidChange() {
        guard hasLoadedModerationManifest, isDisplayingMachine else {
            needsBlockedContentRefresh = true
            return
        }
        loadCommunityContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Align the first title line with the native back button, with room to its right.
        tableView.contentInset.top = -(navigationController?.navigationBar.bounds.height ?? 44)
        refreshActivity()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard needsBlockedContentRefresh, hasLoadedModerationManifest else { return }
        needsBlockedContentRefresh = false
        loadCommunityContent()
    }

    private var isDisplayingMachine: Bool {
        guard isViewLoaded, let window = view.window, !window.isHidden else { return false }
        guard let navigationController = navigationController else { return true }
        return navigationController.visibleViewController === self
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        cells[sections[indexPath.section][indexPath.row]]!
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].isEmpty || section <= 1 ? .leastNormalMagnitude : 8
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.contentSize = CGSize(width: scrollView.bounds.width * CGFloat(pinData.numCoins + 1),
                                        height: scrollView.bounds.height)
        for idx in imageItems.keys.sorted() { layoutImageItem(index: idx) }
        layoutCoinStrip()
        let page = max(0, min(pageControl.currentPage, pinData.numCoins))
        if !scrollView.isDragging && !scrollView.isDecelerating {
            scrollView.contentOffset.x = CGFloat(page) * scrollView.bounds.width
        }
        let accessibleText = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        editedWidthConstraint?.isActive = !accessibleText
        for stack in [activityStack, titleStack, coinHeadingStack, collectionChoiceStack] {
            stack.axis = accessibleText ? .vertical : .horizontal
        }
        titleStack.alignment = accessibleText ? .leading : .top
        coinHeadingStack.alignment = accessibleText ? .leading : .center
        if tableView.bounds.width > 0 {
            let fitted = summaryHeader.systemLayoutSizeFitting(CGSize(width: tableView.bounds.width, height: 0),
                                                              withHorizontalFittingPriority: .required,
                                                              verticalFittingPriority: .fittingSizeLevel)
            if summaryHeader.frame.size != fitted {
                summaryHeader.frame.size = fitted
                tableView.tableHeaderView = summaryHeader
            }
        }
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === coinStrip { updateCoinScrollHint(); return }
        guard scrollView === self.scrollView, scrollView.bounds.width > 0 else { return }
        let page = Int(round(scrollView.contentOffset.x / scrollView.bounds.width))
        pageControl.currentPage = max(0, min(page, pageControl.numberOfPages - 1))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded, pinData != nil,
           previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateActivityLabels()
        }
    }

    func addPaywallButton() {
        paywallButton.isHidden = false
        paywallButton.addTarget(self, action: #selector(paywallButtonTapped), for: .touchUpInside)
        let paywallImage = UIImage(systemName: "dollarsign.circle")?.withTintColor(.black, renderingMode: .alwaysOriginal)
        paywallButton.setImage(paywallImage, for: .normal)
        paywallButton.accessibilityLabel = "Admission fee may apply"
    }

    func addMultimachineButton() {
        multiButton.isHidden = false
        let multiImage = UIImage(systemName: "\(self.pinData.multimachine).circle")?.withTintColor(.black, renderingMode: .alwaysOriginal)
        multiButton.setImage(multiImage, for: .normal)
        multiButton.accessibilityLabel = "\(pinData.multimachine) machines at this location"
        multiButton.addTarget(self, action: #selector(multimachineButtonTapped), for: .touchUpInside)
    }
    
    @objc func paywallButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Paywall!", text: "You probably have to pay a fee to see this penny machine.")
    }
    @objc func multimachineButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Multi-machine!", text: "There are \(self.pinData.multimachine) penny machines in this location. \nPlease add new machines in the correct locations!")
    }
    @objc func statusButtonTapped(sender: UIButton!) {
        showSimpleAlert(title: "Machine is \(self.pinData.machineStatus)", text: "Machine can be available, out-of-order (temporarily unavailable) or retired (permanently unavailable).\nTap 'Edit machine information' to update the machine status.")
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
            applyPhotoManifest(owners: [:], availableImages: nil)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.addAnonymousUserHeader()
        contentSession.dataTask(with: request) { [weak self] data, response, _ in
            let json = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                : nil
            let owners = json?["owners"] as? [String: String] ?? [:]
            let availableImages = json?["available_images"] as? [String]
            DispatchQueue.main.async {
                self?.applyPhotoManifest(owners: owners, availableImages: availableImages)
            }
        }.resume()
    }

    private func applyPhotoManifest(owners: [String: String], availableImages: [String]?) {
        contentOwners = owners
        if let availableImages {
            pinData.availableImages = availableImages
            let confirmed = imageIndices(for: availableImages)
            confirmedImageIndices = confirmed
            pendingImageIndices = confirmed.subtracting(imageDict.keys)
            updateImageLoadingIndicators()
        }
        hasLoadedModerationManifest = true
        needsBlockedContentRefresh = false
        // A response can arrive between appearance callbacks. Start the downloads
        // as soon as the manifest completes, regardless of navigation timing.
        loadCommunityContent()
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
        let imageReport = UIAlertAction(title: page == 0 ? "Report Machine Image" : "Report Coin Image \(page)", style: .default) { _ in
            self.chooseReportReason(for: imageTarget, blockContributor: false)
        }
        imageReport.isEnabled = imageDict[page] != nil
        sheet.addAction(imageReport)
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
            popover.sourceView = reportButton
            popover.sourceRect = reportButton.bounds
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
            popover.sourceView = reportButton
            popover.sourceRect = reportButton.bounds
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
                self.requestReportComment(
                    target: target,
                    reason: reason,
                    blockContributor: blockContributor
                )
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = reportButton
            popover.sourceRect = reportButton.bounds
        }
        present(sheet, animated: true)
    }

    private func requestReportComment(
        target: ModerationTarget,
        reason: ReportReason,
        blockContributor: Bool
    ) {
        let alert = UIAlertController(
            title: "Explain Report",
            message: "Please explain why you are flagging this content.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "Explanation"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak alert] _ in
            let comment = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard comment.count >= 5 else {
                self.showAlert(
                    title: "Invalid Explanation",
                    message: "Please enter a proper explanation why you are flagging this content"
                )
                return
            }
            if blockContributor {
                self.confirmBlock(target: target, reason: reason, comment: comment)
            } else {
                self.submitModerationReport(
                    target: target,
                    reason: reason,
                    comment: comment,
                    blockContributor: false
                )
            }
        })
        present(alert, animated: true)
    }

    private func confirmBlock(
        target: ModerationTarget,
        reason: ReportReason,
        comment: String
    ) {
        let alert = UIAlertController(
            title: "Block Contributor?",
            message: "All attributed machine listings, images, and comments from this contributor will be hidden throughout PennyMe on this device. While content is not deleted, useful information may appear missing to you! You can reverse this in Settings → Blocked content. PennyMe will also receive a report for review within several working days.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Block & Report", style: .destructive) { _ in
            self.submitModerationReport(
                target: target,
                reason: reason,
                comment: comment,
                blockContributor: true
            )
        })
        present(alert, animated: true)
    }

    private func submitModerationReport(
        target: ModerationTarget,
        reason: ReportReason,
        comment: String,
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
            "comment": comment,
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
        
            if let url = URL(string: urlEncodedStringRequest){
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                let task = contentSession.dataTask(with: request) {(data, response, error) in
                    guard let data = data else { return }
                    let results = try? JSONSerialization.jsonObject(with: data, options: JSONSerialization.ReadingOptions.allowFragments)
                    if let results_ = results as? Dictionary<String, String> {
                        let sortedDates = results_.keys.sorted {$0 > $1}
                        var displayString : String = ""
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
                                ? ""
                                : "Comments from blocked contributors are hidden."
                        }
                        completionBlock(displayString)
                    }
                }
                task.resume()
            }
        }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section][indexPath.row] {
        case .addComment:
            commentExpanded.toggle()
            cells[.addComment]?.accessoryType = commentExpanded ? .none : .disclosureIndicator
            tableView.reloadData()
            if commentExpanded { commentTextField.becomeFirstResponder() }
            else { commentTextField.resignFirstResponder() }
        case .edit:
            openMachineChangeRequest()
        case .details:
            detailsExpanded.toggle()
            cells[.details]?.accessoryView = UIImageView(image: UIImage(systemName: detailsExpanded ? "chevron.up" : "chevron.down"))
            cells[.details]?.accessibilityValue = detailsExpanded ? "Expanded" : "Collapsed"
            tableView.reloadData()
        case .coordinates:
            copyToPasteboard(String(format: "%f, %f", pinData.coordinate.latitude, pinData.coordinate.longitude))
        case .website:
            if let url = URL(string: pinData.link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            } else {
                showConfirmationMessage(message: "No external link available.", duration: 2)
            }
        default: break
        }
    }

    /// Always route to the stored point, regardless of how the address is formatted.
    var directionsMapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: pinData.coordinate))
        item.name = pinData.title
        return item
    }

    @objc private func openDirections() {
        directionsMapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    @objc private func copyTitle() {
        if let title = pinData.title, !title.isEmpty { copyToPasteboard(title) }
    }

    @objc private func copyAddress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { copyToPasteboard(pinData.address) }
    }

    private func copyToPasteboard(_ string: String) {
        UIPasteboard.general.string = string
        copyFeedback.notificationOccurred(.success)
        copyFeedback.prepare()
        showConfirmationMessage(message: "Copied!", duration: 1.5)
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

    @objc private func collectionStatusChanged(_ sender: UIButton) {
        let status = statusChoices[sender.tag]
        pinData.status = status
        saveStatusChange(machineid: pinData.id, new_status: status)
        applyCollectionStyle()
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
            imageTasks.removeValue(forKey: photoInd)?.task.cancel()
            pendingImageIndices.remove(photoInd)
            addImageToScrollView(
                image: UIImage(systemName: "eye.slash")!,
                img_idx: photoInd,
                action: nil
            )
            showBlockedImagePlaceholder(at: photoInd)
            return
        }

        // An older or failed manifest cannot tell us that a cached omission is current.
        if let available = confirmedImageIndices, !available.contains(photoInd) {
            imageTasks.removeValue(forKey: photoInd)?.task.cancel()
            pendingImageIndices.remove(photoInd)
            imageDict.removeValue(forKey: photoInd)
            addImageToScrollView(image: photoInd == 0 ? Self.machinePlaceholder : CoinPreviewView.placeholder,
                                 img_idx: photoInd,
                                 action: photoInd == 0 ? #selector(startNewMachineUpload(tapGestureRecognizer:)) : #selector(startNewCoinUpload(tapGestureRecognizer:)))
            return
        }
        guard imageTasks[photoInd] == nil else { return }
        let filename = photoInd == 0 ? "\(pinData.id).jpg" : "\(pinData.id)_coin_\(photoInd - 1).png"
        guard let url = URL(string: imageURL + filename) else { return }
        if confirmedImageIndices?.contains(photoInd) == true { pendingImageIndices.insert(photoInd) }
        updateImageLoadingIndicators()

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let requestID = UUID()
        let task = contentSession.dataTask(with: request) { [weak self] data, response, _ in
            let downloadedImage = (response as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(UIImage.init(data:)) : nil
            DispatchQueue.main.async {
                guard let self, self.imageTasks[photoInd]?.id == requestID else { return }
                self.imageTasks.removeValue(forKey: photoInd)
                self.pendingImageIndices.remove(photoInd)

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
                    self.imageDict.removeValue(forKey: photoInd)
                    let isCoin = photoInd > 0
                    finalImage = isCoin ? CoinPreviewView.placeholder : Self.machinePlaceholder
                    action = isCoin ? #selector(self.startNewCoinUpload(tapGestureRecognizer:)) : #selector(self.startNewMachineUpload(tapGestureRecognizer:))
                }

                self.addImageToScrollView(image: finalImage, img_idx: photoInd, action: action)
            }
        }
        imageTasks[photoInd] = (requestID, task)
        task.resume()
    }

    private func imageSpinner(at index: Int) -> UIActivityIndicatorView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.color = .label
        spinner.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        spinner.layer.cornerRadius = 16
        spinner.bounds.size = CGSize(width: 32, height: 32)
        spinner.accessibilityIdentifier = "photoLoading_\(index)"
        spinner.accessibilityLabel = index == 0 ? "Loading machine photo" : "Loading coin photo \(index)"
        return spinner
    }

    private func updateImageLoadingIndicators() {
        for (index, item) in imageItems {
            if pendingImageIndices.contains(index) { item.spinner.startAnimating() }
            else { item.spinner.stopAnimating() }
        }
        for (index, spinner) in coinSpinners {
            if pendingImageIndices.contains(index) { spinner.startAnimating() }
            else { spinner.stopAnimating() }
        }
    }

    @objc private func collectedSwitchChanged(_ sender: UISwitch) {
        setCoinCollected(sender.isOn, at: sender.tag)
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

        let isCoinPlaceholder = image === CoinPreviewView.placeholder
        let galleryImage = img_idx > 0 && action != nil
            ? (isCoinPlaceholder ? CoinPreviewView.landscapePlaceholder : CoinPreviewView.orientedImage(image, landscape: true)) : image
        let imageView: UIImageView = img_idx == 0 ? UIImageView(image: galleryImage) : CoinPreviewView(image: galleryImage)
        imageView.tag = img_idx
        imageView.isUserInteractionEnabled = true
        // Aspect fill computes the crop from each photo's dimensions; full originals remain available on tap.
        imageView.contentMode = img_idx == 0 && imageDict[0] != nil ? .scaleAspectFill : .scaleAspectFit
        imageView.clipsToBounds = img_idx == 0
        if let action = action {
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
        } else {
            imageView.tintColor = .secondaryLabel
            imageView.contentMode = .center
            imageView.backgroundColor = .secondarySystemBackground
        }
        let photoViewport: MachinePhotoViewport?
        if img_idx == 0, imageDict[0] != nil, action != nil {
            let viewport = MachinePhotoViewport(imageView: imageView) { [weak self] in self?.openPhoto(at: img_idx) }
            container.addSubview(viewport)
            // Vertical drags belong to the crop; horizontal drags still page the gallery.
            scrollView.panGestureRecognizer.require(toFail: viewport.verticalPan)
            tableView.panGestureRecognizer.require(toFail: viewport.verticalPan)
            photoViewport = viewport
        } else {
            container.addSubview(imageView)
            photoViewport = nil
        }

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
        let spinner = imageSpinner(at: img_idx)
        container.addSubview(spinner)

        imageItems[img_idx] = ImageItemViews(
            container: container,
            imageView: imageView,
            photoViewport: photoViewport,
            toggleContainer: toggleContainer,
            toggleLabel: toggleLabel,
            toggleSwitch: toggleSwitch,
            spinner: spinner
        )

        if let thumbnail = coinThumbnails[img_idx] {
            thumbnail.image = action == nil ? image : (isCoinPlaceholder
                ? (pinData.numCoins <= 2 ? CoinPreviewView.landscapePlaceholder : CoinPreviewView.placeholder)
                : CoinPreviewView.orientedImage(image, landscape: pinData.numCoins <= 2))
            thumbnail.contentMode = action == nil ? .center : .scaleAspectFit
        }
        updateCollectionAppearance()
        updateImageLoadingIndicators()
        layoutImageItem(index: img_idx)
    }

    private func showBlockedImagePlaceholder(at index: Int) {
        guard let item = imageItems[index] else { return }
        pendingImageIndices.remove(index)
        updateImageLoadingIndicators()

        item.imageView.gestureRecognizers?.forEach {
            item.imageView.removeGestureRecognizer($0)
        }
        item.imageView.image = UIImage(systemName: "eye.slash")
        item.imageView.tintColor = .secondaryLabel
        item.imageView.contentMode = .center
        item.imageView.backgroundColor = .secondarySystemBackground
        item.photoViewport?.isPanEnabled = false
        imageDict.removeValue(forKey: index)
        (item.imageView as? CoinPreviewView)?.isCollected = false
        coinThumbnails[index]?.image = UIImage(systemName: "eye.slash")
        coinThumbnails[index]?.isCollected = false
        coinThumbnails[index]?.contentMode = .center
        coinButtons[index]?.isEnabled = false

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

        let pageWidth = scrollView.bounds.width
        let pageHeight = scrollView.bounds.height
        let xPosition = pageWidth * CGFloat(index)

        item.container.frame = CGRect(x: xPosition, y: 0, width: pageWidth, height: pageHeight)

        let toggleHeight: CGFloat = (item.toggleContainer == nil) ? 0 : 44
        let spacing: CGFloat = (toggleHeight == 0) ? 0 : 8

        // Image uses remaining height above the toggle
        let imageFrame = CGRect(
            x: 0,
            y: 0,
            width: pageWidth,
            height: max(0, pageHeight - toggleHeight - spacing)
        )
        item.spinner.center = CGPoint(x: imageFrame.midX, y: imageFrame.midY)
        if let viewport = item.photoViewport {
            viewport.frame = imageFrame
            viewport.setNeedsLayout()
            viewport.layoutIfNeeded()
        } else {
            item.imageView.frame = index > 0 ? imageFrame.insetBy(dx: 8, dy: 8) : imageFrame
        }

        if let label = item.container.subviews
            .compactMap({ $0 as? UILabel })
            .first(where: { $0.accessibilityIdentifier == "blockedContentMessage" }) {
            let horizontalPadding: CGFloat = 16
            let labelHeight = label.sizeThatFits(
                CGSize(width: pageWidth - 2 * horizontalPadding, height: .greatestFiniteMagnitude)
            ).height
            label.frame = CGRect(
                x: horizontalPadding,
                y: imageFrame.midY + 24,
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
        openPhoto(at: tappedView.tag)
    }

    private func openPhoto(at index: Int) {
        guard imageDict[index] != nil else { return }
        pendingImageIndex = index
        performSegue(withIdentifier: "bigImage", sender: self)
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

private extension PinViewController {
    func buildPinLayout() {
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.keyboardDismissMode = .interactive
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.sectionHeaderTopPadding = 0
        if #available(iOS 26.0, *) { tableView.topEdgeEffect.isHidden = true }
        copyFeedback.prepare()

        titleLabel.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.lineBreakStrategy = []
        titleLabel.attributedText = pinData.displayTitle
        titleLabel.accessibilityLabel = pinData.title
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.isUserInteractionEnabled = true
        titleLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(copyTitle)))
        titleLabel.accessibilityTraits.insert(.button)
        titleLabel.accessibilityHint = "Copies the machine name"
        titleLabel.accessibilityIdentifier = "pinTitle"

        let statusColor: UIColor = pinData.machineStatus == "available" ? .systemGreen : .systemGray
        var badge = UIButton.Configuration.tinted()
        badge.title = pinData.machineStatus.replacingOccurrences(of: "-", with: " ").capitalized
        badge.image = UIImage(systemName: pinData.machineStatus == "available" ? "checkmark.circle.fill" : "exclamationmark.circle")
        badge.imagePadding = 5
        badge.baseForegroundColor = pinData.machineStatus == "available" ? UIColor(red: 0.13, green: 0.42, blue: 0.23, alpha: 1) : .secondaryLabel
        badge.baseBackgroundColor = statusColor
        badge.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        badge.cornerStyle = .capsule
        badge.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        badge.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming
            result.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return result
        }
        machineStatusButton.configuration = badge
        machineStatusButton.addTarget(self, action: #selector(statusButtonTapped), for: .touchUpInside)
        machineStatusButton.accessibilityLabel = "Machine status: \(pinData.machineStatus)"
        machineStatusButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        paywallButton.isHidden = !pinData.paywall
        multiButton.isHidden = pinData.multimachine <= 1
        if pinData.paywall { addPaywallButton() }
        if pinData.multimachine > 1 { addMultimachineButton() }
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(machineStatusButton)
        titleStack.axis = .horizontal
        titleStack.spacing = 6
        titleStack.alignment = .top
        titleStack.isLayoutMarginsRelativeArrangement = true
        titleStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 48, bottom: 0, trailing: 0)
        for button in [paywallButton, multiButton] {
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.contentVerticalAlignment = .center
        }
        machineStatusButton.setContentHuggingPriority(.required, for: .horizontal)
        machineStatusButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        for label in [lastSeenLabel, lastUpdatedLabel] {
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
        }
        activityStack.spacing = 8
        activityStack.distribution = .fill
        // Reserve room for reporting by giving Edited 90% of Seen's width.
        editedWidthConstraint = lastUpdatedLabel.widthAnchor.constraint(equalTo: lastSeenLabel.widthAnchor, multiplier: 0.9)
        for (label, action) in [(lastSeenLabel, #selector(showSeenInfo)), (lastUpdatedLabel, #selector(showEditedInfo))] {
            label.isUserInteractionEnabled = true
            label.accessibilityTraits = .button
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
        }
        activityStack.addArrangedSubview(lastSeenLabel)
        activityStack.addArrangedSubview(lastUpdatedLabel)
        editedWidthConstraint?.isActive = !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        updateActivityLabels()

        reportButton.setImage(UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        reportButton.tintColor = .systemRed
        reportButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        reportButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        reportButton.accessibilityLabel = "Report content"
        reportButton.accessibilityIdentifier = "reportContentButton"
        reportButton.addTarget(self, action: #selector(showContentSafetyActions), for: .touchUpInside)
        let activityRow = horizontalStack([activityStack, reportButton], spacing: 4)
        activityRow.isLayoutMarginsRelativeArrangement = true
        activityRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)

        let directions = UIImageView(image: UIImage(systemName: "location.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17.82)))
        directions.tintColor = .systemBlue
        directions.contentMode = .center
        directions.widthAnchor.constraint(equalToConstant: 22).isActive = true
        directions.heightAnchor.constraint(equalToConstant: 22).isActive = true
        directions.accessibilityIdentifier = "pinDirections"
        directions.accessibilityLabel = "Walking directions to the machine"
        let displayedAddress = Self.compactAddress(pinData.address)
        addressLabel.text = displayedAddress.isEmpty ? "Navigate to machine" : displayedAddress
        addressLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14.025))
        addressLabel.adjustsFontForContentSizeCategory = true
        addressLabel.numberOfLines = 0
        addressLabel.textColor = .secondaryLabel
        let address = horizontalStack([directions, addressLabel], spacing: 4)
        address.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        address.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openDirections)))
        address.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(copyAddress(_:))))
        address.isAccessibilityElement = true
        address.accessibilityLabel = addressLabel.text
        address.accessibilityTraits = .button
        address.accessibilityHint = "Walking directions to the machine's coordinates. Hold to copy the address."
        address.accessibilityIdentifier = "pinAddress"
        let features = horizontalStack([paywallButton, multiButton], spacing: 0)
        features.accessibilityIdentifier = "pinMachineFeatures"
        features.isHidden = !pinData.paywall && pinData.multimachine <= 1
        let featureRow = horizontalStack([features, UIView()], spacing: 0)
        featureRow.isHidden = features.isHidden
        featureRow.isLayoutMarginsRelativeArrangement = true
        featureRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 4, trailing: 10)
        let summary = UIStackView(arrangedSubviews: [titleStack, address, activityRow, featureRow])
        summary.axis = .vertical
        summary.spacing = 0
        summary.translatesAutoresizingMaskIntoConstraints = false
        summaryHeader.addSubview(summary)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: summaryHeader.leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: summaryHeader.trailingAnchor, constant: -8),
            summary.topAnchor.constraint(equalTo: summaryHeader.topAnchor),
            summary.bottomAnchor.constraint(equalTo: summaryHeader.bottomAnchor)
        ])
        tableView.tableHeaderView = summaryHeader

        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.layer.cornerRadius = 12
        scrollView.clipsToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalTo: scrollView.widthAnchor, multiplier: 9.0 / 16).isActive = true
        pageControl.numberOfPages = max(1, pinData.numCoins + 1)
        pageControl.currentPageIndicatorTintColor = .label
        pageControl.pageIndicatorTintColor = .systemGray3
        pageControl.hidesForSinglePage = true
        pageControl.addTarget(self, action: #selector(photoPageChanged), for: .valueChanged)
        pageControl.accessibilityLabel = "Machine and coin photos"
        let photoCell = makeCell(.photos, views: [scrollView, pageControl], spacing: 0, insets: .zero)
        photoCell.backgroundConfiguration = .clear()

        if pinData.numCoins > 0 {
            let coinTitle = label("\(pinData.numCoins) \(pinData.numCoins == 1 ? "design" : "designs")", style: .subheadline, weight: .semibold)
            coinProgressLabel.font = .preferredFont(forTextStyle: .caption1)
            coinProgressLabel.adjustsFontForContentSizeCategory = true
            coinProgressLabel.textColor = .secondaryLabel
            coinHeadingStack.axis = .horizontal
            coinHeadingStack.alignment = .center
            coinHeadingStack.spacing = 8
            coinHeadingStack.distribution = .fillEqually
            coinHeadingStack.addArrangedSubview(coinTitle)
            coinHeadingStack.addArrangedSubview(coinProgressLabel)
            coinProgressLabel.textAlignment = .right
            coinProgressLabel.numberOfLines = 0
            coinStrip.delegate = self
            coinStrip.accessibilityIdentifier = "coinDesignsScroll"
            coinStrip.showsHorizontalScrollIndicator = pinData.numCoins > 4
            coinStrip.alwaysBounceHorizontal = pinData.numCoins > 4
            coinStripStack.axis = .horizontal
            coinStripStack.spacing = 12
            coinStripStack.alignment = .center
            coinStripStack.isLayoutMarginsRelativeArrangement = true
            coinStripStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8)
            coinStripStack.translatesAutoresizingMaskIntoConstraints = false
            coinStrip.addSubview(coinStripStack)
            NSLayoutConstraint.activate([
                coinStripStack.leadingAnchor.constraint(equalTo: coinStrip.contentLayoutGuide.leadingAnchor),
                coinStripStack.trailingAnchor.constraint(equalTo: coinStrip.contentLayoutGuide.trailingAnchor),
                coinStripStack.topAnchor.constraint(equalTo: coinStrip.contentLayoutGuide.topAnchor),
                coinStripStack.bottomAnchor.constraint(equalTo: coinStrip.contentLayoutGuide.bottomAnchor),
                coinStripStack.heightAnchor.constraint(equalTo: coinStrip.frameLayoutGuide.heightAnchor)
            ])
            for index in 1...pinData.numCoins {
                let thumbnail = CoinPreviewView(image: CoinPreviewView.placeholder)
                thumbnail.tag = index
                thumbnail.contentMode = .scaleAspectFit
                thumbnail.isUserInteractionEnabled = true
                thumbnail.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(coinThumbnailTapped(_:))))
                thumbnail.accessibilityIdentifier = "coinThumbnail_\(index)"
                thumbnail.isAccessibilityElement = true
                thumbnail.accessibilityTraits = .button
                let width = thumbnail.widthAnchor.constraint(equalToConstant: 76)
                coinWidthConstraints.append(width)
                NSLayoutConstraint.activate([width, thumbnail.heightAnchor.constraint(equalToConstant: pinData.numCoins <= 2 ? 88 : 100)])
                let button = UIButton(type: .system)
                button.tag = index
                button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.accessibilityIdentifier = "collectCoin_\(index)"
                button.addTarget(self, action: #selector(coinCollectionTapped(_:)), for: .touchUpInside)
                let column = UIStackView(arrangedSubviews: [thumbnail, button])
                column.axis = .vertical
                column.spacing = 0
                coinStripStack.addArrangedSubview(column)
                coinThumbnails[index] = thumbnail
                coinButtons[index] = button
                let spinner = imageSpinner(at: index)
                spinner.accessibilityIdentifier = "coinLoading_\(index)"
                spinner.translatesAutoresizingMaskIntoConstraints = false
                thumbnail.addSubview(spinner)
                NSLayoutConstraint.activate([
                    spinner.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
                    spinner.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
                    spinner.widthAnchor.constraint(equalToConstant: 32),
                    spinner.heightAnchor.constraint(equalToConstant: 32)
                ])
                coinSpinners[index] = spinner
            }
            coinMoreLabel.font = .preferredFont(forTextStyle: .caption2)
            coinMoreLabel.adjustsFontForContentSizeCategory = true
            coinMoreLabel.textColor = .secondaryLabel
            coinMoreLabel.textAlignment = .center
            coinMoreLabel.isHidden = pinData.numCoins <= 4
            coinMoreLabel.text = "Swipe for more designs →"
            makeCell(.coins, views: [coinHeadingStack, coinStrip, coinMoreLabel], spacing: 0,
                     insets: NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
        }

        let choices = pinData.status == "retired" ? statusChoices : Array(statusChoices.prefix(3))
        let symbols = ["circle.dashed", "checkmark.circle", "bookmark", "archivebox"]
        collectionChoiceStack.axis = .horizontal
        collectionChoiceStack.spacing = 6
        collectionChoiceStack.distribution = .fillEqually
        for (index, choice) in choices.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            var config = UIButton.Configuration.plain()
            config.title = choice.capitalized
            config.image = UIImage(systemName: symbols[index])?.withTintColor(statusColors[index], renderingMode: .alwaysOriginal)
            config.imagePlacement = .top
            config.imagePadding = 5
            config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 3, bottom: 9, trailing: 3)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var result = incoming
                result.font = .preferredFont(forTextStyle: .caption1).withWeight(.medium)
                return result
            }
            button.configuration = config
            button.layer.cornerRadius = 10
            button.addTarget(self, action: #selector(collectionStatusChanged(_:)), for: .touchUpInside)
            button.accessibilityIdentifier = "collection_\(choice)"
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            collectionChoiceStack.addArrangedSubview(button)
            collectionButtons.append(button)
        }
        makeCell(.collection, views: [label("My collection", style: .subheadline, weight: .semibold), collectionChoiceStack], spacing: 10)
        applyCollectionStyle()

        updatedLabel.numberOfLines = 0
        updatedLabel.font = .preferredFont(forTextStyle: .subheadline)
        updatedLabel.adjustsFontForContentSizeCategory = true
        makeCell(.comments, views: [updatedLabel])
        actionCell(.addComment, title: "Add public comment", symbol: "bubble.left", disclosure: true)
        commentTextField.placeholder = "Write a public comment"
        commentTextField.font = .preferredFont(forTextStyle: .body)
        commentTextField.adjustsFontForContentSizeCategory = true
        commentTextField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        submitButton.setImage(UIImage(systemName: "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)), for: .normal)
        submitButton.accessibilityLabel = "Submit comment"
        submitButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        submitButton.addTarget(self, action: #selector(addComment), for: .touchUpInside)
        makeCell(.composer, views: [horizontalStack([commentTextField, submitButton], spacing: 8)])
        actionCell(.edit, title: "Edit machine information", symbol: "square.and.pencil", disclosure: true)
        actionCell(.details, title: "Details", symbol: "info.circle")
        cells[.details]?.accessoryView = UIImageView(image: UIImage(systemName: "chevron.down"))
        cells[.details]?.accessibilityValue = "Collapsed"
        actionCell(.coordinates, title: String(format: "%.6f, %.6f", pinData.coordinate.latitude, pinData.coordinate.longitude), symbol: "mappin.and.ellipse")
        cells[.coordinates]?.accessibilityHint = "Copies the coordinates"
        actionCell(.website, title: Self.externalWebsiteTitle(for: pinData.link), symbol: "safari", disclosure: true)
        if URL(string: pinData.link)?.host == nil {
            var config = cells[.website]?.contentConfiguration as? UIListContentConfiguration
            config?.text = "No website available"
            config?.textProperties.color = .secondaryLabel
            config?.imageProperties.tintColor = .tertiaryLabel
            cells[.website]?.contentConfiguration = config
            cells[.website]?.isUserInteractionEnabled = false
            cells[.website]?.accessoryType = .none
        }
        makeCell(.info, views: [label(detailInfo, style: .footnote)])
        updateCollectionAppearance()

        for index in 0...max(0, pinData.numCoins) {
            let placeholder = index == 0 ? Self.machinePlaceholder : CoinPreviewView.placeholder
            addImageToScrollView(image: placeholder, img_idx: index,
                                 action: index == 0 ? #selector(startNewMachineUpload(tapGestureRecognizer:)) : #selector(startNewCoinUpload(tapGestureRecognizer:)))
        }
    }

    @discardableResult
    private func makeCell(_ row: Row, views: [UIView], spacing: CGFloat = 8, insets: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "pin_\(row)"
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: insets.leading),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -insets.trailing),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: insets.top),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -insets.bottom)
        ])
        cells[row] = cell
        return cell
    }

    private func actionCell(_ row: Row, title: String, symbol: String, disclosure: Bool = false) {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var config = cell.defaultContentConfiguration()
        config.text = title
        config.textProperties.font = .preferredFont(forTextStyle: .body)
        config.textProperties.numberOfLines = 0
        config.image = UIImage(systemName: symbol)
        config.imageProperties.tintColor = .systemBlue
        config.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        cell.contentConfiguration = config
        cell.accessoryType = disclosure ? .disclosureIndicator : .none
        cell.accessibilityIdentifier = "pin_\(row)"
        cells[row] = cell
    }

    func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style).withWeight(weight)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    func horizontalStack(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        return stack
    }

    func applyCollectionStyle() {
        for button in collectionButtons {
            let selected = statusChoices[button.tag] == pinData.status
            let color = statusColors[button.tag]
            button.backgroundColor = color.withAlphaComponent(selected ? 0.2484 : 0.06)
            button.layer.borderWidth = selected ? 1.5 : 0
            button.layer.borderColor = color.withAlphaComponent(0.55).cgColor
            button.configuration?.baseForegroundColor = .label
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    @objc func photoPageChanged() {
        scrollView.setContentOffset(CGPoint(x: CGFloat(pageControl.currentPage) * scrollView.bounds.width, y: 0), animated: true)
    }

    @objc func coinThumbnailTapped(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view else { return }
        let key = ModerationTarget.visibleImage(view.tag).contentKey
        guard !blockedContributors.isBlocked(contributorID: contentOwners[key], contentKey: localContentKey(key)) else { return }
        pageControl.currentPage = view.tag
        photoPageChanged()
        if imageDict[view.tag] != nil { enlargeImage(tapGestureRecognizer: gesture) }
        else { startNewCoinUpload(tapGestureRecognizer: gesture) }
    }

    @objc func coinCollectionTapped(_ sender: UIButton) {
        setCoinCollected(!(collectedByIndex[sender.tag] ?? false), at: sender.tag)
    }

    func setCoinCollected(_ collected: Bool, at index: Int) {
        guard !collected || imageDict[index] != nil else {
            imageItems[index]?.toggleSwitch?.setOn(false, animated: true)
            showConfirmationMessage(message: "Take a picture first!", duration: 1.5)
            return
        }
        collectedByIndex[index] = collected
        saveCollectedToDefaults()
        updateCollectionAppearance()
    }

    func updateCollectionAppearance() {
        let count = (0..<max(0, pinData.numCoins)).filter { collectedByIndex[$0 + 1] == true }.count
        coinProgressLabel.text = "\(count)/\(pinData.numCoins) collected"
        let complete = pinData.numCoins > 0 && count == pinData.numCoins
        cells[.coins]?.layer.borderWidth = complete ? 5 : 0
        cells[.coins]?.layer.borderColor = UIColor.systemGreen.cgColor
        cells[.coins]?.layer.cornerRadius = 16
        cells[.coins]?.accessibilityValue = complete ? "All coins collected" : coinProgressLabel.text
        coinProgressLabel.textColor = complete ? .systemGreen : .secondaryLabel
        for (index, thumbnail) in coinThumbnails {
            let collected = collectedByIndex[index] == true
            let key = ModerationTarget.visibleImage(index).contentKey
            let blocked = blockedContributors.isBlocked(contributorID: contentOwners[key], contentKey: localContentKey(key))
            thumbnail.isCollected = collected && imageDict[index] != nil && !blocked
            thumbnail.accessibilityLabel = blocked ? "Coin \(index): image from a blocked contributor" : "Coin \(index)\(collected ? ", collected" : ""). Tap to enlarge or add a photo."
            coinButtons[index]?.isEnabled = !blocked
            coinButtons[index]?.setImage(UIImage(systemName: collected ? "checkmark.circle.fill" : "plus.circle"), for: .normal)
            coinButtons[index]?.setTitle(" \(index)", for: .normal)
            coinButtons[index]?.tintColor = collected ? .systemGreen : .secondaryLabel
            coinButtons[index]?.accessibilityLabel = "\(collected ? "Uncollect" : "Collect") coin \(index)"
            coinButtons[index]?.accessibilityTraits = collected ? [.button, .selected] : .button
            imageItems[index]?.toggleSwitch?.setOn(collected, animated: true)
            (imageItems[index]?.imageView as? CoinPreviewView)?.isCollected = collected && imageDict[index] != nil && !blocked
        }
    }

    var detailInfo: String {
        "Machine #\(pinData.id) · \(pinData.area)"
    }

    static func activityDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "yyyy-MM-dd"
        return date.date(from: value)
    }

    func updateActivityLabels() {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        for (label, symbol, prefix, value) in [(lastSeenLabel, "eye", "Seen", pinData.lastSeen),
                                               (lastUpdatedLabel, "pencil", "Edited", Optional(lastEdited))] {
            let date = value.flatMap(Self.activityDate)
            let text = date.map { abs($0.timeIntervalSinceNow) < 60 ? "Just now" : formatter.localizedString(for: $0, relativeTo: Date()) } ?? "—"
            let attachment = NSTextAttachment()
            let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            attachment.image = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.black, renderingMode: .alwaysOriginal)
            let width = max(24, label.font.pointSize + 6)
            let size = attachment.image?.size ?? CGSize(width: 1, height: 1)
            let height = width * size.height / size.width
            attachment.bounds = CGRect(x: 0, y: (label.font.capHeight - height) / 2, width: width, height: height)
            let attributed = NSMutableAttributedString(attachment: attachment)
            attributed.append(NSAttributedString(string: "  \(text)"))
            label.attributedText = attributed
            let unknown = prefix == "Seen" ? "Not yet confirmed" : "Unknown"
            label.accessibilityLabel = "\(prefix): \(date.map { DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .short) } ?? unknown)"
        }
    }

    @objc func presenceDidChange(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? Int, String(id) == pinData.id,
              let seen = notification.userInfo?["last_seen"] as? String else { return }
        activityTask?.cancel()
        activityGeneration = UUID()
        pinData.lastSeen = seen
        updateActivityLabels()
    }

    @objc func refreshVisibleActivity() {
        guard isDisplayingMachine else { return }
        refreshActivity()
    }

    func refreshActivity() {
        guard let url = URL(string: "machines/\(pinData.id)/activity", relativeTo: URL(string: flaskURL)) else { return }
        activityTask?.cancel()
        activityGeneration = UUID()
        let generation = activityGeneration
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.addAnonymousUserHeader()
        activityTask = contentSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let activity = object as? [String: Any],
                  let edited = activity["last_updated"] as? String,
                  activity.keys.contains("last_seen") else { return }
            DispatchQueue.main.async {
                guard let self = self, self.activityGeneration == generation else { return }
                self.pinData.lastSeen = activity["last_seen"] as? String
                self.lastEdited = edited
                self.updateActivityLabels()
            }
        }
        activityTask?.resume()
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: pointSize)
    }
}

private extension PinViewController {
    func layoutCoinStrip() {
        let count = pinData.numCoins
        let horizontalPadding = coinStripStack.directionalLayoutMargins.leading + coinStripStack.directionalLayoutMargins.trailing
        let width = coinStrip.bounds.width - horizontalPadding
        guard count > 0, width > 0 else { return }
        let columns = count > 4 ? 3.65 : CGFloat(count)
        let itemWidth = count < 4 ? min(count <= 2 ? 160 : 92, (width - CGFloat(count - 1) * 12) / columns)
            : (width - 36) / columns
        for constraint in coinWidthConstraints { constraint.constant = max(44, itemWidth) }
        let contentWidth = CGFloat(count) * max(44, itemWidth) + CGFloat(count - 1) * 12 + horizontalPadding
        let inset = max(0, (coinStrip.bounds.width - contentWidth) / 2)
        if coinStrip.contentInset.left != inset {
            coinStrip.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            if !coinStrip.isDragging && !coinStrip.isDecelerating {
                coinStrip.contentOffset.x = -inset
            }
        }
        updateCoinScrollHint()
    }

    func updateCoinScrollHint() {
        guard pinData.numCoins > 4 else { return }
        let atStart = coinStrip.contentOffset.x <= 1
        let atEnd = coinStrip.contentOffset.x + coinStrip.bounds.width >= coinStrip.contentSize.width - 1
        coinMoreLabel.text = atStart ? "Swipe for more designs →" : (atEnd ? "← Swipe for earlier designs" : "← More designs →")
    }

    @objc func showEditedInfo() {
        let date = Self.activityDate(lastEdited).map { DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .none) } ?? "Unknown"
        let alert = UIAlertController(title: "Last edited", message: "The machine's details were last updated on \(date).", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Edit machine details", style: .default) { [weak self] _ in
            self?.dismiss(animated: true) { [weak self] in self?.openMachineChangeRequest() }
        })
        alert.addAction(UIAlertAction(title: "Okay", style: .cancel))
        present(alert, animated: true)
    }

    func openMachineChangeRequest() {
        present(UIHostingController(rootView: MachineChangedForm(pinData: pinData, areaChoices: areaChoices)), animated: true)
    }

    @objc func showSeenInfo() {
        let date = pinData.lastSeen.flatMap(Self.activityDate).map {
            DateFormatter.localizedString(from: $0, dateStyle: .long, timeStyle: .short)
        }
        let message = date.map { "A nearby user last confirmed this machine's existence on \($0)." }
            ?? "This machine has not yet been confirmed by a nearby user."
        let alert = UIAlertController(title: "Last seen", message: message + "\n\nYou can confirm it while within 200 metres.", preferredStyle: .alert)
        let confirm = UIAlertAction(title: "Confirm it's here", style: .default) { [weak self] _ in
            self?.dismiss(animated: true) { [weak self] in self?.confirmMachinePresence() }
        }
        // Tapping starts a fresh location request; a cached fix must not lock this entry point.
        confirm.isEnabled = Int(pinData.id) != nil && presenceMonitor != nil
        alert.addAction(confirm)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

extension PinViewController {
    static func externalWebsiteTitle(for link: String) -> String {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return "No website available" }
        let name: String
        if host == "pennycollector.com" || host.hasSuffix(".pennycollector.com") { name = "PennyCollector" }
        else { name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return "\(name) (External)"
    }
}

/// The outline follows the photo's alpha mask, including irregular and rotated coins.
/// Older opaque photos use only edge-connected white background as the fallback mask.
final class CoinPreviewView: UIImageView {
    var isCollected = false {
        didSet { outlineLayer.isHidden = !isCollected; setNeedsLayout() }
    }
    override var image: UIImage? {
        didSet { cachedImage = nil; setNeedsLayout() }
    }
    private let outlineLayer = CALayer()
    private var cachedImage: UIImage?
    private var cachedSize = CGSize.zero
    private static let context = CIContext()

    override init(image: UIImage?) {
        super.init(image: image)
        clipsToBounds = false
        layer.addSublayer(outlineLayer)
        outlineLayer.isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = false
        layer.addSublayer(outlineLayer)
        outlineLayer.isHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isCollected, let image = image, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        outlineLayer.frame = bounds.insetBy(dx: -8, dy: -8)
        guard cachedImage !== image || cachedSize != bounds.size else { return }
        cachedImage = image
        cachedSize = bounds.size
        outlineLayer.contents = Self.collectionOutline(for: image, size: bounds.size)?.cgImage
        outlineLayer.contentsScale = traitCollection.displayScale
    }

    static func collectionOutline(for image: UIImage, size: CGSize) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 else { return nil }
        let padding: CGFloat = 8
        let output = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: (output.width - fitted.width) / 2, y: (output.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let rendered = UIGraphicsImageRenderer(size: output, format: format).image { _ in image.draw(in: rect) }
        guard let source = rendered.cgImage else { return nil }
        let foreground: CGImage
        if hasTransparency(image) { foreground = source }
        else { foreground = removingWhiteBackground(source) ?? source }
        let input = CIImage(cgImage: foreground)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.systemGreen.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        let colored = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": zero, "inputGVector": zero, "inputBVector": zero,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: red, y: green, z: blue, w: 0)
        ])
        let ring = colored.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 6 * format.scale])
            .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: input])
        guard let result = context.createCGImage(ring, from: input.extent) else { return nil }
        return UIImage(cgImage: result, scale: format.scale, orientation: .up)
    }

    private static func hasTransparency(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return true }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let transparent = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] < 240 }
        }
        return transparent
    }

    private static func removingWhiteBackground(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var visited = [Bool](repeating: false, count: width * height)
            var queue: [Int] = []
            func enqueue(_ index: Int) {
                guard !visited[index] else { return }
                visited[index] = true
                let offset = index * 4
                if bytes[offset + 3] < 16 || (bytes[offset] > 235 && bytes[offset + 1] > 235 && bytes[offset + 2] > 235) {
                    queue.append(index)
                }
            }
            for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
            for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
            var head = 0
            while head < queue.count {
                let index = queue[head]
                head += 1
                let offset = index * 4
                for channel in 0..<4 { bytes[offset + channel] = 0 }
                let x = index % width, y = index / width
                if x > 0 { enqueue(index - 1) }
                if x + 1 < width { enqueue(index + 1) }
                if y > 0 { enqueue(index - width) }
                if y + 1 < height { enqueue(index + width) }
            }
            return context.makeImage()
        }
    }

    /// Each preview controls orientation while the stored original stays available for zooming.
    static func orientedImage(_ image: UIImage, landscape: Bool) -> UIImage {
        guard image.size.width != image.size.height, (image.size.width > image.size.height) != landscape else { return image }
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = !hasTransparency(image)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if format.opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }

    /// Upright, text-free placeholder drawn with native vector paths.
    static let placeholder: UIImage = {
        let size = CGSize(width: 56, height: 92)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let edge = UIBezierPath(ovalIn: CGRect(x: 5, y: 4, width: 46, height: 84))
            UIColor(red: 0.76, green: 0.42, blue: 0.19, alpha: 1).setFill()
            edge.fill()
            UIColor(red: 0.43, green: 0.23, blue: 0.10, alpha: 1).setStroke()
            edge.lineWidth = 2
            edge.stroke()
            let inner = UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 36, height: 72))
            inner.lineWidth = 1
            inner.setLineDash([2, 2], count: 2, phase: 0)
            inner.stroke()
        }
    }()

    static let landscapePlaceholder = orientedImage(placeholder, landscape: true)
}

/// A vertical crop inside the horizontal gallery. Full-resolution originals remain unchanged.
final class MachinePhotoViewport: UIView, UIGestureRecognizerDelegate {
    let imageView: UIImageView
    let verticalPan = UIPanGestureRecognizer()
    private let onOpen: () -> Void
    private var verticalFraction: CGFloat = 0
    var isPanEnabled = true {
        didSet {
            verticalPan.isEnabled = isPanEnabled
            if !isPanEnabled { verticalFraction = 0 }
            updateAccessibility()
            setNeedsLayout()
        }
    }

    init(imageView: UIImageView, onOpen: @escaping () -> Void) {
        self.imageView = imageView
        self.onOpen = onOpen
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(imageView)
        verticalPan.addTarget(self, action: #selector(panPhoto(_:)))
        verticalPan.delegate = self
        addGestureRecognizer(verticalPan)
        isAccessibilityElement = true
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("Use init(imageView:onOpen:)") }

    private func updateAccessibility() {
        accessibilityTraits = isPanEnabled ? [.image, .button] : .image
        accessibilityLabel = isPanEnabled ? "Machine photo" : "Blocked machine photo"
        accessibilityHint = isPanEnabled ? "Tap to enlarge. Swipe up or down to reposition; swipe sideways for coin photos." : nil
    }

    private var fittedSize: CGSize {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }

    private var maximumOffset: CGFloat { max(0, (fittedSize.height - bounds.height) / 2) }

    func canPan(velocity: CGPoint) -> Bool {
        isPanEnabled && maximumOffset > 0.5 && abs(velocity.y) > abs(velocity.x)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === verticalPan { return canPan(velocity: verticalPan.velocity(in: self)) }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isPanEnabled else { imageView.frame = bounds; return }
        let size = fittedSize
        imageView.frame = CGRect(x: (bounds.width - size.width) / 2,
                                 y: (bounds.height - size.height) / 2 + verticalFraction * maximumOffset,
                                 width: size.width, height: size.height)
    }

    func movePhotoVertically(by translation: CGFloat) {
        guard isPanEnabled, maximumOffset > 0 else { return }
        let offset = min(max(verticalFraction * maximumOffset + translation, -maximumOffset), maximumOffset)
        verticalFraction = offset / maximumOffset
        setNeedsLayout()
        layoutIfNeeded()
    }

    @objc private func panPhoto(_ gesture: UIPanGestureRecognizer) {
        movePhotoVertically(by: gesture.translation(in: self).y)
        gesture.setTranslation(.zero, in: self)
    }

    override func accessibilityActivate() -> Bool {
        guard isPanEnabled else { return false }
        onOpen()
        return true
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let old = verticalFraction
        switch direction {
        case .up: movePhotoVertically(by: -bounds.height * 0.75)
        case .down: movePhotoVertically(by: bounds.height * 0.75)
        default: return false
        }
        guard old != verticalFraction else { return false }
        UIAccessibility.post(notification: .pageScrolled, argument: "Photo repositioned")
        return true
    }
}

extension PinViewController {
    private static let addressCountryNames: Set<String> = {
        let english = Locale(identifier: "en_US")
        let names = Locale.isoRegionCodes.flatMap { code in
            [english.localizedString(forRegionCode: code), Locale.current.localizedString(forRegionCode: code)].compactMap { $0 }
        } + ["USA", "U.S.A.", "US", "UK", "U.K.", "United States of America", "UAE",
             "England", "Scotland", "Wales", "Northern Ireland", "Czech Republic", "Turkey", "Russia"]
        // PennyCollector also uses Georgia as a US state; don't strip that address component.
        return Set(names.map { $0.lowercased() }).subtracting(["georgia"])
    }()

    static func compactAddress(_ address: String) -> String {
        var parts = address.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let last = parts.last, addressCountryNames.contains(last.lowercased()) { parts.removeLast() }
        return parts.joined(separator: ", ")
    }
}
