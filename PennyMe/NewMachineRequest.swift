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
struct RequestFormView: View {
    let coords: CLLocationCoordinate2D
    // Properties to hold user input
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var area: String = ""
    @State private var paywall: Bool = false
    @State private var multimachine: String = ""
    @State private var showFinishedAlert = false
    @State private var submittedName: String = ""
    @Environment(\.presentationMode) private var presentationMode // Access the presentationMode environment variable
    @State private var selectedImage: UIImage? = nil
    @State private var isImagePickerPresented: Bool = false
    
    var body: some View {
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
            Button(action: {
                submitRequest()
                showFinishedAlert = true
            }) {
                Text("Submit")
                    .padding()
                    .foregroundColor(Color.white)
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)
            }.padding()
            
            // Enter all info
            Text("\(submittedName)").foregroundColor(Color.red)
            
            AlertPresenter(showAlert: $showFinishedAlert, title: "Finished", message: "Thanks for adding this machine. We will review this request and the machine will be added shortly.")
                .padding()
        }
        .padding()
        .navigationBarTitle("Add new machine")
        .sheet(isPresented: $isImagePickerPresented) {
            ImagePicker(selectedImage: $selectedImage, sourceType: .photoLibrary)
        }
    }
    
    // Function to handle the submission of the request
    private func submitRequest() {
        if name == "" || address == "" || area == "" || selectedImage == nil {
            submittedName = "Please enter all information & upload image"
        } else {
            // correct multimachine information
            if multimachine == "" {
                multimachine = "1"
            }
            
            showFinishedAlert = true
            presentationMode.wrappedValue.dismiss()
        
            // upload image and make request
            if let image = selectedImage! as UIImage ?? nil {
                //  Convert the image to a data object
                guard let imageData = image.jpegData(compressionQuality: 1.0) else {
                    print("Failed to convert image to data")
                    return
                }
                // call flask method called create_machine
                guard let url = URL(string: flaskURL+"/create_machine?title=\(name)&address=\(address)&lat_coord=\(coords.latitude)&lon_coord=\(coords.longitude)&multimachine=\(multimachine)&paywall=\(paywall)&area=\(area)"
                ) else {
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
                        print("Error: \(error)")
                        return
                    }
                }
                task.resume()
            }
        }
    }
}
