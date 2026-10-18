import UIKit
import UniformTypeIdentifiers

/// Saves the shared link and hands it to the main app for immediate preview.
final class ShareViewController: UIViewController {
    private var started = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task {
            do {
                let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
                let providers = items.flatMap { $0.attachments ?? [] }
                guard let provider = providers.first(where: {
                    $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                        || $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                }) else { throw CocoaError(.fileReadUnsupportedScheme) }
                let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                    ? UTType.url.identifier : UTType.plainText.identifier
                let item = try await provider.loadItem(forTypeIdentifier: type, options: nil)
                let text = (item as? URL)?.absoluteString ?? (item as? String) ?? ""
                try SharedTrip.save(text)
                openPennyMe()
            } catch {
                finish(title: "Couldn’t import trip", message: error.localizedDescription)
            }
        }
    }

    private func openPennyMe() {
        guard let url = URL(string: "pennyme://trip") else {
            finish(title: "Trip ready", message: "Open PennyMe to view this trip.")
            return
        }
        extensionContext?.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                if opened {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self?.finish(title: "Trip ready", message: "Open PennyMe to view this trip.")
                }
            }
        }
    }

    private func finish(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }
}
