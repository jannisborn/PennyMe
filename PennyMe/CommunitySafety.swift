//
//  CommunitySafety.swift
//  PennyMe
//
//  Account-free safeguards for user-generated content.
//

import Foundation
import Security
import UIKit

extension Notification.Name {
    static let blockedContentDidChange = Notification.Name("PennyMeBlockedContentDidChange")
}

enum AnonymousUserID {
    private static let account = "anonymous-contributor-id"

    private static var service: String {
        return Bundle.main.bundleIdentifier ?? "PennyMe"
    }

    static func getOrCreate() -> String {
        if let existing = read(), !existing.isEmpty {
            return existing
        }

        let identifier = UUID().uuidString.lowercased()
        save(identifier)
        return identifier
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ identifier: String) {
        let data = Data(identifier.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        SecItemAdd(newItem as CFDictionary, nil)
    }
}

enum AppSession {
    static let anonymousUserID = AnonymousUserID.getOrCreate()
}

extension URLRequest {
    mutating func addAnonymousUserHeader() {
        setValue(AppSession.anonymousUserID, forHTTPHeaderField: "X-PennyMe-Anonymous-ID")
    }
}

enum CommunityTerms {
    static let version = "2026-07-22"

    // terms_of_use.md is copied into the app bundle by the Resources build phase.
    // Keeping this as the only terms source prevents the acceptance screen and the
    // published legal document from drifting apart.
    static var text: String {
        return BundledLegalDocument.text(named: "terms_of_use")
            ?? "The Terms of Use could not be loaded. Please restart PennyMe and try again."
    }
}

enum BundledLegalDocument {
    static func text(named name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else {
            assertionFailure("Missing bundled legal document: \(name).md")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

enum LegalMarkdownRenderer {
    private static let inlinePattern = "\\*\\*([^*]+)\\*\\*|\\[([^\\]]+)\\]\\(([^\\)]+)\\)"

    static func attributedText(
        from markdown: String,
        baseTextStyle: UIFont.TextStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for (index, originalLine) in lines.enumerated() {
            if originalLine.isEmpty {
                result.append(NSAttributedString(string: "\n"))
                continue
            }

            var line = originalLine
            var font = UIFont.preferredFont(forTextStyle: baseTextStyle)
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 3

            if line.hasPrefix("# ") {
                line = String(line.dropFirst(2))
                let titleFont = UIFont.preferredFont(forTextStyle: .title2)
                font = UIFont.systemFont(ofSize: titleFont.pointSize, weight: .bold)
                paragraph.paragraphSpacingBefore = 4
                paragraph.paragraphSpacing = 8
            } else if line.hasPrefix("## ") {
                line = String(line.dropFirst(3))
                font = UIFont.preferredFont(forTextStyle: .headline)
                paragraph.paragraphSpacingBefore = 5
                paragraph.paragraphSpacing = 4
            } else if line.hasPrefix("- ") {
                line = "• " + String(line.dropFirst(2))
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 16
            }

            let lineStart = result.length
            result.append(inlineText(line, font: font))
            result.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: lineStart, length: result.length - lineStart)
            )
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func inlineText(_ text: String, font: UIFont) -> NSAttributedString {
        guard let expression = try? NSRegularExpression(pattern: inlinePattern) else {
            return NSAttributedString(string: text, attributes: attributes(font: font))
        }

        let result = NSMutableAttributedString()
        let source = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                let plainRange = NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                )
                result.append(
                    NSAttributedString(
                        string: source.substring(with: plainRange),
                        attributes: attributes(font: font)
                    )
                )
            }

            if match.range(at: 1).location != NSNotFound {
                let boldFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                result.append(
                    NSAttributedString(
                        string: source.substring(with: match.range(at: 1)),
                        attributes: attributes(font: boldFont)
                    )
                )
            } else {
                let label = source.substring(with: match.range(at: 2))
                let destination = source.substring(with: match.range(at: 3))
                var linkAttributes = attributes(font: font)
                if let url = URL(string: destination) {
                    linkAttributes[.link] = url
                    linkAttributes[.foregroundColor] = UIColor.systemBlue
                    linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: label, attributes: linkAttributes))
            }
            cursor = NSMaxRange(match.range)
        }

        if cursor < source.length {
            result.append(
                NSAttributedString(
                    string: source.substring(from: cursor),
                    attributes: attributes(font: font)
                )
            )
        }
        return result
    }

    private static func attributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        return [
            .font: font,
            .foregroundColor: UIColor.label
        ]
    }
}

