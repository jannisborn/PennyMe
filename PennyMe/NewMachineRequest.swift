//
//  NewMachineRequest.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 25.07.23.
//  Copyright © 2023 Jannis Born. All rights reserved.
//

import Foundation
import MapKit
import UIKit

// RequestFormView.swift

import SwiftUI
import Combine

@available(iOS 13.0, *)
struct AlertPresenter: UIViewControllerRepresentable {
    @Binding var showAlert: Bool
    let title: String
    let message: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: UIViewControllerRepresentableContext<AlertPresenter>) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<AlertPresenter>) {
        if showAlert {
            presentAlert()
        }
    }

    private func presentAlert() {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

        // Get the topmost view controller from the UIApplication and present the alert
        if let controller = UIApplication.shared.keyWindow?.rootViewController {
            controller.present(alertController, animated: true, completion: nil)
        }
    }

    class Coordinator: NSObject {
        var parent: AlertPresenter

        init(_ alertPresenter: AlertPresenter) {
            parent = alertPresenter
        }
    }
}

@available(iOS 13.0, *)
struct ConfirmationMessageView: View {
    let message: String
    @Binding var isPresented: Bool
    
    @available(iOS 13.0.0, *)
    var body: some View {
        VStack {
            Text(message)
                .padding()
                .background(Color.gray)
                .cornerRadius(15)
        }
        .opacity(isPresented ? 1 : 0)
        .animation(.easeInOut(duration: 0.3))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation {
                    isPresented = false
                }
            }
        }
    }
}

@available(iOS 14.0, *)
struct NewMachineFormView: View {
    private struct NearbyMachine: Identifiable {
        let machineID: String
        let name: String
        let status: String
        let distance: Int
        var id: String { machineID }

        init?(json: [String: Any]) {
            guard let name = json["name"] as? String,
                  let status = json["machine_status"] as? String,
                  let machineID = json["id"],
                  let distance = json["distance_m"] as? NSNumber else {
                return nil
            }
            self.machineID = "\(machineID)"
            self.name = name
            self.status = status
            self.distance = distance.intValue
        }

        var statusColor: Color {
            switch status {
            case "available":
                return .red
            case "out-of-order", "retired":
                return .gray
            default:
                return .black
            }
        }
    }

    let coords: CLLocationCoordinate2D
    let areaChoices: [String]
    let openExistingMachine: ((String) -> Void)?
    let isExistingMachineVisible: ((String) -> Bool)?
    let isExistingMachineBlocked: ((String) -> Bool)?
    // Properties to hold user input
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var area: String = ""
    @State private var paywall: Bool = false
    @State private var multimachine: String = "1"
    @State private var numCoins: Int = 4
    @State private var showFinishedAlert = false
    @State private var selectedLocation: CLLocationCoordinate2D
    @State private var displayResponse: String = ""
    @Environment(\.presentationMode) private var presentationMode // Access the presentationMode environment variable
    @State private var selectedImage: UIImage? = nil
    @State private var isImagePickerPresented: Bool = false
    @State private var showAlert = false
    @State private var duplicateMachine: NearbyMachine? = nil
    @State private var similarMachine: NearbyMachine? = nil
    @State private var nearbyMachines: [NearbyMachine] = []
    @State private var nearbyConfirmationPending = false
    @State private var isLoading = false

    @State private var keyboardHeight: CGFloat = 0
    private var keyboardObserver: AnyCancellable?

    init(
        coordinate: CLLocationCoordinate2D,
        areaChoices: [String] = [],
        openExistingMachine: ((String) -> Void)? = nil,
        isExistingMachineVisible: ((String) -> Bool)? = nil,
        isExistingMachineBlocked: ((String) -> Bool)? = nil
    ) {
        coords = coordinate
        self.areaChoices = areaChoices
        self.openExistingMachine = openExistingMachine
        self.isExistingMachineVisible = isExistingMachineVisible
        self.isExistingMachineBlocked = isExistingMachineBlocked
        _selectedLocation = State(initialValue: coords)
        // Observe keyboard frame changes
        keyboardObserver = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .compactMap { $0.userInfo?["UIKeyboardFrameEndUserInfoKey"] as? CGRect }
            .map { $0.height }
            .subscribe(on: DispatchQueue.main)
            .assign(to: \.keyboardHeight, on: self)
    }

