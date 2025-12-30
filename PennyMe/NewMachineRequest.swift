//
//  NewMachineRequest.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 25.07.23.
//  Copyright © 2023 Jannis Born. All rights reserved.
//

import Foundation
import MapKit

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
    let coords: CLLocationCoordinate2D
    // Properties to hold user input
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var area: String = ""
    @State private var paywall: Bool = false
    @State private var multimachine: String = "1"
    @State private var showFinishedAlert = false
    @State private var selectedLocation: CLLocationCoordinate2D
    @State private var displayResponse: String = ""
    @Environment(\.presentationMode) private var presentationMode // Access the presentationMode environment variable
    @State private var selectedImage: UIImage? = nil
    @State private var isImagePickerPresented: Bool = false
    @State private var showAlert = false
    @State private var isLoading = false

    @State private var keyboardHeight: CGFloat = 0
    private var keyboardObserver: AnyCancellable?

    init(coordinate: CLLocationCoordinate2D) {
        coords = coordinate
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

            
            // Paywall checkbox
            Toggle(isOn: $paywall) {
                            Text("Is there a fee / paywall?")
                        }
            
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
                    Alert(title: Text("Error!"), message: Text(displayResponse), dismissButton: .default(Text("Dismiss")))
                }
        .padding()
        .navigationBarTitle("Add new machine")
        .sheet(isPresented: $isImagePickerPresented) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .photoLibrary)
        }
        }
        .padding(.bottom, keyboardHeight)
    }
    
    private func finishLoading(message: String) {
        displayResponse = message
        showAlert = true
        isLoading = false
    }
    
    // Function to handle the submission of the request
    private func submitRequest() {
        isLoading = true
        if name == "" || address == "" || area == "" || selectedImage == nil {
            finishLoading(message: "Please enter all information & upload image")
        } else {

            // upload image and make request
            if let image = selectedImage! as UIImage ?? nil {
                //  Convert the image to a data object
                guard let imageData = image.jpegData(compressionQuality: 1.0) else {
                    print("Failed to convert image to data")
                    finishLoading(message: "Something went wrong with your image")
                    return
                }
                var urlComponents = URLComponents(string: flaskURL)!
                urlComponents.path = "/create_machine"
                urlComponents.queryItems = [
                    URLQueryItem(name: "title", value: name),
                    URLQueryItem(name: "address", value: address),
                    URLQueryItem(name: "area", value: area),
                    URLQueryItem(name: "multimachine", value: multimachine),
                    URLQueryItem(name:"paywall", value: String(paywall)),
                    URLQueryItem(name: "lon_coord", value: "\(selectedLocation.longitude)"),
                    URLQueryItem(name: "lat_coord", value: "\(selectedLocation.latitude)"),
                ]
                urlComponents.percentEncodedQuery = urlComponents.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
                var request = URLRequest(url: urlComponents.url!)
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
                let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                    if let error = error {
                        finishLoading(message: "Something went wrong. Please check your internet connection and try again")
                        return
                    }
                    // Check if a valid HTTP response was received
                    guard let httpResponse = response as? HTTPURLResponse else {
                        finishLoading(message: "Something went wrong. Please check your internet connection and try again")
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
                    else {
                        if let responseData = data {
                            do {
                                // Parse the JSON response
                                if let json = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
                                    // Handle the JSON data here
                                    if let answerString = json["error"] as? String {
                                        finishLoading(message: answerString)
                                        return
                                    }
                                }
                            } catch {
                                print("JSON parsing error: \(error)")
                                finishLoading(message: "Something went wrong. Please check your internet connection and try again")
                            }
                        }
                    }
                }
                task.resume()
            }
        }
    }
}
