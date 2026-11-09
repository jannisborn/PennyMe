import CoreLocation
import SwiftUI
import UIKit

struct PresencePhoto: Identifiable {
    let id: String
    let image: UIImage
}

/// Uses the same image names and moderation ownership as the machine detail view.
@MainActor
final class PresencePhotos: ObservableObject {
    @Published private(set) var photos: [PresencePhoto] = []
    @Published private(set) var isLoading = true
    private var hasLoaded = false

    func load(machine: PresenceMachine, session: URLSession = .shared,
              blocked: BlockedContributorsStore = BlockedContributorsStore()) async {
        guard !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        var owners: [String: String] = [:]
        if let url = URL(string: "moderation/manifest/\(machine.id)", relativeTo: URL(string: flaskURL)) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.addAnonymousUserHeader()
            if let (data, _) = try? await session.data(for: request),
               let object = try? JSONSerialization.jsonObject(with: data),
               let manifest = object as? [String: Any] {
                owners = manifest["owners"] as? [String: String] ?? [:]
            }
        }
        guard !Task.isCancelled else { return }
        func isBlocked(_ key: String) -> Bool {
            blocked.isBlocked(contributorID: owners[key], contentKey: "\(machine.id):\(key)")
        }
        let machineKey = "image:machine"
        if !isBlocked(machineKey),
           let image = await Self.download("\(machine.id).jpg", session: session),
           !isBlocked(machineKey), !Task.isCancelled {
            photos = [PresencePhoto(id: machineKey, image: image)]
            hasLoaded = true
            return
        }
        guard !Task.isCancelled else { return }
        // Fetch all coin photos, including when some indexes have no image.
        photos = []
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for index in 0..<max(0, machine.numCoins ?? 4) {
                guard !isBlocked("image:coin_\(index)") else { continue }
                group.addTask {
                    (index, await Self.download("\(machine.id)_coin_\(index).png", session: session))
                }
            }
            var coins: [Int: UIImage] = [:]
            for await (index, image) in group {
                guard !Task.isCancelled, !isBlocked("image:coin_\(index)"), let image = image else { continue }
                coins[index] = image
                photos = coins.keys.sorted().map { PresencePhoto(id: "image:coin_\($0)", image: coins[$0]!) }
            }
        }
        hasLoaded = !Task.isCancelled
    }

    private static func download(_ filename: String, session: URLSession) async -> UIImage? {
        guard let url = URL(string: filename, relativeTo: URL(string: imageURL)) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

}