enum LegalLinkOpener {
    static func open(_ url: URL, from presenter: UIViewController) {
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened, url.scheme?.caseInsensitiveCompare("mailto") == .orderedSame else {
                return
            }
            let encodedAddress = String(url.absoluteString.dropFirst("mailto:".count))
                .components(separatedBy: "?")[0]
            let address = encodedAddress.removingPercentEncoding ?? encodedAddress
            DispatchQueue.main.async {
                UIPasteboard.general.string = address
                let alert = UIAlertController(
                    title: "No Mail App Available",
                    message: "The email address \(address) was copied to the clipboard.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }
}

enum CommunityTermsGate {
    private static let acceptedVersionKey = "communityTerms.acceptedVersion"

    static func start(from presenter: UIViewController, completion: @escaping () -> Void) {
        if UserDefaults.standard.string(forKey: acceptedVersionKey) == CommunityTerms.version {
            completion()
            return
        }

        let termsController = TermsGateViewController()
        termsController.onAccept = {
            UserDefaults.standard.set(CommunityTerms.version, forKey: acceptedVersionKey)
            termsController.dismiss(animated: true, completion: completion)
        }
        termsController.modalPresentationStyle = .fullScreen
        termsController.isModalInPresentation = true
        presenter.present(termsController, animated: false)
    }
}

final class TermsGateViewController: UIViewController, UITextViewDelegate {
    var onAccept: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Welcome to PennyMe"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        let summaryLabel = UILabel()
        summaryLabel.text = "Please accept our community rules. We have zero tolerance for objectionable content or abusive behavior."
        summaryLabel.font = .preferredFont(forTextStyle: .body)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.numberOfLines = 0

        let textView = UITextView()
        textView.attributedText = LegalMarkdownRenderer.attributedText(
            from: CommunityTerms.text,
            baseTextStyle: .footnote
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 1
        textView.layer.cornerRadius = 8

        let acceptButton = UIButton(type: .system)
        acceptButton.setTitle("Agree & Continue", for: .normal)
        acceptButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        acceptButton.addTarget(self, action: #selector(acceptTerms), for: .touchUpInside)
        acceptButton.accessibilityIdentifier = "communityTermsAcceptButton"

        let declineButton = UIButton(type: .system)
        declineButton.setTitle("Decline", for: .normal)
        declineButton.setTitleColor(.secondaryLabel, for: .normal)
        declineButton.addTarget(self, action: #selector(declineTerms), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [acceptButton, declineButton])
        buttons.axis = .vertical
        buttons.spacing = 8

        let stack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel, textView, buttons])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    @objc private func acceptTerms() {
        onAccept?()
    }

    @objc private func declineTerms() {
        let alert = UIAlertController(
            title: "Terms Required",
            message: "You must accept the Terms and Community Guidelines to use PennyMe.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Review Terms", style: .default))
        present(alert, animated: true)
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        LegalLinkOpener.open(url, from: self)
        return false
    }
}

enum TextModeration {
    private static let bannedWords: Set<String> = [
        "asshole", "bastard", "bitch", "cunt", "fuck", "fucking",
        "motherfucker", "naked", "nudes", "porn", "porno", "pornography",
        "pussy", "retard", "slut", "whore"
    ]

    private static let threatPhrases = [
        "attack you", "beat you", "find where you live", "hurt you",
        "i know where you live", "i will find you", "i will kill",
        "i will shoot", "i will stab", "i'll find you", "i'll kill",
        "i'll shoot", "i'll stab", "kill you", "shoot you", "stab you"
    ]

    static func blockReason(_ values: String...) -> String? {
        let normalized = values.joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let tokens = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        if tokens.contains(where: { bannedWords.contains($0) }) {
            return "This text contains language that is not allowed. Please edit it and try again."
        }
        if threatPhrases.contains(where: { normalized.contains($0) }) {
            return "This text appears to contain a threat. Please edit it and try again."
        }
        return nil
    }
}

struct BlockedContentSnapshot {
    fileprivate let contributorIDs: Set<String>
    fileprivate let contentKeys: Set<String>

    func isBlocked(contributorID: String?, contentKey: String) -> Bool {
        if contentKeys.contains(contentKey) {
            return true
        }
        guard let contributorID = contributorID else { return false }
        return contributorIDs.contains(contributorID)
    }
}

final class BlockedContributorsStore {
    private let defaults: UserDefaults
    private let contributorsKey = "moderation.blockedContributorIDs"
    private let contentKey = "moderation.blockedContentKeys"
    private let contentOwnersKey = "moderation.blockedContentOwners"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func block(contributorID: String?, contentKey: String) {
        var content = blockedContentKeys()
        content.insert(contentKey)
        defaults.set(Array(content), forKey: self.contentKey)

        guard let contributorID = contributorID, !contributorID.isEmpty else { return }
        var contributors = blockedContributorIDs()
        contributors.insert(contributorID)
        defaults.set(Array(contributors), forKey: contributorsKey)

        var owners = blockedContentOwners()
        owners[contentKey] = contributorID
        defaults.set(owners, forKey: contentOwnersKey)
    }

    func isBlocked(contributorID: String?, contentKey: String) -> Bool {
        return snapshot().isBlocked(
            contributorID: contributorID,
            contentKey: contentKey
        )
    }

    func snapshot() -> BlockedContentSnapshot {
        return BlockedContentSnapshot(
            contributorIDs: blockedContributorIDs(),
            contentKeys: blockedContentKeys()
        )
    }

    func blockedContributorIDs() -> Set<String> {
        return Set(defaults.stringArray(forKey: contributorsKey) ?? [])
    }

    func blockedContentKeys() -> Set<String> {
        return Set(defaults.stringArray(forKey: contentKey) ?? [])
    }

    func unattributedContentKeys() -> Set<String> {
        return blockedContentKeys().subtracting(blockedContentOwners().keys)
    }

    func unblock(contributorID: String) {
        var contributors = blockedContributorIDs()
        contributors.remove(contributorID)
        defaults.set(Array(contributors), forKey: contributorsKey)

        var owners = blockedContentOwners()
        let associatedContent = owners.compactMap { key, owner in
            owner == contributorID ? key : nil
        }
        associatedContent.forEach { owners.removeValue(forKey: $0) }
        defaults.set(owners, forKey: contentOwnersKey)

        var content = blockedContentKeys()
        content.subtract(associatedContent)
        defaults.set(Array(content), forKey: self.contentKey)
        NotificationCenter.default.post(name: .blockedContentDidChange, object: nil)
    }

    func unblock(contentKey: String) {
        var content = blockedContentKeys()
        content.remove(contentKey)
        defaults.set(Array(content), forKey: self.contentKey)

        var owners = blockedContentOwners()
        owners.removeValue(forKey: contentKey)
        defaults.set(owners, forKey: contentOwnersKey)
        NotificationCenter.default.post(name: .blockedContentDidChange, object: nil)
    }

    func unblockAll() {
        defaults.removeObject(forKey: contributorsKey)
        defaults.removeObject(forKey: contentKey)
        defaults.removeObject(forKey: contentOwnersKey)
        NotificationCenter.default.post(name: .blockedContentDidChange, object: nil)
    }

    private func blockedContentOwners() -> [String: String] {
        return defaults.dictionary(forKey: contentOwnersKey) as? [String: String] ?? [:]
    }
}

final class LegalDocumentViewController: UIViewController, UITextViewDelegate {
    private let documentName: String
    private let documentTitle: String

    init(documentName: String, title: String) {
        self.documentName = documentName
        self.documentTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = documentTitle
        view.backgroundColor = .systemBackground

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16)
        let markdown = BundledLegalDocument.text(named: documentName)
            ?? "This document is temporarily unavailable."
        textView.attributedText = LegalMarkdownRenderer.attributedText(
            from: markdown,
            baseTextStyle: .body
        )
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        LegalLinkOpener.open(url, from: self)
        return false
    }
}

final class BlockedContentViewController: UITableViewController {
    private enum Entry {
        case contributor(String)
        case unattributedContent(String)
    }

    private let store = BlockedContributorsStore()
    private var entries: [Entry] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Blocked content"
        tableView.rowHeight = 58
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Unblock All",
            style: .plain,
            target: self,
            action: #selector(confirmUnblockAll)
        )
        reloadEntries()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let identifier = "BlockedContentCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let entry = entries[indexPath.row]
        switch entry {
        case .contributor(let identifier):
            cell.textLabel?.text = "Anonymous contributor"
            cell.detailTextLabel?.text = abbreviated(identifier)
        case .unattributedContent(let key):
            cell.textLabel?.text = "Older unattributed content"
            cell.detailTextLabel?.text = key
        }
        cell.selectionStyle = .none

        let button = UIButton(type: .system)
        button.setTitle("Unblock", for: .normal)
        button.sizeToFit()
        button.tag = indexPath.row
        button.addTarget(self, action: #selector(unblockEntry(_:)), for: .touchUpInside)
        cell.accessoryView = button
        return cell
    }

    @objc private func unblockEntry(_ sender: UIButton) {
        guard entries.indices.contains(sender.tag) else { return }
        switch entries[sender.tag] {
        case .contributor(let identifier):
            store.unblock(contributorID: identifier)
        case .unattributedContent(let key):
            store.unblock(contentKey: key)
        }
        reloadEntries()
    }

    @objc private func confirmUnblockAll() {
        guard !entries.isEmpty else { return }
        let alert = UIAlertController(
            title: "Unblock All Content?",
            message: "All locally blocked contributors and content will become visible again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unblock All", style: .destructive) { _ in
            self.store.unblockAll()
            self.reloadEntries()
        })
        present(alert, animated: true)
    }

    private func reloadEntries() {
        entries = store.blockedContributorIDs().sorted().map(Entry.contributor)
        entries += store.unattributedContentKeys().sorted().map(Entry.unattributedContent)
        navigationItem.rightBarButtonItem?.isEnabled = !entries.isEmpty
        tableView.backgroundView = entries.isEmpty ? emptyStateLabel() : nil
        tableView.reloadData()
    }

    private func emptyStateLabel() -> UILabel {
        let label = UILabel()
        label.text = "No contributors or content are blocked on this device."
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    private func abbreviated(_ identifier: String) -> String {
        guard identifier.count > 12 else { return identifier }
        return "ID \(identifier.prefix(8))…\(identifier.suffix(4))"
    }
}
