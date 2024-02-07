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
    @State private var multimachine: String = ""
    @State private var showFinishedAlert = false
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
        // Observe keyboard frame changes
        keyboardObserver = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
            .compactMap { $0.userInfo?["UIKeyboardFrameEndUserInfoKey"] as? CGRect }
            .map { $0.height }
            .subscribe(on: DispatchQueue.main)
            .assign(to: \.keyboardHeight, on: self)
    }

    var body: some View {
        ScrollView{
        VStack {
            // Name input field
            TextField("Machine title", text: $name)
                .padding()
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // Email input field
            TextField("Address", text: $address)
                .padding()
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // Area input field
            TextField("Area (Country or US state)", text: $area)
                .padding()
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // Multimachine input field
//            Text("Multi-machines? (Change if there are multiple machines)")
            TextField("Number of machines (leave empty if 1)", text: $multimachine)
                .padding()
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // Paywall checkbox
            Toggle(isOn: $paywall) {
                            Text("Is there a fee / paywall?")
                        }
                        .padding()
            
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
            
            AlertPresenter(showAlert: $showFinishedAlert, title: "Finished", message: "Thanks for suggesting this machine. We will review this request shortly. Note that it can take up to a few days until the machine becomes visible.")
                .padding()
        }
        .alert(isPresented: $showAlert) {
                    Alert(title: Text("Attention!"), message: Text(displayResponse), dismissButton: .default(Text("Dismiss")))
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
            // correct multimachine information
            if multimachine == "" {
                multimachine = "1"
            }
            // upload image and make request
            if let image = selectedImage! as UIImage ?? nil {
                //  Convert the image to a data object
                guard let imageData = image.jpegData(compressionQuality: 1.0) else {
                    print("Failed to convert image to data")
                    finishLoading(message: "Something went wrong with your image")
                    return
                }
                let addressCleaned = address.replacingOccurrences(of: "?", with: "%3f").replacingOccurrences(of: "+", with: "%2b").replacingOccurrences(of: "=", with: "%3d").replacingOccurrences(of: "&", with: "%26")
                let titleCleaned = name.replacingOccurrences(of: "?", with: "%3f").replacingOccurrences(of: "+", with: "%2b").replacingOccurrences(of: "=", with: "%3d").replacingOccurrences(of: "&", with: "%26")
                let areaCleaned = area.replacingOccurrences(of: "?", with: "%3f").replacingOccurrences(of: "+", with: "%2b").replacingOccurrences(of: "=", with: "%3d").replacingOccurrences(of: "&", with: "%26")
                
                // call flask method called create_machine
                let urlString = flaskURL+"/create_machine?title=\(titleCleaned)&address=\(addressCleaned)&lat_coord=\(coords.latitude)&lon_coord=\(coords.longitude)&multimachine=\(multimachine)&paywall=\(paywall)&area=\(areaCleaned)"
                guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "None"
                ) else {
                    finishLoading(message: "Something went wrong. Please try to re-enter the information")
                    return
                }
                var request = URLRequest(url: url)
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
