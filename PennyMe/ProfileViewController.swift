//
//  ProfileViewController.swift
//  PennyMe
//

import UIKit

@available(iOS 15.0, *)
final class ProfileViewController: UIViewController, UIPageViewControllerDataSource,
    UIPageViewControllerDelegate
{
    private let sourceStoryboard: UIStoryboard
    private let artworks: [Artwork]
    private let selector = UISegmentedControl(items: ["Statistics", "Contributions"])
    private let pager = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal
    )
    private lazy var pages: [UIViewController] = {
        guard let statistics = sourceStoryboard.instantiateViewController(
            withIdentifier: "StatisticsViewController"
        ) as? StatisticsViewController else {
            fatalError("StatisticsViewController is missing from Main.storyboard")
        }
        return [
            statistics,
            ContributionsViewController(storyboard: sourceStoryboard, artworks: artworks)
        ]
    }()
    private var selectedPage = 0

    init(storyboard: UIStoryboard, artworks: [Artwork]) {
        sourceStoryboard = storyboard
        self.artworks = artworks
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Profile"
        view.backgroundColor = .systemBackground

        selector.translatesAutoresizingMaskIntoConstraints = false
        selector.selectedSegmentIndex = 0
        selector.addTarget(self, action: #selector(selectPage), for: .valueChanged)
        selector.accessibilityLabel = "Profile section"
        view.addSubview(selector)

        addChild(pager)
        pager.dataSource = self
        pager.delegate = self
        pager.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.setViewControllers([pages[0]], direction: .forward, animated: false)

        NSLayoutConstraint.activate([
            selector.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            selector.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            selector.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            pager.view.topAnchor.constraint(equalTo: selector.bottomAnchor, constant: 8),
            pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func selectPage() {
        let newPage = selector.selectedSegmentIndex
        guard newPage != selectedPage else { return }
        let direction: UIPageViewController.NavigationDirection =
            newPage > selectedPage ? .forward : .reverse
        selectedPage = newPage
        pager.setViewControllers([pages[newPage]], direction: direction, animated: true)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }), index > 0 else {
            return nil
        }
        return pages[index - 1]
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let index = pages.firstIndex(where: { $0 === viewController }),
              index + 1 < pages.count else {
            return nil
        }
        return pages[index + 1]
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed, let visible = pageViewController.viewControllers?.first,
              let index = pages.firstIndex(where: { $0 === visible }) else {
            return
        }
        selectedPage = index
        selector.selectedSegmentIndex = index
    }
}

private struct ContributionsResponse: Decodable {
    let changeRequests: [Contribution]
    let ugcReports: [Contribution]?

    enum CodingKeys: String, CodingKey {
        case changeRequests = "change_requests"
        case ugcReports = "ugc_reports"
    }
}

private struct Contribution: Decodable {
    let machineID: Int?
    let changeType: String
    let machineName: String?
    let submittedAt: String
    let reviewedAt: String?
    let status: String
    let rejectionReason: String?
    let changedFields: [ChangedField]
    var isUGCReport: Bool { changeType == "ugc_report" }

    enum CodingKeys: String, CodingKey {
        case status
        case machineID = "machine_id"
        case changeType = "change_type"
        case machineName = "machine_name"
        case submittedAt = "submitted_at"
        case reviewedAt = "reviewed_at"
        case rejectionReason = "rejection_reason"
        case changedFields = "changed_fields"
    }
}

private struct ChangedField: Decodable {
    let label: String
    let oldValue: String?
    let newValue: String

    enum CodingKeys: String, CodingKey {
        case label
        case oldValue = "old_value"
        case newValue = "new_value"
    }
}

enum ContributionDiff {
    struct Segments: Equatable {
        let prefix: String
        let removed: String
        let added: String
        let suffix: String
    }

    static func segments(
        old: String,
        new: String,
        context: Int = 14
    ) -> Segments {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldCharacters.count - prefix,
              suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - suffix - 1]
                == newCharacters[newCharacters.count - suffix - 1] {
            suffix += 1
        }

        guard prefix < oldCharacters.count || prefix < newCharacters.count else {
            let start = max(0, oldCharacters.count - context * 2)
            return Segments(
                prefix: (start > 0 ? "…" : "") + String(oldCharacters[start...]),
                removed: "",
                added: "",
                suffix: ""
            )
        }

        let prefixStart = max(0, prefix - context)
        let suffixStart = oldCharacters.count - suffix
        let suffixEnd = min(oldCharacters.count, suffixStart + context)
        return Segments(
            prefix: (prefixStart > 0 ? "…" : "")
                + String(oldCharacters[prefixStart ..< prefix]),
            removed: String(oldCharacters[prefix ..< oldCharacters.count - suffix]),
            added: String(newCharacters[prefix ..< newCharacters.count - suffix]),
            suffix: String(oldCharacters[suffixStart ..< suffixEnd])
                + (suffixEnd < oldCharacters.count ? "…" : "")
        )
    }

    static func visibleChange(_ value: String) -> String {
        guard !value.isEmpty, value.allSatisfy(\.isWhitespace) else { return value }
        return value.map { character in
            switch character {
            case " ": return "␠"
            case "\t": return "⇥"
            case "\n": return "↵"
            default: return String(character)
            }
        }.joined()
    }
}

