//
//  PennyMeTests.swift
//  PennyMeTests
//
//  Created by Jannis Born on 11.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import XCTest
import UIKit
import SwiftUI
import MapKit
@testable import PennyMe

class PennyMeTests: XCTestCase {

    @MainActor
    func testContributionHeadersGrowForLargeTextAndKeepTheirToggleWorking() throws {
        let controller = ContributionHeaderLayoutTestController(style: .plain)
        let parent = UIViewController()
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = parent
        parent.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor)
        ])
        controller.didMove(toParent: parent)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        var standardHeight: CGFloat = 0
        var standardFont: CGFloat = 0
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            for size in [CGSize(width: 320, height: 568), CGSize(width: 667, height: 320),
                         CGSize(width: 375, height: 480), CGSize(width: 1024, height: 768)] {
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                controller.tableView.reloadData()
                controller.tableView.setContentOffset(CGPoint(x: 0, y: -controller.tableView.adjustedContentInset.top), animated: false)
                controller.tableView.layoutIfNeeded()
                let header = try XCTUnwrap(controller.tableView.headerView(forSection: 0))
                let label = try XCTUnwrap(header.contentView.subviews.compactMap { $0 as? UILabel }.first)
                let toggle = try XCTUnwrap(header.contentView.subviews.compactMap { $0 as? UIButton }.first)
                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height)
                for view in [label, toggle] {
                    XCTAssertFalse(view.hasAmbiguousLayout)
                    XCTAssertTrue(header.contentView.bounds.insetBy(dx: -1, dy: -1).contains(view.frame))
                }
                XCTAssertGreaterThanOrEqual(toggle.bounds.width, 44)
                XCTAssertGreaterThanOrEqual(toggle.bounds.height, 44)
                if size.width == 320 {
                    if category == .large {
                        standardHeight = header.bounds.height
                        standardFont = label.font.pointSize
                    } else {
                        XCTAssertGreaterThan(header.bounds.height, standardHeight)
                        XCTAssertGreaterThan(label.font.pointSize, standardFont)
                    }
                }
                toggle.sendActions(for: .touchUpInside)
                controller.tableView.layoutIfNeeded()
                XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 0)
                let collapsedHeader = try XCTUnwrap(controller.tableView.headerView(forSection: 0))
                let expand = try XCTUnwrap(collapsedHeader.contentView.subviews.compactMap { $0 as? UIButton }.first)
                XCTAssertTrue(expand.accessibilityLabel?.hasPrefix("Expand") == true)
                expand.sendActions(for: .touchUpInside)
                controller.tableView.layoutIfNeeded()
                XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
            }
        }
    }

    @MainActor
    func testBlockedContentRowsGrowWithoutClippingAndUnblockTheSelectedEntry() throws {
        let suite = "BlockedContentLayoutTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = BlockedContributorsStore(defaults: defaults)
        let contributor = "test-contributor-12345678"
        let legacyKey = "123456789:image:coin_123456789"
        store.block(contributorID: contributor, contentKey: "42:image:machine")
        store.block(contributorID: nil, contentKey: legacyKey)
        let controller = BlockedContentViewController(store: store)
        let parent = UIViewController()
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = parent
        parent.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor)
        ])
        controller.didMove(toParent: parent)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        var standardHeight: CGFloat = 0
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            for size in [CGSize(width: 320, height: 568), CGSize(width: 667, height: 320),
                         CGSize(width: 375, height: 480), CGSize(width: 1024, height: 768)] {
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                controller.tableView.reloadData()
                controller.tableView.layoutIfNeeded()
                for rowIndex in 0..<2 {
                    let index = IndexPath(row: rowIndex, section: 0)
                    controller.tableView.scrollToRow(at: index, at: .middle, animated: false)
                    controller.tableView.layoutIfNeeded()
                    let cell = try XCTUnwrap(controller.tableView.cellForRow(at: index))
                    let row = try XCTUnwrap(cell.contentView.subviews.compactMap { $0 as? UIStackView }.first)
                    let labels = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? UIStackView }.first)
                    let button = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? UIButton }.first)
                    XCTAssertEqual(row.axis, category.isAccessibilityCategory ? .vertical : .horizontal)
                    for label in labels.arrangedSubviews.compactMap({ $0 as? UILabel }) {
                        let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                        XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height)
                        XCTAssertFalse(label.hasAmbiguousLayout, "Row \(rowIndex), \(size), \(category)")
                    }
                    for view in [labels, button] {
                        XCTAssertTrue(row.bounds.insetBy(dx: -1, dy: -1).contains(view.frame))
                    }
                    XCTAssertTrue(cell.contentView.bounds.insetBy(dx: -1, dy: -1).contains(row.frame))
                    XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
                    let title = try XCTUnwrap(button.titleLabel)
                    XCTAssertTrue(button.bounds.insetBy(dx: -1, dy: -1).contains(title.frame))
                    let actionFrame = button.convert(button.bounds, to: controller.tableView)
                    controller.tableView.scrollRectToVisible(actionFrame, animated: false)
                    XCTAssertTrue(controller.tableView.bounds.inset(by: controller.tableView.adjustedContentInset)
                        .insetBy(dx: -1, dy: -1).contains(actionFrame), "Unblock must remain reachable even when a row is taller than the screen")
                    if size.width == 320 && rowIndex == 0 {
                        if category == .large { standardHeight = cell.bounds.height }
                        else { XCTAssertGreaterThan(cell.bounds.height, standardHeight) }
                    }
                    if size.width == 320 && rowIndex == 1 {
                        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        })
                        attachment.name = "Blocked-content-\(category.rawValue)-320"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
        let firstIndex = IndexPath(row: 0, section: 0)
        controller.tableView.scrollToRow(at: firstIndex, at: .top, animated: false)
        controller.tableView.layoutIfNeeded()
        let firstCell = try XCTUnwrap(controller.tableView.cellForRow(at: firstIndex))
        let firstRow = try XCTUnwrap(firstCell.contentView.subviews.compactMap { $0 as? UIStackView }.first)
        let unblock = try XCTUnwrap(firstRow.arrangedSubviews.compactMap { $0 as? UIButton }.first)
        unblock.sendActions(for: .touchUpInside)
        XCTAssertFalse(store.blockedContributorIDs().contains(contributor))
        XCTAssertTrue(store.blockedContentKeys().contains(legacyKey))
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 1)
    }

    @MainActor
    func testCommunityTermsStayReachableOnShortScreensAndWithLargeText() throws {
        let controller = TermsGateViewController()
        let parent = UIViewController()
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = parent
        parent.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor)
        ])
        controller.didMove(toParent: parent)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIScrollView }.first)
        let stack = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIStackView }.first)
        let text = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UITextView }.first)
        let buttons = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UIStackView }.first)
        let actions = buttons.arrangedSubviews.compactMap { $0 as? UIButton }
        let originalTerms = text.attributedText.string
        var standardFontSize: CGFloat = 0
        var acceptances = 0
        controller.onAccept = { acceptances += 1 }

        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            for size in [CGSize(width: 320, height: 568), CGSize(width: 667, height: 320),
                         CGSize(width: 375, height: 480), CGSize(width: 1024, height: 768)] {
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                XCTAssertEqual(scroll.frame, controller.view.safeAreaLayoutGuide.layoutFrame)
                XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 1)
                let contentBounds = CGRect(origin: .zero, size: scroll.contentSize).insetBy(dx: -1, dy: -1)
                for view in stack.arrangedSubviews {
                    XCTAssertFalse(view.hasAmbiguousLayout, "\(size), \(category)")
                    XCTAssertTrue(contentBounds.contains(view.convert(view.bounds, to: scroll)))
                    if let label = view as? UILabel {
                        let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                        XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height, "Introductory text must not be clipped")
                    }
                }
                XCTAssertEqual(text.attributedText.string, originalTerms)
                XCTAssertFalse(text.isEditable)
                XCTAssertTrue(text.isSelectable)
                XCTAssertGreaterThanOrEqual(text.bounds.height, 220)
                let endOfTerms = text.caretRect(for: text.endOfDocument)
                text.scrollRectToVisible(endOfTerms, animated: false)
                XCTAssertTrue(text.bounds.insetBy(dx: -1, dy: -1).contains(endOfTerms), "The end of the legal document must be reachable")

                let buttonFrame = buttons.convert(buttons.bounds, to: scroll)
                scroll.scrollRectToVisible(buttonFrame.insetBy(dx: 0, dy: -4), animated: false)
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(buttonFrame), "Both acceptance choices must be reachable")
                for button in actions {
                    XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
                    let label = try XCTUnwrap(button.titleLabel)
                    let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                    XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height)
                    XCTAssertTrue(button.bounds.insetBy(dx: -1, dy: -1).contains(label.frame), "Button titles must fit")
                }
                if size.height == 320 {
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                }
                if size.width == 320 {
                    let font = try XCTUnwrap(text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
                    if category == .large {
                        standardFontSize = font.pointSize
                    } else {
                        XCTAssertGreaterThan(font.pointSize, standardFontSize, "Legal text must scale with the screen's text size")
                    }
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = "Community-terms-\(category.rawValue)-320"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        XCTAssertEqual(acceptances, 0, "Layout and scrolling must not accept the terms")
        let accept = try XCTUnwrap(actions.first { $0.accessibilityIdentifier == "communityTermsAcceptButton" })
        accept.sendActions(for: .touchUpInside)
        XCTAssertEqual(acceptances, 1)
    }

    @MainActor
    func testLegalMarkdownScalesWithoutLosingLinksOrFormatting() throws {
        let markdown = "# Terms\n\n## Rules\n\nPlease accept **these terms**. Contact [support](mailto:support@example.com)."
        let standard = LegalMarkdownRenderer.attributedText(from: markdown, baseTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let enlarged = LegalMarkdownRenderer.attributedText(from: markdown, baseTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertEqual(standard.string, enlarged.string)
        for phrase in ["Terms", "Rules", "Please", "these terms"] {
            let index = (standard.string as NSString).range(of: phrase).location
            let before = try XCTUnwrap(standard.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
            let after = try XCTUnwrap(enlarged.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
            XCTAssertGreaterThan(after.pointSize, before.pointSize, phrase)
        }
        let linkIndex = (enlarged.string as NSString).range(of: "support").location
        XCTAssertEqual((enlarged.attribute(.link, at: linkIndex, effectiveRange: nil) as? URL)?.absoluteString,
                       "mailto:support@example.com")
    }

    @MainActor
    func testPhotoViewerFitsAndCentersDifferentImageShapesAfterLayout() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ZoomViewController.self))
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for imageSize in [CGSize(width: 1200, height: 800), CGSize(width: 800, height: 1200),
                          CGSize(width: 800, height: 800), CGSize(width: 40, height: 20),
                          CGSize(width: 2000, height: 200)] {
            let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: imageSize))
                UIColor.systemYellow.setFill()
                context.fill(CGRect(x: 0, y: 0, width: imageSize.width / 2, height: imageSize.height / 2))
            }
            let controller = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "ZoomViewController") as? ZoomViewController)
            controller.image = image
            let navigation = UINavigationController(rootViewController: controller)
            window.rootViewController = navigation
            window.makeKeyAndVisible()
            for size in [CGSize(width: 320, height: 568), CGSize(width: 667, height: 375),
                         CGSize(width: 1024, height: 768), CGSize(width: 375, height: 768)] {
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                let scroll = try XCTUnwrap(controller.scrollView)
                let expectedFit = min(scroll.bounds.width / imageSize.width, scroll.bounds.height / imageSize.height)
                XCTAssertEqual(scroll.minimumZoomScale, expectedFit, accuracy: 0.001)
                XCTAssertEqual(scroll.maximumZoomScale, expectedFit * 4, accuracy: 0.001)
                XCTAssertEqual(scroll.zoomScale, expectedFit, accuracy: 0.001)
                XCTAssertEqual(controller.bigImageView.bounds.size, imageSize)
                XCTAssertTrue(controller.bigImageView.superview === scroll)
                XCTAssertFalse(scroll.hasAmbiguousLayout)
                XCTAssertEqual(scroll.frame, controller.view.safeAreaLayoutGuide.layoutFrame)
                let imageFrame = controller.bigImageView.convert(controller.bigImageView.bounds, to: scroll)
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(imageFrame), "The full image must fit: \(imageSize), \(size)")
                XCTAssertEqual(imageFrame.midX, scroll.bounds.midX, accuracy: 1)
                XCTAssertEqual(imageFrame.midY, scroll.bounds.midY, accuracy: 1)
            }
        }
    }

    @MainActor
    func testPhotoViewerPreservesZoomAndFocalPointWhenResized() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ZoomViewController.self))
        let controller = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "ZoomViewController") as? ZoomViewController)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        controller.image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(controller.scrollView)
        scroll.setZoomScale(scroll.minimumZoomScale * 3, animated: false)
        let focus = CGPoint(x: 960, y: 660)
        let scaledFocus = controller.bigImageView.convert(focus, to: scroll)
        scroll.contentOffset = CGPoint(x: scaledFocus.x - scroll.bounds.width / 2, y: scaledFocus.y - scroll.bounds.height / 2)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale / scroll.minimumZoomScale, 3, accuracy: 0.001, "Ordinary layout must not reset a pinch zoom")

        for size in [CGSize(width: 667, height: 375), CGSize(width: 1024, height: 768), CGSize(width: 375, height: 768)] {
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            controller.view.layoutIfNeeded()
            XCTAssertEqual(scroll.zoomScale / scroll.minimumZoomScale, 3, accuracy: 0.001)
            let currentFocus = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: controller.bigImageView)
            XCTAssertEqual(currentFocus.x, focus.x, accuracy: 2)
            XCTAssertEqual(currentFocus.y, focus.y, accuracy: 2)
        }
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        window.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, scroll.minimumZoomScale, accuracy: 0.001)
        let fittedFrame = controller.bigImageView.convert(controller.bigImageView.bounds, to: scroll)
        XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(fittedFrame))
    }

    @MainActor
    func testPhotoViewerHandlesMissingAndZeroSizeImages() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ZoomViewController.self))
        for image in [nil, UIImage()] as [UIImage?] {
            let controller = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "ZoomViewController") as? ZoomViewController)
            controller.image = image
            controller.loadViewIfNeeded()
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.scrollView.contentSize, .zero)
            XCTAssertTrue(controller.scrollView.zoomScale.isFinite)
            XCTAssertTrue(controller.scrollView.minimumZoomScale.isFinite)
            XCTAssertTrue(controller.scrollView.maximumZoomScale.isFinite)
        }
    }

    @MainActor
    func testStatisticsLayoutScrollsWithinProfileAtAllTextSizes() throws {
        let original = (visitedCount, totalMachines, visitedByArea, activeMachinesByArea, visitedActiveByArea)
        let defaults = UserDefaults.standard
        let previousAward = defaults.object(forKey: "userSawLast")
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
            (visitedCount, totalMachines, visitedByArea, activeMachinesByArea, visitedActiveByArea) = original
            defaults.set(previousAward, forKey: "userSawLast")
        }
        visitedCount = 192
        totalMachines = 7835
        visitedByArea = ["Germany": 100, "United States": 90, "Switzerland": 80, "France": 70,
                         "United Kingdom": 60, "Canada": 50, "Italy": 40, "Spain": 30,
                         "Austria": 20, "Belgium": 15, "Netherlands": 10, "Poland": 5]
        activeMachinesByArea = visitedByArea.mapValues { $0 * 2 }
        visitedActiveByArea = visitedByArea
        defaults.set(visitedCount, forKey: "userSawLast")

        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: StatisticsViewController.self))
        let profile = ProfileViewController(storyboard: storyboard, artworks: [])
        let navigation = UINavigationController(rootViewController: profile)
        let parent = UIViewController()
        window.rootViewController = parent
        parent.addChild(navigation)
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(navigation.view)
        NSLayoutConstraint.activate([
            navigation.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            navigation.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            navigation.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            navigation.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor)
        ])
        navigation.didMove(toParent: parent)
        window.makeKeyAndVisible()
        profile.loadViewIfNeeded()
        let pager = try XCTUnwrap(profile.children.compactMap { $0 as? UIPageViewController }.first)
        let controller = try XCTUnwrap(pager.viewControllers?.first as? StatisticsViewController)
        controller.barChartView.animate(xAxisDuration: 0, yAxisDuration: 0)
        var compactVisibleRows: Double = 0

        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: navigation)
            for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852), CGSize(width: 667, height: 375),
                         CGSize(width: 1024, height: 768), CGSize(width: 375, height: 768)] {
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                // Commit the navigation and page containers' layout before inspecting the chart.
                let snapshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let scroll = controller.scrollView
                let selector = try XCTUnwrap(profile.view.subviews.compactMap { $0 as? UISegmentedControl }.first)
                XCTAssertGreaterThanOrEqual(scroll.convert(scroll.bounds, to: profile.view).minY, selector.frame.maxY)
                XCTAssertTrue(scroll.clipsToBounds, "Scrolled content must stay below the Profile controls")
                XCTAssertEqual(scroll.contentSize.width, scroll.bounds.width, accuracy: 1)
                XCTAssertEqual(controller.barChartView.data?.entryCount, 12)
                let chart = controller.barChartView
                XCTAssertEqual(chart.visibleXRange, chart.visibleXRange.rounded(), accuracy: 0.05, "Show complete country rows")
                XCTAssertGreaterThanOrEqual(chart.highestVisibleX, 11, "Show the highest-ranked countries initially")
                let visibleNames = chart.xAxis.entries.filter { $0 >= chart.lowestVisibleX && $0 <= chart.highestVisibleX }
                    .compactMap { chart.xAxis.valueFormatter?.stringForValue($0, axis: chart.xAxis) }.filter { !$0.isEmpty }
                XCTAssertEqual(visibleNames.count, Int(chart.visibleXRange.rounded()), "Every visible country needs a label")
                let rowSpacing = chart.viewPortHandler.contentRect.height / CGFloat(chart.visibleXRange)
                XCTAssertGreaterThanOrEqual(rowSpacing + 1, chart.xAxis.labelHeight + 4, "Multiline country labels must remain readable")
                XCTAssertGreaterThanOrEqual(rowSpacing, 31)
                XCTAssertLessThanOrEqual(rowSpacing, 44, "Country rows must remain compact")
                if category == .large && size.width == 320 {
                    compactVisibleRows = chart.visibleXRange
                    let originalTop = chart.highestVisibleX
                    let transformer = chart.getTransformer(forAxis: .left)
                    let bottom = transformer.pixelForValues(x: 0, y: chart.xAxis.axisMinimum + chart.visibleXRange)
                    chart.viewPortHandler.centerViewPort(pt: bottom, chart: chart)
                    controller.view.setNeedsLayout()
                    controller.view.layoutIfNeeded()
                    XCTAssertLessThan(chart.highestVisibleX, originalTop, "Scrolling must reveal the remaining countries without resetting")
                    let top = transformer.pixelForValues(x: 0, y: chart.xAxis.axisMaximum)
                    chart.viewPortHandler.centerViewPort(pt: top, chart: chart)
                    chart.notifyDataSetChanged()
                }
                if category == .large && size.width == 393 {
                    XCTAssertGreaterThan(chart.visibleXRange, compactVisibleRows, "Taller screens should show more countries")
                    XCTAssertGreaterThan(chart.visibleXRange, 8, "The chart must not be capped at eight countries")
                }
                XCTAssertGreaterThan(controller.barChartView.viewPortHandler.contentRect.width, 80)
                let requiredLabelWidth = ["Germany", "United\nStates", "Switzerland"].map {
                    ($0 as NSString).size(withAttributes: [.font: controller.barChartView.xAxis.labelFont]).width
                }.max() ?? 0
                XCTAssertGreaterThanOrEqual(controller.barChartView.viewPortHandler.offsetLeft, requiredLabelWidth,
                                             "Country labels need enough space before the plot")
                let valueFont = try XCTUnwrap(controller.barChartView.data?.dataSets.first?.valueFont)
                let requiredValueWidth = ("100" as NSString).size(withAttributes: [.font: valueFont]).width
                XCTAssertGreaterThanOrEqual(controller.barChartView.viewPortHandler.offsetRight, requiredValueWidth + 4,
                                             "Bar values need enough space after the plot")
                let contentBounds = CGRect(origin: .zero, size: scroll.contentSize).insetBy(dx: -1, dy: -1)
                for view in [controller.titleLabel, controller.numberLabel, controller.totalLabel,
                             controller.crownImage, controller.secondCrown,
                             controller.thirdCrown, controller.byCountryLabel, controller.barChartView,
                             controller.percentLabel, controller.showPercentSwitch] {
                    if view.isHidden { continue }
                    XCTAssertFalse(view.hasAmbiguousLayout, "\(type(of: view)), \(size), \(category)")
                    XCTAssertTrue(contentBounds.contains(view.convert(view.bounds, to: scroll)),
                                  "All content must fit within the scrollable area: \(type(of: view)), \(size), \(category)")
                    if let label = view as? UILabel, !label.adjustsFontSizeToFitWidth {
                        let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                        XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height, "Text must not be clipped")
                    }
                }
                XCTAssertEqual(controller.numberLabel.text, "192")
                XCTAssertEqual(controller.totalLabel.text, "/7835")
                XCTAssertEqual(controller.titleLabel.text, "Collector status: Gold!")
                XCTAssertFalse(controller.titleLabel.isHidden)
                let crownFrame = controller.crownImage.convert(controller.crownImage.bounds, to: scroll)
                let numberFrame = controller.numberLabel.convert(controller.numberLabel.bounds, to: scroll)
                let totalFrame = controller.totalLabel.convert(controller.totalLabel.bounds, to: scroll)
                XCTAssertGreaterThanOrEqual(crownFrame.minX, max(numberFrame.maxX, totalFrame.maxX), "Crowns belong beside the numbers")
                if category == .large && size.height >= 768 {
                    scroll.setContentOffset(.zero, animated: false)
                    XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(chart.convert(chart.bounds, to: scroll)),
                                  "The dynamically sized location list must fit on a normal portrait screen")
                    XCTAssertTrue(scroll.bounds.contains(controller.titleLabel.convert(controller.titleLabel.bounds, to: scroll)),
                                  "Collector status must be visible with the chart")
                }
                let toggleFrame = controller.showPercentSwitch.convert(controller.showPercentSwitch.bounds, to: scroll)
                let percentRow = try XCTUnwrap(controller.percentLabel.superview)
                let percentFrame = percentRow.convert(percentRow.bounds, to: scroll)
                scroll.scrollRectToVisible(percentFrame.insetBy(dx: 0, dy: -8), animated: false)
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(toggleFrame), "The chart control must remain reachable")
                XCTAssertTrue(scroll.bounds.insetBy(dx: -1, dy: -1).contains(percentFrame), "The full chart-control label must remain reachable")
                XCTAssertTrue(scroll.isScrollEnabled)
                XCTAssertTrue(chart.dragEnabled)
                if size.width == 320 || size.width == 393 {
                    let attachment = XCTAttachment(image: snapshot)
                    attachment.name = "Statistics-\(category.rawValue)-\(Int(size.width))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    @MainActor
    func testStatisticsPreservesChartModesAndEmptyState() throws {
        let original = (visitedCount, totalMachines, visitedByArea, activeMachinesByArea, visitedActiveByArea)
        let defaults = UserDefaults.standard
        let previousAward = defaults.object(forKey: "userSawLast")
        defer {
            (visitedCount, totalMachines, visitedByArea, activeMachinesByArea, visitedActiveByArea) = original
            defaults.set(previousAward, forKey: "userSawLast")
        }
        visitedCount = 5
        totalMachines = 14
        visitedByArea = ["A": 3, "B": 2]
        activeMachinesByArea = ["A": 6, "B": 8]
        visitedActiveByArea = visitedByArea
        defaults.set(visitedCount, forKey: "userSawLast")
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: StatisticsViewController.self))
        let controller = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "StatisticsViewController") as? StatisticsViewController)
        controller.loadViewIfNeeded()
        let absolute = try XCTUnwrap(controller.barChartView.data?.dataSets.first)
        XCTAssertEqual((0..<absolute.entryCount).compactMap { absolute.entryForIndex($0)?.y }.sorted(), [2, 3])
        controller.showPercentSwitch.isOn = true
        controller.showPercentSwitch.sendActions(for: .valueChanged)
        let percentages = try XCTUnwrap(controller.barChartView.data?.dataSets.first)
        XCTAssertEqual((0..<percentages.entryCount).compactMap { percentages.entryForIndex($0)?.y }.sorted(), [25, 50])

        visitedCount = 0
        visitedByArea = [:]
        let empty = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "StatisticsViewController") as? StatisticsViewController)
        empty.loadViewIfNeeded()
        XCTAssertNil(empty.barChartView.data)
        XCTAssertEqual(empty.barChartView.noDataText, "No collected countries yet.")
        XCTAssertEqual(empty.numberLabel.text, "0")
        XCTAssertFalse(empty.titleLabel.isHidden)
        XCTAssertEqual(empty.titleLabel.text, "Collector status: Getting started")
        XCTAssertTrue(empty.secondCrown.isHidden)
        XCTAssertTrue(empty.thirdCrown.isHidden)
    }

    @MainActor
    func testSettingsRowsAdaptToWidthAndAccessibilityText() throws {
        let defaults = UserDefaults.standard
        let originalRadius = defaults.object(forKey: "radius")
        defaults.set(20, forKey: "radius")
        defer { defaults.set(originalRadius, forKey: "radius") }
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: SettingsViewController.self))
        let controller = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "Settings") as? SettingsViewController)
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        let parent = UIViewController()
        window.rootViewController = parent
        parent.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor)
        ])
        controller.didMove(toParent: parent)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }

        XCTAssertEqual(radius, 1, "Use 1 km even when a different radius was previously saved")
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 1), 1, "Keep only the push-notification switch")
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 3), 1, "Keep only the trip import row")
        XCTAssertEqual(controller.tableView(controller.tableView, titleForFooterInSection: 1),
                       "Notify me when within 1KM of unvisited machine. NOTE: Open app regularly to keep this active.")
        let visitedCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 2))
        let visitedLabel = try XCTUnwrap(visitedCell.contentView.subviews.compactMap { $0 as? UILabel }.first)
        visitedLabel.text = "Show penny machines that I have already visited while travelling"
        var standardSwitchHeight: CGFloat = 0
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            for size in [CGSize(width: 320, height: 568), CGSize(width: 667, height: 375),
                         CGSize(width: 1024, height: 768), CGSize(width: 375, height: 768)] {
                window.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                controller.tableView.reloadData()
                controller.tableView.layoutIfNeeded()
                for section in 0..<controller.tableView.numberOfSections {
                    for row in 0..<controller.tableView.numberOfRows(inSection: section) {
                        let indexPath = IndexPath(row: row, section: section)
                        controller.tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
                        controller.tableView.layoutIfNeeded()
                        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: indexPath))
                        XCTAssertGreaterThanOrEqual(cell.bounds.height, 44)
                        for view in cell.contentView.subviews {
                            XCTAssertFalse(view is UISlider, "Settings no longer exposes distance sliders")
                            XCTAssertFalse(view.hasAmbiguousLayout, "\(indexPath), \(size), \(category)")
                            XCTAssertTrue(cell.contentView.bounds.insetBy(dx: -1, dy: -1).contains(view.frame),
                                          "Content must fit within its row: \(indexPath), \(size), \(category)")
                            if let label = view as? UILabel {
                                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                                XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height, "Text must not be clipped: \(indexPath)")
                            } else if let button = view as? UIButton, let label = button.titleLabel {
                                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                                XCTAssertGreaterThanOrEqual(label.bounds.height + 1, required.height, "Button titles must not be clipped")
                                XCTAssertTrue(button.bounds.insetBy(dx: -1, dy: -1).contains(label.frame), "Button titles must fit within the button")
                            }
                        }
                    }
                }
                let pushHeight = controller.tableView.rectForRow(at: IndexPath(row: 0, section: 1)).height
                if size.width == 320 {
                    if category == .large {
                        standardSwitchHeight = pushHeight
                    } else {
                        XCTAssertGreaterThan(pushHeight, standardSwitchHeight, "Accessibility text must grow the row")
                    }
                    controller.tableView.setContentOffset(CGPoint(x: 0, y: -controller.tableView.adjustedContentInset.top), animated: false)
                    controller.tableView.layoutIfNeeded()
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = "Settings-\(category.rawValue)-320"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    @MainActor
    func testMapControlsAndSearchResultsResizeWithTheirContainer() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ViewController.self))
        let controller: MapLayoutTestController = storyboard.instantiateViewController(identifier: "SettingsViewController") {
            MapLayoutTestController(coder: $0)
        }
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        controller.artworks = ["Entrance 1", "Entrance 2", "Playground"].enumerated().map { index, suffix in
            Artwork(title: "Allwetterzoo Münster - \(suffix)", address: "", link: "", status: "unvisited",
                    coordinate: CLLocationCoordinate2D(latitude: 51.95, longitude: 7.59), id: index,
                    last_updated: "", multimachine: 1, paywall: false,
                    machineStatus: "available", area: "", numCoins: 4)
        }

        for size in [CGSize(width: 375, height: 667), CGSize(width: 667, height: 375),
                     CGSize(width: 1024, height: 768), CGSize(width: 375, height: 768)] {
            controller.filterContentForSearchText("no matches")
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let safeArea = controller.view.safeAreaLayoutGuide.layoutFrame
            for button in [controller.ownLocation!, controller.toggleMapButton!,
                           controller.newMachineButton!, controller.userProfileButton!] {
                XCTAssertTrue(button.superview === controller.view, "Reparenting removes the storyboard constraints")
                XCTAssertFalse(button.hasAmbiguousLayout)
                XCTAssertTrue(safeArea.contains(button.frame))
            }
            XCTAssertEqual(controller.ownLocation.frame.maxX, safeArea.maxX - 10, accuracy: 0.5)
            XCTAssertEqual(controller.ownLocation.frame.maxY, safeArea.maxY - 30, accuracy: 0.5)
            XCTAssertEqual(controller.locationResult.frame.minX, controller.PennyMap.frame.minX, accuracy: 0.5)
            XCTAssertEqual(controller.locationResult.frame.width, controller.PennyMap.frame.width, accuracy: 0.5)
            XCTAssertEqual(controller.locationResult.frame.minY, controller.PennyMap.frame.minY, accuracy: 0.5)
            XCTAssertLessThanOrEqual(controller.locationResult.frame.maxY,
                                    controller.view.keyboardLayoutGuide.layoutFrame.minY + 0.5)
            XCTAssertGreaterThan(controller.locationResult.bounds.height, 0)
            XCTAssertLessThan(controller.locationResult.bounds.height, controller.PennyMap.bounds.height,
                              "The empty-search message should leave the map visible")
            XCTAssertFalse(controller.locationResult.hasAmbiguousLayout)

            controller.filterContentForSearchText("Münster")
            controller.view.layoutIfNeeded()
            let table = controller.locationResult
            let availableHeight = controller.view.keyboardLayoutGuide.layoutFrame.minY - table.frame.minY
            XCTAssertEqual(table.bounds.height, min(table.contentSize.height, availableHeight), accuracy: 1,
                           "Three matches should occupy only the space their rows need")
            XCTAssertEqual(table.numberOfRows(inSection: 0), 3)
            if size.width == 375 && size.height == 667 {
                let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                })
                attachment.name = "Search-three-results-map-below"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testMapSearchHandlesLongTitlesEmptyResultsClearingAndCancellation() throws {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ViewController.self))
        let controller: MapLayoutTestController = storyboard.instantiateViewController(identifier: "SettingsViewController") {
            MapLayoutTestController(coder: $0)
        }
        let originalWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        controller.view.layoutIfNeeded()
        let title = String(repeating: "Long machine title ", count: 12)
        controller.artworks = [Artwork(title: title, address: "Test address", link: "", status: "unvisited",
                                       coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), id: 1,
                                       last_updated: "", multimachine: 1, paywall: false,
                                       machineStatus: "available", area: "", numCoins: 4)]

        controller.filterContentForSearchText("machine")
        controller.view.layoutIfNeeded()
        controller.locationResult.layoutIfNeeded()
        XCTAssertFalse(controller.locationResult.isHidden)
        XCTAssertEqual(controller.locationResult.numberOfRows(inSection: 0), 1)
        XCTAssertEqual(controller.locationResult.cellForRow(at: IndexPath(row: 0, section: 0))?.textLabel?.text, title)
        XCTAssertGreaterThan(controller.locationResult.rectForRow(at: IndexPath(row: 0, section: 0)).height, 44)
        XCTAssertTrue(try XCTUnwrap(controller.locationResult.backgroundView).isHidden)
        XCTAssertEqual(controller.locationResult.bounds.height, controller.locationResult.contentSize.height, accuracy: 1,
                       "A short result list must not cover the map below its last row")
        let mapPoint = CGPoint(x: controller.PennyMap.frame.midX, y: controller.locationResult.frame.maxY + 20)
        XCTAssertTrue(controller.view.hitTest(mapPoint, with: nil)?.isDescendant(of: controller.PennyMap) == true,
                      "The exposed map must remain interactive")

        let shortResults = controller.artworks
        controller.artworks += (2...80).map { id in
            Artwork(title: "Machine \(id)", address: "Test address", link: "", status: "unvisited",
                    coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), id: id,
                    last_updated: "", multimachine: 1, paywall: false,
                    machineStatus: "available", area: "", numCoins: 4)
        }
        controller.filterContentForSearchText("machine")
        controller.view.layoutIfNeeded()
        let table = controller.locationResult
        XCTAssertEqual(table.frame.maxY, controller.view.keyboardLayoutGuide.layoutFrame.minY, accuracy: 1)
        XCTAssertGreaterThan(table.contentSize.height, table.bounds.height)
        XCTAssertTrue(table.isScrollEnabled)
        table.scrollToRow(at: IndexPath(row: 79, section: 0), at: .bottom, animated: false)
        table.layoutIfNeeded()
        XCTAssertNotNil(table.cellForRow(at: IndexPath(row: 79, section: 0)), "The final result must remain reachable")

        controller.artworks = shortResults
        controller.filterContentForSearchText("machine")
        controller.view.layoutIfNeeded()
        XCTAssertEqual(table.bounds.height, table.contentSize.height, accuracy: 1,
                       "Narrowing a long result list should reveal the map again")

        controller.filterContentForSearchText("nonexistent")
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.locationResult.numberOfRows(inSection: 0), 0)
        XCTAssertFalse(try XCTUnwrap(controller.locationResult.backgroundView).isHidden)

        controller.searchController.searchBar.text = ""
        controller.updateSearchResults(for: controller.searchController)
        XCTAssertTrue(controller.locationResult.isHidden)
        XCTAssertTrue(controller.filteredArtworks.isEmpty)

        controller.filterContentForSearchText("machine")
        controller.searchBarCancelButtonClicked(controller.searchController.searchBar)
        XCTAssertTrue(controller.locationResult.isHidden)
        XCTAssertEqual(controller.locationResult.numberOfRows(inSection: 0), 0)
        controller.filterContentForSearchText("machine")
        XCTAssertFalse(controller.locationResult.isHidden)
        XCTAssertEqual(controller.locationResult.numberOfRows(inSection: 0), 1)

        controller.didDismissSearchController(controller.searchController)
        XCTAssertTrue(controller.locationResult.isHidden)
        XCTAssertTrue(controller.filteredArtworks.isEmpty)
    }

    @MainActor
    func testScrollingPinDetailsDoesNotChangeTheReportedImage() {
        let controller = PinViewController(style: .grouped)
        let photos = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let pages = UIPageControl()
        pages.numberOfPages = 5
        controller.scrollView = photos
        controller.pageControl = pages
        let details = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        for page in 1...4 {
            photos.contentOffset.x = CGFloat(page) * photos.bounds.width
            controller.scrollViewDidScroll(photos)
            XCTAssertEqual(pages.currentPage, page)
            details.contentOffset.y = CGFloat(page) * 100
            controller.scrollViewDidScroll(details)
            XCTAssertEqual(pages.currentPage, page, "Vertical scrolling must preserve the selected coin")
        }
        photos.frame.size.width = 0
        controller.scrollViewDidScroll(photos)
        XCTAssertEqual(pages.currentPage, 4)
    }

    @MainActor
    func testPresencePromptSurvivesLocationLossDriftAndAppInterruptions() async throws {
        let appDelegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let originalWindow = appDelegate.window
        let window = UIWindow(frame: originalWindow?.bounds ?? UIScreen.main.bounds)
        let presenter = UIViewController()
        window.rootViewController = presenter
        appDelegate.window = window
        window.makeKeyAndVisible()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let machine = PresenceMachine(id: 42, name: "Zoo · Machine 6", latitude: 0, longitude: 0)
        let data = try JSONSerialization.data(withJSONObject: ["machines": [], "nearby_machines": [
            ["id": 42, "name": machine.name, "latitude": 0, "longitude": 0, "num_coins": 0],
            ["id": 43, "name": "Zoo · Machine 7", "latitude": 0, "longitude": 0, "num_coins": 0]
        ]])
        PresenceTestURLProtocol.response = { request in
            request.url?.path == "/machines/nearby-confirmations" ? (200, data) : (404, Data())
        }
        defer {
            presenter.dismiss(animated: false)
            PresenceTestURLProtocol.response = nil
            session.invalidateAndCancel()
            window.isHidden = true
            appDelegate.window = originalWindow
            originalWindow?.makeKeyAndVisible()
        }
        let manager = PresenceTestLocationManager()
        let fix = CLLocation(coordinate: machine.location.coordinate, altitude: 0,
                             horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        manager.testLocation = fix
        var active = true
        let monitor = MachinePresenceMonitor(hasNearbyMachine: { _ in false }, isBlocked: { _ in false },
                                             manager: manager, session: session, isActive: { active })
        monitor.requestManualConfirmation(machine)
        let presented = expectation(for: NSPredicate { _, _ in
            guard let prompt = presenter.presentedViewController as? PresenceConfirmationController else { return false }
            return !prompt.isBeingPresented
        }, evaluatedWith: nil)
        await fulfillment(of: [presented], timeout: 4)
        let prompt = try XCTUnwrap(presenter.presentedViewController as? PresenceConfirmationController)
        XCTAssertTrue(prompt.isModalInPresentation)
        if #available(iOS 16.0, *) {
            let initialHeight = prompt.view.bounds.height
            prompt.rootView.onCompareNearby()
            let expanded = expectation(for: NSPredicate { _, _ in
                prompt.view.bounds.height > initialHeight
            }, evaluatedWith: nil)
            await fulfillment(of: [expanded], timeout: 3)
        }

        let viewer = UIViewController()
        viewer.modalPresentationStyle = .fullScreen
        prompt.present(viewer, animated: false)
        for location in [
            CLLocation(coordinate: machine.location.coordinate, altitude: 0, horizontalAccuracy: 5,
                       verticalAccuracy: -1, timestamp: Date().addingTimeInterval(-20)),
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 120 / 111319.49),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        ] {
            manager.testLocation = location
            monitor.locationManager(manager, didUpdateLocations: [location])
            XCTAssertTrue(presenter.presentedViewController === prompt)
            XCTAssertTrue(prompt.presentedViewController === viewer)
            XCTAssertFalse(prompt.isBeingDismissed)
            XCTAssertNotNil(prompt.rootView.locationMessage)
            if MachinePresencePolicy.isPreciseAndFresh(location) {
                XCTAssertEqual(prompt.rootView.location.coordinate.longitude, location.coordinate.longitude)
            }
        }
        active = false
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(presenter.presentedViewController === prompt)
        XCTAssertTrue(prompt.presentedViewController === viewer)
        active = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        manager.testLocation = fix
        monitor.locationManager(manager, didUpdateLocations: [fix])
        XCTAssertNil(prompt.rootView.locationMessage)
        XCTAssertTrue(prompt.presentedViewController === viewer)
    }

    func testPresenceComparisonUsesOneHundredMetresAroundUserAndSupportsOlderResponses() throws {
        func machine(_ id: Int, metres: Double) -> [String: Any] {
            ["id": id, "name": "Machine \(id)", "latitude": 0, "longitude": metres / 111319.49, "num_coins": 6]
        }
        let target = machine(1, metres: 20)
        let context = [target, machine(2, metres: 119.9), machine(3, metres: -80.1), machine(4, metres: 20)]
        let data = try JSONSerialization.data(withJSONObject: ["machines": [target], "nearby_machines": context])
        let candidates = try JSONDecoder().decode(PresenceCandidates.self, from: data)
        let selected = try XCTUnwrap(candidates.machines.first)
        XCTAssertEqual(selected.numCoins, 6)
        let location = CLLocation(latitude: 0, longitude: 0)
        // Count other machines around the user, including recently confirmed ones.
        XCTAssertEqual(candidates.neighbors(of: selected, at: location).map(\.id), [4, 3])
        XCTAssertTrue(candidates.neighbors(of: selected, at: CLLocation(latitude: 1, longitude: 1)).isEmpty)

        let legacyData = Data("{\"machines\":[{\"id\":1,\"name\":\"Zoo\",\"latitude\":0,\"longitude\":0}]}".utf8)
        let legacy = try JSONDecoder().decode(PresenceCandidates.self, from: legacyData)
        XCTAssertNil(legacy.machines[0].numCoins)
        XCTAssertTrue(legacy.neighbors(of: legacy.machines[0], at: location).isEmpty)
    }

    @MainActor
    func testPresenceComparisonDisappearsWhenOnlySelfOrDistantMachinesRemain() {
        let target = PresenceMachine(id: 1, name: "Target", latitude: 0, longitude: 0)
        let nearby = PresenceMachine(id: 2, name: "Nearby", latitude: 0, longitude: 99.9 / 111319.49)
        let distant = PresenceMachine(id: 3, name: "Distant", latitude: 0, longitude: 100.1 / 111319.49)
        let controller = PresenceConfirmationController(machine: target, neighbors: [target, nearby, distant],
                                                       location: target.location, finish: { _ in })
        XCTAssertEqual(controller.rootView.comparisonMachines.map(\.id), [2])
        let moved = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        controller.updateLocation(moved, source: .manual)
        XCTAssertTrue(controller.rootView.comparisonMachines.isEmpty)
        let isolated = PresenceConfirmationView(machine: target, neighbors: [target, distant],
                                               location: target.location, finish: { _ in })
        XCTAssertTrue(isolated.comparisonMachines.isEmpty)
    }

    @MainActor
    func testPresencePhotosPreferMachineThenAllAvailableCoinsAndRespectBlocks() async throws {
        let suiteName = "PresencePhotoBlocksTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let blocked = BlockedContributorsStore(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }.pngData())
        let machine = PresenceMachine(id: 42, name: "Zoo", latitude: 0, longitude: 0, numCoins: 3)
        defer {
            PresenceTestURLProtocol.response = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
        }
        for scenario in ["machine", "coins", "blocked", "missing"] {
            blocked.unblockAll()
            if scenario == "blocked" {
                blocked.block(contributorID: "hidden", contentKey: "99:image:machine")
                blocked.block(contributorID: nil, contentKey: "42:image:coin_2")
            }
            PresenceTestURLProtocol.response = { request in
                let path = request.url!.path
                if path.contains("moderation/manifest") {
                    return (200, Data("{\"owners\":{\"image:machine\":\"hidden\",\"image:coin_0\":\"hidden\"}}".utf8))
                }
                if scenario == "blocked" {
                    XCTAssertFalse(path.hasSuffix("42.jpg"))
                    XCTAssertFalse(path.hasSuffix("coin_0.png"))
                    XCTAssertFalse(path.hasSuffix("coin_2.png"))
                }
                if scenario == "machine" {
                    XCTAssertFalse(path.contains("coin_"), "Coins are only a fallback")
                    return (200, png)
                }
                if scenario == "coins", path.hasSuffix("coin_0.png") || path.hasSuffix("coin_2.png") {
                    return (200, png)
                }
                if scenario == "blocked", path.hasSuffix("coin_1.png") { return (200, png) }
                return (404, Data())
            }
            let photos = PresencePhotos()
            await photos.load(machine: machine, session: session, blocked: blocked)
            let expected: [String]
            switch scenario {
            case "machine": expected = ["image:machine"]
            case "coins": expected = ["image:coin_0", "image:coin_2"]
            case "blocked": expected = ["image:coin_1"]
            default: expected = []
            }
            XCTAssertEqual(photos.photos.map(\.id), expected, scenario)
            XCTAssertFalse(photos.isLoading)
        }
    }

    @MainActor
    func testRediscoveryUsesServerStatusAndOnlyPresetsTheProposedStatus() throws {
        for status in ["available", "out-of-order", "retired"] {
            let feature: [String: Any] = [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [8.54, 47.37]],
                "properties": ["id": 42, "name": "Current server title", "address": "Current address",
                               "area": "Germany", "external_url": "null", "last_updated": "2026-11-01",
                               "machine_status": status, "num_coins": 8, "paywall": true]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["machine": feature])
            let rediscovered = MachinePresencePolicy.rediscoveredMachine(from: data)
            XCTAssertEqual(rediscovered != nil, status != "available")
            let encoded = try JSONSerialization.data(withJSONObject: feature)
            let geoFeature = try XCTUnwrap(MKGeoJSONDecoder().decode(encoded).first as? MKGeoJSONFeature)
            let machine = try XCTUnwrap(Artwork(feature: geoFeature))
            let regular = MachineChangedForm(pinData: machine)
            XCTAssertEqual(regular.proposedMachineStatus, status)
            XCTAssertFalse(regular.requiresStatusExplanation)
            let suggested = MachineChangedForm(pinData: machine, suggestedStatus: "available")
            XCTAssertEqual(suggested.proposedMachineStatus, "available")
            XCTAssertEqual(suggested.requiresStatusExplanation, status != "available")
            XCTAssertEqual(machine.machineStatus, status)
            XCTAssertEqual(suggested.pinDataStored.address, "Current address")
            XCTAssertEqual(suggested.pinDataStored.numCoins, 8)
        }
        XCTAssertNil(MachinePresencePolicy.rediscoveredMachine(from: Data("{}".utf8)))
        XCTAssertNil(MachinePresencePolicy.rediscoveredMachine(from: Data("{\"machine\":{\"properties\":{\"machine_status\":\"retired\"}}}".utf8)))
    }

    func testStatusChangeReasonRequiresTenTrimmedCharacters() {
        XCTAssertFalse(MachineChangedForm.isValidStatusReason("          "))
        XCTAssertFalse(MachineChangedForm.isValidStatusReason("123456789"))
        XCTAssertTrue(MachineChangedForm.isValidStatusReason(" 1234567890 "))
        XCTAssertFalse(MachineChangedForm.isValidStatusReason(String(repeating: "x", count: 2001)))
    }

    @MainActor
    func testPresenceConfirmsWithExistingFreshFixAndAfterTemporaryError() async {
        for temporaryError in [false, true] {
            let sent = expectation(description: "Live confirmation sent (temporary error: \(temporaryError))")
            let manager = PresenceTestLocationManager()
            let fix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                 altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                                 timestamp: Date().addingTimeInterval(-2))
            manager.testLocation = temporaryError ? nil : fix
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PresenceTestURLProtocol.self]
            let session = URLSession(configuration: configuration)
            PresenceTestURLProtocol.onRequest = { request in
                XCTAssertEqual(request.url?.path, "/machines/42/confirm-presence")
                sent.fulfill()
            }
            let monitor = MachinePresenceMonitor(
                hasNearbyMachine: { _ in false }, isBlocked: { _ in false },
                manager: manager, session: session, isActive: { true }
            )
            let stopsBeforeConfirming = manager.stops
            monitor.requestFreshConfirmation(PresenceMachine(id: 42, name: "Test", latitude: 0, longitude: 0))
            if temporaryError {
                monitor.locationManager(manager, didFailWithError: CLError(.locationUnknown))
                // The delegate fix can precede the tap and the manager's cached property can be nil.
                monitor.locationManager(manager, didUpdateLocations: [fix])
            }
            XCTAssertEqual(manager.stops, stopsBeforeConfirming, "Confirming must not restart GPS")
            await fulfillment(of: [sent], timeout: 3)
            session.invalidateAndCancel()
        }
        PresenceTestURLProtocol.onRequest = nil
    }

    func testPresenceRequiresFreshPreciseLocationWithinTwentyMetres() {
        let now = Date()
        let machine = PresenceMachine(id: 1, name: "Test", latitude: 0, longitude: 0)
        func fix(metres: Double = 0, accuracy: Double = 5, age: Double = 0) -> CLLocation {
            let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: metres / 111319.49)
            return CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy,
                              verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 19.9), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 20.1), now: now))
        XCTAssertTrue(MachinePresencePolicy.canConfirm(machine, at: fix(accuracy: 10, age: 15), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(accuracy: -1), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(accuracy: 10.1), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(age: 15.1), now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(age: -5.1), now: now))
    }

    @MainActor
    func testManualPresenceUsesOneHundredMetresAndSendsTheManualSource() async throws {
        let now = Date()
        let machine = PresenceMachine(id: 42, name: "Zoo", latitude: 0, longitude: 0)
        func fix(metres: Double, age: Double = 0, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: metres / 111319.49),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 99.9), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 100.1), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 75, age: 16), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 75, accuracy: 11), source: .manual, now: now))
        XCTAssertFalse(MachinePresencePolicy.canConfirm(machine, at: fix(metres: 75), now: now))
        let manager = PresenceTestLocationManager()
        manager.testLocation = fix(metres: 75)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sent = expectation(description: "Manual confirmation sent beyond the automatic radius")
        PresenceTestURLProtocol.onRequest = { request in
            XCTAssertEqual(request.url?.path, "/machines/42/confirm-presence")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            XCTAssertEqual(body?["source"] as? String, "manual")
            sent.fulfill()
        }
        defer {
            PresenceTestURLProtocol.onRequest = nil
            session.invalidateAndCancel()
        }
        let monitor = MachinePresenceMonitor(hasNearbyMachine: { _ in false }, isBlocked: { _ in false },
                                             manager: manager, session: session, isActive: { true })
        monitor.requestFreshConfirmation(machine, source: .manual)
        await fulfillment(of: [sent], timeout: 3)
    }

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// User movement updates the form; programmatic changes must not feed back.
    @MainActor
    func testCoordinatePickerSynchronizesSelection() {
        let initial = CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54)
        var selection = initial
        let coordinator = CoordinatePickerMap.Coordinator(
            selectedLocation: Binding(get: { selection }, set: { selection = $0 })
        )
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 200))
        let moved = CLLocationCoordinate2D(latitude: 47.38, longitude: 8.55)
        map.setRegion(MKCoordinateRegion(
            center: moved, latitudinalMeters: 500, longitudinalMeters: 500
        ), animated: false)
        coordinator.isUpdating = true
        coordinator.mapView(map, regionDidChangeAnimated: false)
        XCTAssertEqual(selection, initial)

        coordinator.isUpdating = false
        coordinator.mapView(map, regionDidChangeAnimated: false)
        XCTAssertEqual(selection.latitude, moved.latitude, accuracy: 0.00001)
        XCTAssertEqual(selection.longitude, moved.longitude, accuracy: 0.00001)
    }

    func testTextModerationBlocksObjectionableLanguageWithoutSubstringFalsePositive() {
        XCTAssertNotNil(TextModeration.blockReason("This is fucking awful"))
        XCTAssertNil(TextModeration.blockReason("Classic brass machine"))
    }

    func testContributionDiffShowsOnlyChangedTextWithContext() {
        let segments = ContributionDiff.segments(
            old: "1737 Post Street, West Mall, #326, San Francisco",
            new: "1737 Post Street, West Mall, San Francisco"
        )

        XCTAssertTrue(segments.prefix.hasPrefix("…"))
        XCTAssertTrue(segments.prefix.contains("West Mall"))
        XCTAssertEqual(segments.removed, "#326, ")
        XCTAssertEqual(segments.added, "")
        XCTAssertTrue(segments.suffix.contains("San Francisco"))
        XCTAssertFalse(segments.prefix.contains("1737 Post"))

        let whitespace = ContributionDiff.segments(
            old: "Fisherman's Wharf ",
            new: "Fisherman's Wharf"
        )
        XCTAssertEqual(whitespace.removed, " ")
        XCTAssertEqual(ContributionDiff.visibleChange(whitespace.removed), "␠")
    }

    func testLegalMarkdownRendersFormattingAndMailLink() {
        let rendered = LegalMarkdownRenderer.attributedText(
            from: "# Terms\n\nContact [support@example.com](mailto:support@example.com). Accept **these terms**.",
            baseTextStyle: .body
        )

        XCTAssertFalse(rendered.string.contains("# "))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertFalse(rendered.string.contains("[support@example.com]"))

        let emailRange = (rendered.string as NSString).range(of: "support@example.com")
        let link = rendered.attribute(.link, at: emailRange.location, effectiveRange: nil)
            as? URL
        XCTAssertEqual(link?.absoluteString, "mailto:support@example.com")
    }

    func testContributorBlockAppliesToOtherContentFromSameContributor() {
        let suiteName = "BlockedContributorsStoreTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlockedContributorsStore(defaults: defaults)
        store.block(contributorID: "contributor-a", contentKey: "image:machine")

        XCTAssertTrue(
            store.isBlocked(contributorID: "contributor-a", contentKey: "image:coin_0")
        )
        XCTAssertFalse(
            store.isBlocked(contributorID: "contributor-b", contentKey: "image:coin_0")
        )
    }

    func testContributorCanBeUnblocked() {
        let suiteName = "BlockedContributorsUnblockTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlockedContributorsStore(defaults: defaults)
        store.block(contributorID: "contributor-a", contentKey: "42:image:machine")
        store.unblock(contributorID: "contributor-a")

        XCTAssertFalse(
            store.isBlocked(
                contributorID: "contributor-a",
                contentKey: "42:image:machine"
            )
        )
        XCTAssertTrue(store.blockedContributorIDs().isEmpty)
        XCTAssertTrue(store.blockedContentKeys().isEmpty)
    }

    func testAllBlocksCanBeCleared() {
        let suiteName = "BlockedContributorsUnblockAllTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlockedContributorsStore(defaults: defaults)
        store.block(contributorID: "contributor-a", contentKey: "42:image:machine")
        store.block(contributorID: nil, contentKey: "43:image:coin_0")
        store.unblockAll()

        XCTAssertTrue(store.blockedContributorIDs().isEmpty)
        XCTAssertTrue(store.blockedContentKeys().isEmpty)
    }

    func testPerformanceExample() {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}