private struct PresencePhotoGallery: View {
    let machine: PresenceMachine
    let distance: String
    var compact = false
    var session: URLSession = .shared
    let openPhoto: (PresencePhoto) -> Void
    @StateObject private var images = PresencePhotos()

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 12) {
            if compact {
                Button(action: enlargeFirstPhoto) {
                    HStack(alignment: .top, spacing: 12) {
                        if let photo = images.photos.first {
                            thumbnail(photo, height: 64).frame(width: 72)
                        } else if images.isLoading {
                            ProgressView().frame(width: 72, height: 64)
                        } else {
                            Image(systemName: "photo").foregroundColor(.secondary).frame(width: 72, height: 64)
                        }
                        machineTitle
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(images.photos.isEmpty)
                .accessibilityHint("Opens a photo of another nearby machine")
            } else {
                Button(action: enlargeFirstPhoto) { machineTitle }
                    .buttonStyle(.plain)
                    .disabled(images.photos.isEmpty)
                    .accessibilityHint("Enlarges the photo of the machine to confirm")
                mainPhotos
            }
        }
        .task { await images.load(machine: machine, session: session) }
    }

    private var machineTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(machine.name).font(compact ? .subheadline.weight(.semibold) : .headline)
                .foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
            Label(distance, systemImage: "location.fill")
                .font(compact ? .caption : .subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var mainPhotos: some View {
        VStack(spacing: 8) {
            if images.isLoading && images.photos.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 170)
                    .accessibilityLabel("Loading photos")
            } else if images.photos.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.title2)
                    Text("No photos available").font(.subheadline)
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .accessibilityLabel("No photos available")
            } else if let photo = images.photos.first, photo.id == "image:machine" {
                Button { openPhoto(photo) } label: {
                    VStack(spacing: 8) {
                        thumbnail(photo, height: 190)
                        Text("Machine photo · Tap to enlarge").font(.caption).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Enlarge machine photo for \(machine.name)")
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(images.photos) { photo in photoButton(photo, height: 105) }
                }
                Button(action: enlargeFirstPhoto) {
                    Text("Coin photos · Tap to enlarge").font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func photoButton(_ photo: PresencePhoto, height: CGFloat) -> some View {
        Button { openPhoto(photo) } label: {
            thumbnail(photo, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Enlarge \(photo.id == "image:machine" ? "machine" : "coin") photo for \(machine.name)")
    }

    private func enlargeFirstPhoto() {
        if let photo = images.photos.first { openPhoto(photo) }
    }

    private func thumbnail(_ photo: PresencePhoto, height: CGFloat) -> some View {
        Image(uiImage: photo.image)
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity).frame(height: height)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
    }
}

private struct PresencePhotoSelection: Identifiable {
    let machine: PresenceMachine
    let photo: PresencePhoto
    let isTarget: Bool
    var id: String { "\(machine.id):\(photo.id)" }
}

struct PresenceConfirmationView: View {
    let machine: PresenceMachine
    let neighbors: [PresenceMachine]
    var location: CLLocation
    let finish: (Bool) -> Void
    var session: URLSession = .shared
    var locationMessage: String?
    var onCompareNearby: () -> Void = {}
    @State private var comparingNearby = false
    @State private var enlarged: PresencePhotoSelection?

    var comparisonMachines: [PresenceMachine] {
        MachinePresencePolicy.neighbors(in: neighbors, excluding: machine, at: location)
    }

    var body: some View {
        let neighbors = comparisonMachines
        return VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Is this machine still here?")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        PresencePhotoGallery(machine: machine, distance: distance(to: machine), session: session) { photo in
                            enlarged = PresencePhotoSelection(machine: machine, photo: photo, isTarget: true)
                        }
                        if !neighbors.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("\(neighbors.count) other \(neighbors.count == 1 ? "machine" : "machines") nearby",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                Text("Check the name and photo carefully.").font(.subheadline)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.18)).cornerRadius(12)

                            DisclosureGroup(isExpanded: $comparingNearby) {
                                if comparingNearby {
                                    VStack(spacing: 12) {
                                        ForEach(neighbors, id: \.id) { neighbor in
                                            PresencePhotoGallery(machine: neighbor, distance: distance(to: neighbor),
                                                                 compact: true, session: session) { photo in
                                                enlarged = PresencePhotoSelection(machine: neighbor, photo: photo, isTarget: false)
                                            }
                                            .id(neighbor.id)
                                            if neighbor.id != neighbors.last?.id { Divider() }
                                        }
                                    }
                                    .padding(.top, 12)
                                }
                            } label: {
                                Text("Compare nearby machines").font(.subheadline.weight(.semibold))
                                    .padding(.vertical, 10)
                            }
                            .accessibilityIdentifier("presence.compareNearby")
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 16)
                }
                .onChange(of: comparingNearby) { expanded in
                    guard expanded, let first = neighbors.first else { return }
                    onCompareNearby()
                    DispatchQueue.main.async {
                        withAnimation {
                            scroll.scrollTo(first.id, anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            VStack(spacing: 8) {
                if let locationMessage = locationMessage {
                    Label(locationMessage, systemImage: "location.slash")
                        .font(.footnote).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { finish(true) } label: {
                    Label("Yes, it's here", systemImage: "checkmark")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered).tint(.green)
                .accessibilityIdentifier("presence.confirm")
                Button { finish(false) } label: {
                    Text("I can't confirm").font(.body).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered).tint(.red)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(UIColor.systemBackground))
        .interactiveDismissDisabled()
        .fullScreenCover(item: $enlarged) { photoViewer($0) }
    }

    private func photoViewer(_ selection: PresencePhotoSelection) -> some View {
        let machine = selection.machine
        let photo = selection.photo
        let isTarget = selection.isTarget
        let contextColor: Color = isTarget ? .green : .red
        return NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Label(isTarget ? "Is this machine still here?" : "Nearby machine, not the one to confirm.",
                      systemImage: isTarget ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(contextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(machine.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Image(uiImage: photo.image)
                    .resizable().scaledToFit().padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(contextColor, lineWidth: 4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("\(isTarget ? "Target" : "Nearby") machine photo: \(machine.name)")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemBackground))
            .navigationTitle(photo.id == "image:machine" ? "Machine photo" : "Coin photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { enlarged = nil } label: { Label("Back", systemImage: "chevron.left") }
                        .accessibilityLabel("Back to confirmation")
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled()
    }

    private func distance(to machine: PresenceMachine) -> String {
        "\(Int(location.distance(from: machine.location).rounded())) m away"
    }
}

final class PresenceConfirmationController: UIHostingController<PresenceConfirmationView> {
    init(machine: PresenceMachine, neighbors: [PresenceMachine], location: CLLocation,
         session: URLSession = .shared, finish: @escaping (Bool) -> Void) {
        super.init(rootView: PresenceConfirmationView(machine: machine, neighbors: neighbors, location: location, finish: finish, session: session))
        modalPresentationStyle = .pageSheet
        isModalInPresentation = true
        if let sheet = sheetPresentationController {
            if #available(iOS 16.0, *) {
                let identifier = UISheetPresentationController.Detent.Identifier("presence")
                sheet.detents = [.custom(identifier: identifier) { min(660, $0.maximumDetentValue * 0.85) }, .large()]
                sheet.selectedDetentIdentifier = identifier
            } else {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .large
            }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 28
        }
        rootView.onCompareNearby = { [weak self] in
            guard let sheet = self?.sheetPresentationController else { return }
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
    }

    func updateLocation(_ location: CLLocation?, source: PresenceConfirmationSource) {
        let message: String?
        if let location = location, MachinePresencePolicy.isPreciseAndFresh(location) {
            if rootView.location.coordinate.latitude != location.coordinate.latitude
                || rootView.location.coordinate.longitude != location.coordinate.longitude {
                rootView.location = location
            }
            message = MachinePresencePolicy.canConfirm(rootView.machine, at: location, source: source)
                ? nil : "Move within \(Int(source.radius)) metres to confirm this machine."
        } else {
            message = "A fresh, precise location is needed to confirm."
        }
        if rootView.locationMessage != message { rootView.locationMessage = message }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(machine:neighbors:location:finish:)") }
}