@available(iOS 15.0, *)
private final class ContributionCell: UITableViewCell {
    private let titleLine = UILabel()
    private let fieldsLabel = UILabel()
    private let statusButton = UIButton(type: .system)
    private var onStatusTap: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        titleLine.translatesAutoresizingMaskIntoConstraints = false
        titleLine.numberOfLines = 1
        titleLine.adjustsFontForContentSizeCategory = true
        fieldsLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldsLabel.numberOfLines = 0
        fieldsLabel.adjustsFontForContentSizeCategory = true
        statusButton.translatesAutoresizingMaskIntoConstraints = false
        statusButton.addTarget(self, action: #selector(showStatusDetails), for: .touchUpInside)
        statusButton.accessibilityHint = "Show review status details"

        contentView.addSubview(titleLine)
        contentView.addSubview(fieldsLabel)
        contentView.addSubview(statusButton)
        NSLayoutConstraint.activate([
            statusButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            statusButton.widthAnchor.constraint(equalToConstant: 44),
            statusButton.heightAnchor.constraint(equalToConstant: 44),
            titleLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLine.trailingAnchor.constraint(equalTo: statusButton.leadingAnchor, constant: -8),
            fieldsLabel.topAnchor.constraint(equalTo: titleLine.bottomAnchor, constant: 3),
            fieldsLabel.leadingAnchor.constraint(equalTo: titleLine.leadingAnchor),
            fieldsLabel.trailingAnchor.constraint(equalTo: statusButton.leadingAnchor, constant: -8),
            fieldsLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        date: String,
        fields: [ChangedField],
        status: String,
        isUGCReport: Bool,
        rejectionReason: String?,
        onStatusTap: @escaping () -> Void
    ) {
        let heading = NSMutableAttributedString()
        if isUGCReport,
           let icon = UIImage(systemName: "exclamationmark.circle.fill")?.withTintColor(
               .systemOrange,
               renderingMode: .alwaysOriginal
           ) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            attachment.bounds = CGRect(x: 0, y: -2, width: 16, height: 16)
            heading.append(NSAttributedString(attachment: attachment))
            heading.append(NSAttributedString(string: " "))
        }
        heading.append(
            NSAttributedString(
                string: title,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .headline),
                    .foregroundColor: UIColor.label
                ]
            )
        )
        heading.append(
            NSAttributedString(
                string: " (\(date))",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.secondaryLabel
                ]
            )
        )
        titleLine.attributedText = heading
        fieldsLabel.attributedText = fieldText(fields, showsDiff: !isUGCReport)
        self.onStatusTap = onStatusTap

        let color: UIColor
        let background: UIColor
        let symbol: String
        switch status {
        case "approved":
            color = .systemGreen
            background = .systemGreen.withAlphaComponent(0.08)
            symbol = "checkmark.circle.fill"
        case "rejected":
            color = .systemRed
            background = .systemRed.withAlphaComponent(0.08)
            symbol = "xmark.circle.fill"
        default:
            color = .label
            background = .systemYellow.withAlphaComponent(0.14)
            symbol = "clock.fill"
        }
        let imageConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        statusButton.setImage(UIImage(systemName: symbol, withConfiguration: imageConfiguration), for: .normal)
        statusButton.tintColor = color
        statusButton.accessibilityLabel = "Status: \(status)"
        contentView.backgroundColor = background
        let spokenChanges = fields.map { field in
            if let oldValue = field.oldValue {
                return "\(field.label), changed from \(oldValue) to \(field.newValue)"
            }
            return "\(field.label), added \(field.newValue)"
        }.joined(separator: ", ")
        let reasonText = rejectionReason.map { ", reason \($0)" } ?? ""
        let kindText = isUGCReport ? "UGC report, " : ""
        accessibilityLabel = "\(kindText)\(title), \(date), status \(status)\(reasonText), \(spokenChanges)"
    }

    @objc private func showStatusDetails() {
        onStatusTap?()
    }

    private func fieldText(
        _ fields: [ChangedField],
        showsDiff: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, field) in fields.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            result.append(
                NSAttributedString(
                    string: field.label + "  ",
                    attributes: [
                        .font: UIFont.systemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                            weight: .semibold
                        ),
                        .foregroundColor: UIColor.secondaryLabel
                    ]
                )
            )
            if !showsDiff {
                result.append(
                    NSAttributedString(
                        string: field.newValue,
                        attributes: [
                            .font: UIFont.preferredFont(forTextStyle: .subheadline),
                            .foregroundColor: UIColor.label
                        ]
                    )
                )
            } else if let oldValue = field.oldValue {
                appendInlineDiff(old: oldValue, new: field.newValue, to: result)
            } else {
                appendAddition(field.newValue, to: result)
            }
        }
        return result
    }

    private func appendInlineDiff(
        old: String,
        new: String,
        to result: NSMutableAttributedString
    ) {
        let segments = ContributionDiff.segments(old: old, new: new)
        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: UIColor.label
        ]
        result.append(NSAttributedString(string: segments.prefix, attributes: normalAttributes))
        if !segments.removed.isEmpty {
            result.append(
                NSAttributedString(
                    string: ContributionDiff.visibleChange(segments.removed),
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .subheadline),
                        .foregroundColor: UIColor.systemRed,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue
                    ]
                )
            )
        }
        if !segments.removed.isEmpty, !segments.added.isEmpty {
            result.append(NSAttributedString(string: " ", attributes: normalAttributes))
        }
        if !segments.added.isEmpty {
            result.append(
                NSAttributedString(
                    string: ContributionDiff.visibleChange(segments.added),
                    attributes: [
                        .font: UIFont.boldSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                        ),
                        .foregroundColor: UIColor.systemGreen
                    ]
                )
            )
        }
        result.append(NSAttributedString(string: segments.suffix, attributes: normalAttributes))
    }

    private func appendAddition(_ value: String, to result: NSMutableAttributedString) {
        result.append(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: UIFont.boldSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize
                    ),
                    .foregroundColor: UIColor.systemGreen
                ]
            )
        )
    }
}

