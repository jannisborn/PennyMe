//
//  AboutViewController.swift
//  PennyMe
//
//  Created by Jannis Born on 22.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import SwiftUI
import UIKit

/// Keeps the storyboard navigation while hosting a native, scrolling About screen.
final class AboutViewController: UIViewController {
    private var host: UIHostingController<AboutView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: AboutView())
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
        self.host = host
    }
}

private struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    // Generated during the build, so the year never changes on an installed version.
    private let releaseYear: String = {
        guard let url = Bundle.main.url(forResource: "ReleaseYear", withExtension: "txt"),
              let year = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return year.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PennyMe")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Your penny collection, wherever you travel.")
                    Text("Version \(version)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            Section("Explore and collect") {
                Text("Find nearby penny machines and explore your favorite destinations. Track the machines you’ve visited and build your digital penny collection.")
                Text("Get directions, browse photos and learn more about each machine. Enable notifications to hear when an unvisited machine is nearby.")
            }
            Section("Made better together") {
                Text("Help grow the collection by uploading photos, sharing comments or adding machines with a long press on the map.")
                Text("We’re two developers building PennyMe in our spare time. Your contributions and feedback help keep it growing!")
            }
            Section {
                Text("Jannis Born & Nina Wiedemann")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open-source contributors")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Eric Shito · Zain Malik")
                }
            } header: {
                Text("Credits")
            } footer: {
                Text("© \(releaseYear) Jannis Born & Nina Wiedemann")
            }
        }
        .listStyle(.insetGrouped)
    }
}