// Exercise the production header with native table sizing, without a contributions request.
private final class ContributionHeaderLayoutTestController: UITableViewController {
    private var expanded = true

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 52
        tableView.register(ContributionGroupHeader.self, forHeaderFooterViewReuseIdentifier: "header")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return expanded ? 1 : 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.textLabel?.text = "Example"
        return cell
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: "header") as? ContributionGroupHeader else { return nil }
        header.configure(title: "Older than a month", expanded: expanded) { [weak self] in
            guard let self = self else { return }
            self.expanded.toggle()
            self.tableView.reloadData()
        }
        return header
    }
}

// Load the real storyboard and layout without starting location or server requests.
private final class MapLayoutTestController: ViewController {
    override func viewDidLoad() {
        setDelegates()
        configureMapLayout()
    }

    override func viewWillAppear(_ animated: Bool) {}
    override func viewDidAppear(_ animated: Bool) {}
}

private final class PresenceTestLocationManager: CLLocationManager {
    var testLocation: CLLocation?
    var stops = 0
    private weak var testDelegate: CLLocationManagerDelegate?
    override var delegate: CLLocationManagerDelegate? {
        get { testDelegate }
        set { testDelegate = newValue }
    }
    override var location: CLLocation? { testLocation }
    override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    override func startUpdatingLocation() {}
    override func stopUpdatingLocation() { stops += 1 }
}

private final class PresenceTestURLProtocol: URLProtocol {
    static var onRequest: ((URLRequest) -> Void)?
    static var response: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.onRequest?(request)
        let (status, data) = Self.response?(request) ?? (200, Data("{}".utf8))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