@available(iOS 15.0, *)
private final class ContributionGroupHeader: UITableViewHeaderFooterView {
    private let titleLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var onToggle: (() -> Void)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.font = UIFont.systemFont(
            ofSize: titleLabel.font.pointSize,
            weight: .semibold
        )
        titleLabel.textColor = .secondaryLabel
        titleLabel.adjustsFontForContentSizeCategory = true

        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        toggleButton.tintColor = .secondaryLabel
        toggleButton.accessibilityHint = "Expand or collapse contributions"

        contentView.addSubview(titleLabel)
        contentView.addSubview(toggleButton)
        contentView.backgroundColor = .systemGroupedBackground
        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            toggleButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: 28),
            toggleButton.heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, expanded: Bool, onToggle: @escaping () -> Void) {
        titleLabel.text = title
        let symbol = expanded ? "chevron.down" : "chevron.right"
        let configuration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        toggleButton.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
        toggleButton.accessibilityLabel = expanded ? "Collapse \(title)" : "Expand \(title)"
        self.onToggle = onToggle
    }

    @objc private func toggle() {
        onToggle?()
    }
}

@available(iOS 15.0, *)
private final class ContributionsViewController: UITableViewController {
    private enum GroupKey: CaseIterable, Hashable {
        case today
        case yesterday
        case lastWeek
        case lastMonth
        case older

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .lastWeek: return "Last week"
            case .lastMonth: return "Last month"
            case .older: return "Older than a month"
            }
        }
    }

    private struct ContributionGroup {
        let key: GroupKey
        let contributions: [Contribution]
    }

    private let cellIdentifier = "ContributionCell"
    private let headerIdentifier = "ContributionGroupHeader"
    private let sourceStoryboard: UIStoryboard
    private let artworks: [Artwork]
    private var contributions: [Contribution] = []
    private var groups: [ContributionGroup] = []
    private var collapsedGroups = Set<GroupKey>()
    private var requestTask: URLSessionDataTask?

    init(storyboard: UIStoryboard, artworks: [Artwork]) {
        sourceStoryboard = storyboard
        self.artworks = artworks
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.register(ContributionCell.self, forCellReuseIdentifier: cellIdentifier)
        tableView.register(
            ContributionGroupHeader.self,
            forHeaderFooterViewReuseIdentifier: headerIdentifier
        )
        tableView.sectionHeaderHeight = 28
        tableView.estimatedSectionHeaderHeight = 28

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        loadContributions()
    }

    deinit {
        requestTask?.cancel()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !collapsedGroups.contains(groups[section].key) else { return 0 }
        return groups[section].contributions.count
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        groups.count
    }

    override func tableView(
        _ tableView: UITableView,
        viewForHeaderInSection section: Int
    ) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: headerIdentifier
        ) as? ContributionGroupHeader else {
            return nil
        }
        let group = groups[section]
        header.configure(
            title: group.key.title,
            expanded: !collapsedGroups.contains(group.key),
            onToggle: { [weak self] in
                self?.toggleGroup(group.key)
            }
        )
        return header
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: cellIdentifier,
            for: indexPath
        ) as? ContributionCell else {
            return UITableViewCell()
        }
        let contribution = groups[indexPath.section].contributions[indexPath.row]
        cell.configure(
            title: displayTitle(for: contribution),
            date: formattedDate(contribution.submittedAt),
            fields: contribution.changedFields,
            status: contribution.status,
            isUGCReport: contribution.isUGCReport,
            rejectionReason: contribution.rejectionReason,
            onStatusTap: { [weak self] in
                self?.showStatus(for: contribution)
            }
        )
        cell.selectionStyle = artwork(for: contribution) == nil ? .none : .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let artwork = artwork(for: groups[indexPath.section].contributions[indexPath.row]),
              let pinView = sourceStoryboard.instantiateViewController(
                withIdentifier: "PinViewController"
              ) as? PinViewController else {
            return
        }
        pinView.pinData = artwork
        navigationController?.pushViewController(pinView, animated: true)
    }

    private func toggleGroup(_ key: GroupKey) {
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
        guard let section = groups.firstIndex(where: { $0.key == key }) else { return }
        tableView.reloadSections(IndexSet(integer: section), with: .automatic)
    }

    private func showStatus(for contribution: Contribution) {
        var message = statusDate(for: contribution)
        if contribution.status == "rejected",
           let reason = contribution.rejectionReason,
           !reason.isEmpty {
            message += "\nReason: \(reason)"
        }
        let alert = UIAlertController(
            title: contribution.status.capitalized,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func refresh() {
        loadContributions()
    }

    private func loadContributions() {
        requestTask?.cancel()
        guard let url = URL(string: flaskURL + "change_requests") else {
            showMessage("Could not create the contributions request.")
            return
        }

        if contributions.isEmpty {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            tableView.backgroundView = spinner
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.addAnonymousUserHeader()
        requestTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.refreshControl?.endRefreshing()
                guard error == nil,
                      let response = response as? HTTPURLResponse,
                      200 ..< 300 ~= response.statusCode,
                      let data = data,
                      let decoded = try? JSONDecoder().decode(ContributionsResponse.self, from: data)
                else {
                    if self.contributions.isEmpty {
                        self.showMessage("Could not load contributions. Pull down to try again.")
                    }
                    return
                }

                self.contributions = (
                    decoded.changeRequests + (decoded.ugcReports ?? [])
                ).sorted {
                    (self.parseDate($0.submittedAt) ?? .distantPast)
                        > (self.parseDate($1.submittedAt) ?? .distantPast)
                }
                self.groups = self.makeGroups(from: self.contributions)
                self.tableView.backgroundView = self.contributions.isEmpty
                    ? self.messageLabel("No contributions from this device yet.")
                    : nil
                self.tableView.reloadData()
            }
        }
        requestTask?.resume()
    }

    private func makeGroups(from contributions: [Contribution]) -> [ContributionGroup] {
        let grouped = Dictionary(grouping: contributions, by: groupKey(for:))
        return GroupKey.allCases.compactMap { key in
            guard let contributions = grouped[key], !contributions.isEmpty else { return nil }
            return ContributionGroup(key: key, contributions: contributions)
        }
    }

    private func groupKey(for contribution: Contribution) -> GroupKey {
        guard let date = parseDate(contribution.submittedAt) else { return .older }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: today)!
        let lastMonth = calendar.date(byAdding: .day, value: -30, to: today)!

        if date >= today { return .today }
        if date >= yesterday { return .yesterday }
        if date >= lastWeek { return .lastWeek }
        if date >= lastMonth { return .lastMonth }
        return .older
    }

    private func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return fractional.date(from: value) ?? standard.date(from: value)
    }

    private func artwork(for contribution: Contribution) -> Artwork? {
        guard let machineID = contribution.machineID else { return nil }
        return artworks.first { $0.id == String(machineID) }
    }

    private func displayTitle(for contribution: Contribution) -> String {
        let title: String
        if contribution.changeType == "create" {
            title = contribution.machineName ?? "New machine"
        } else {
            title = contribution.machineName ?? artwork(for: contribution)?.title ?? "Machine"
        }
        guard title.count > 20 else { return title }
        return "\(title.prefix(15))...\(title.suffix(5))"
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = parseDate(value) else {
            return value
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yy, ha"
        return formatter.string(from: date).lowercased()
    }

    private func statusDate(for contribution: Contribution) -> String {
        if contribution.status != "pending", let reviewedAt = contribution.reviewedAt {
            return formattedDate(reviewedAt)
        }
        return formattedDate(contribution.submittedAt)
    }

    private func showMessage(_ text: String) {
        refreshControl?.endRefreshing()
        tableView.backgroundView = messageLabel(text)
    }

    private func messageLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }
}