    var body: some View {
        ScrollView{
        VStack(alignment: .leading, spacing: 15) {
            Text("Add a new machine")
                .font(.title3)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .center)

            // Name input field
            TextField("Machine title", text: $name)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // Email input field
            TextField("Address", text: $address)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // location
            Section() {
                InteractiveMapView(selectedLocation: $selectedLocation)

                Text("Lat: \(String(format: "%.4f", selectedLocation.latitude)), Lon: \(String(format: "%.4f", selectedLocation.longitude))")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            
            // Area input field
            TextField("Area (Country or US state)", text: $area)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            if !matchingAreas.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(matchingAreas.prefix(5), id: \.self) { areaChoice in
                        Button(action: {
                            area = areaChoice
                        }) {
                            Text(areaChoice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.footnote)
                .padding(.horizontal, 4)
            }

            
            // Paywall checkbox
            Toggle(isOn: $paywall) {
                            Text("Is there a fee / paywall?")
                        }
        
            // Number of coins
            Stepper(value: $numCoins, in: 1...10) {
                Text("Number of coin designs: \(numCoins)")
            }
            .padding(.vertical)

            
            // Button to open the ImagePicker when tapped
            Button(action: {
                isImagePickerPresented = true
            }) {
                Text("Select Image")
                    .padding()
                    .foregroundColor(Color.white)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
                
                // Display the selected image
                if let selectedImage = selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFit()
                }
            }
            .padding()
            
            // Submit button
            if isLoading {
                ProgressView("Loading...")
                    .padding()
            } else {
                Button(action: {
                    submitRequest()
                }) {
                    Text("Submit")
                        .padding()
                        .foregroundColor(Color.white)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(10)
                }.padding().disabled(isLoading)
            }
            
            AlertPresenter(showAlert: $showFinishedAlert, title: "Finished", message: "Thanks for suggesting this machine. We will review this request shortly. Note that it may take a few days until the machine becomes visible.")
                .padding()
        }
        .alert(isPresented: $showAlert) {
            return Alert(title: Text("Could not submit"), message: Text(displayResponse), dismissButton: .default(Text("Dismiss")))
        }
        .padding()
        .navigationBarTitle("Add new machine")
        .sheet(isPresented: $isImagePickerPresented) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .photoLibrary)
        }
        .overlay(warningOverlay)
        }
        .padding(.bottom, keyboardHeight)
    }

    @ViewBuilder
    private var warningOverlay: some View {
        ZStack {
            if let duplicateMachine = duplicateMachine {
                warningBackdrop
                warningBox {
                    Text("A machine with this exact name already exists nearby")
                        .font(.headline)
                    if isExistingMachineBlocked?(duplicateMachine.machineID) == true {
                        Text("You blocked this machine listing.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        machineLine(duplicateMachine)
                        if ["out-of-order", "retired"].contains(duplicateMachine.status) {
                            Text("Cool! You re-discovered a machine that was marked as \(duplicateMachine.status).")
                            Text("Please change its status to 'Active'.")
                        }
                        if isExistingMachineVisible?(duplicateMachine.machineID) == false {
                            Text("You didn't see this machine on the map because in your settings you toggled \(duplicateMachine.status) machines to be invisible.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Button(action: {
                            self.duplicateMachine = nil
                            openExistingMachine?(duplicateMachine.machineID)
                        }) {
                            primaryButtonLabel("Open existing machine")
                        }
                    }
                    Button(action: {
                        self.duplicateMachine = nil
                    }) {
                        secondaryButtonLabel("Cancel")
                    }
                }
            } else if let similarMachine = similarMachine {
                warningBackdrop
                warningBox {
                    Text("A similarly named machine '\(similarMachine.name)' already exists. Pick a more distinct name.")
                        .font(.headline)
                    Button(action: {
                        self.similarMachine = nil
                    }) {
                        primaryButtonLabel("Change name")
                    }
                }
            } else if nearbyConfirmationPending {
                warningBackdrop
                warningBox {
                    Text("\(nearbyMachines.count) Nearby machines found!")
                        .font(.headline)
                    Text("This may already be in PennyMe. Do you still want to submit this machine?")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(nearbyMachines.filter {
                            isExistingMachineBlocked?($0.machineID) != true
                        }) { machine in
                            machineLine(machine)
                        }
                        if nearbyMachines.contains(where: {
                            isExistingMachineBlocked?($0.machineID) == true
                        }) {
                            Text("Some nearby machine listings are hidden because you blocked their contributors.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    Button(action: {
                        nearbyConfirmationPending = false
                        submitRequest(ignoreNearby: true)
                    }) {
                        secondaryButtonLabel("Submit anyway")
                    }
                    Button(action: {
                        nearbyConfirmationPending = false
                    }) {
                        primaryButtonLabel("Cancel")
                    }
                }
            }
        }
    }

    private var warningBackdrop: some View {
        Color.black.opacity(0.3).edgesIgnoringSafeArea(.all)
    }

    private var matchingAreas: [String] {
        let query = area.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return areaChoices.filter {
            $0.localizedCaseInsensitiveContains(query) && $0.caseInsensitiveCompare(query) != .orderedSame
        }
    }

    private var submittedArea: String {
        let query = area.trimmingCharacters(in: .whitespacesAndNewlines)
        return areaChoices.first { $0.caseInsensitiveCompare(query) == .orderedSame } ?? query
    }

    private func warningBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding()
            .frame(maxWidth: 360)
            .background(Color(UIColor.systemBackground))
            .cornerRadius(10)
            .shadow(radius: 8)
            .padding()
    }

    // One-line nearby machine summary with status colored like map pins.
    private func machineLine(_ machine: NearbyMachine) -> Text {
        Text("\(machine.distance)m: \(machine.name) (")
            + Text(machine.status).foregroundColor(machine.statusColor)
            + Text(")")
    }

    private func primaryButtonLabel(_ title: String) -> some View {
        Text(title)
            .padding()
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .background(Color.blue)
            .cornerRadius(10)
    }

    private func secondaryButtonLabel(_ title: String) -> some View {
        Text(title)
            .padding()
            .frame(maxWidth: .infinity)
    }
    
    private func finishLoading(message: String) {
        DispatchQueue.main.async {
            displayResponse = message
            duplicateMachine = nil
            similarMachine = nil
            nearbyConfirmationPending = false
            showAlert = true
            isLoading = false
        }
    }

    // Show a hard stop for a machine that already exists.
    private func showDuplicateMachine(machine: NearbyMachine) {
        DispatchQueue.main.async {
            duplicateMachine = machine
            similarMachine = nil
            nearbyConfirmationPending = false
            isLoading = false
        }
    }

    // Ask for a more distinct title while preserving the form's current input.
    private func showSimilarMachine(machine: NearbyMachine) {
        DispatchQueue.main.async {
            duplicateMachine = nil
            similarMachine = machine
            nearbyConfirmationPending = false
            isLoading = false
        }
    }

    // Show the backend warning for nearby machines and let the user override it.
    private func confirmNearbyMachines(machines: [NearbyMachine]) {
        DispatchQueue.main.async {
            duplicateMachine = nil
            similarMachine = nil
            nearbyMachines = machines
            nearbyConfirmationPending = true
            isLoading = false
        }
    }

    private func imageDataForUpload(_ image: UIImage) -> Data? {
        let maxDimension: CGFloat = 2048
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension else {
            return image.jpegData(compressionQuality: 0.7)
        }

        let scale = maxDimension / longestSide
        let size = CGSize(
            width: floor(image.size.width * scale),
            height: floor(image.size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resizedImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resizedImage.jpegData(compressionQuality: 0.7)
    }

    private func networkErrorMessage(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "The submission could not be sent. Please try again later."
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return "Your device appears to be offline. Connect to the internet and try again."
        case .timedOut:
            return "PennyMe could not confirm whether the submission was received because the request timed out. Please wait before trying again."
        case .networkConnectionLost:
            return "PennyMe could not confirm whether the submission was received because the connection was interrupted. Please wait before trying again."
        default:
            return "PennyMe could not connect to the server (network error \(urlError.code.rawValue)). Please try again later."
        }
    }

    private func serverErrorMessage(statusCode: Int) -> String {
        switch statusCode {
        case 413:
            return "The selected image is too large to upload (error 413). Please choose a smaller image and try again."
        case 408, 504:
            return "The PennyMe server timed out while processing the submission. Please try again later."
        case 500...599:
            return "The PennyMe server could not process the submission (error \(statusCode)). Please try again later."
        default:
            return "The PennyMe server returned an unexpected response (error \(statusCode)). Please try again later."
        }
    }
    
    // Function to handle the submission of the request
    private func submitRequest(ignoreNearby: Bool = false) {
        isLoading = true
        if let reason = TextModeration.blockReason(name) {
            finishLoading(message: reason)
            return
        }
        if name == "" || address == "" || submittedArea == "" || selectedImage == nil {
            finishLoading(message: "Please enter all information & upload image")
        } else {

            // upload image and make request
            if let image = selectedImage {
                //  Convert the image to a data object
                guard let imageData = imageDataForUpload(image) else {
                    print("Failed to convert image to data")
                    finishLoading(message: "Something went wrong with your image")
                    return
                }
                var urlComponents = URLComponents(string: flaskURL)!
                urlComponents.path = "/create_machine"
                urlComponents.queryItems = [
                    URLQueryItem(name: "title", value: name),
                    URLQueryItem(name: "address", value: address),
                    URLQueryItem(name: "area", value: submittedArea),
                    URLQueryItem(name: "multimachine", value: multimachine),
                    URLQueryItem(name:"paywall", value: String(paywall)),
                    URLQueryItem(name:"num_coins", value: String(numCoins)),
                    URLQueryItem(name: "lon_coord", value: "\(selectedLocation.longitude)"),
                    URLQueryItem(name: "lat_coord", value: "\(selectedLocation.latitude)"),
                    URLQueryItem(name: "ignore_nearby", value: String(ignoreNearby)),
                ]
                urlComponents.percentEncodedQuery = urlComponents.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                var request = URLRequest(url: urlComponents.url!)
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
                let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                    if let error = error {
                        print("New machine submission failed: \(error)")
                        finishLoading(message: networkErrorMessage(error))
                        return
                    }
                    // Check if a valid HTTP response was received
                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("New machine submission returned no HTTP response")
                        finishLoading(message: "PennyMe did not receive a valid response from the server. Please try again later.")
                        return
                    }
                    // Extract the status code from the HTTP response
                    let statusCode = httpResponse.statusCode
                    
                    // Check if the status code indicates success (e.g., 200 OK)
                    if 200 ..< 300 ~= statusCode {
                        // everything worked, finish
                        DispatchQueue.main.async {
                            self.showFinishedAlert = true
                            self.presentationMode.wrappedValue.dismiss()
                            isLoading = false
                        }
                    }
                    else if let responseData = data,
                            let jsonObject = try? JSONSerialization.jsonObject(with: responseData),
                            let json = jsonObject as? [String: Any],
                            let answerString = json["error"] as? String {
                        if statusCode == 409,
                           let duplicateJSON = json["duplicate_machine"] as? [String: Any],
                           let duplicateMachine = NearbyMachine(json: duplicateJSON) {
                            showDuplicateMachine(machine: duplicateMachine)
                            return
                        }
                        if statusCode == 409,
                           let similarJSON = json["similar_machine"] as? [String: Any],
                           let similarMachine = NearbyMachine(json: similarJSON) {
                            showSimilarMachine(machine: similarMachine)
                            return
                        }
                        if statusCode == 409,
                           let nearbyJSON = json["nearby_machines"] as? [[String: Any]] {
                            let nearbyMachines = nearbyJSON.compactMap(NearbyMachine.init)
                            if !nearbyMachines.isEmpty {
                                confirmNearbyMachines(machines: nearbyMachines)
                                return
                            }
                        }
                        finishLoading(message: answerString)
                    } else {
                        let responseText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<empty>"
                        print("New machine submission returned HTTP \(statusCode): \(responseText.prefix(500))")
                        finishLoading(message: serverErrorMessage(statusCode: statusCode))
                    }
                }
                task.resume()
            }
        }
    }
}
