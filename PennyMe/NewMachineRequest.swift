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
            showAlert = false
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
    @State private var paywall: String = "0"
    @State private var multimachine: String = "1"
    @State private var showFinishedAlert = false
    @State private var submittedName: String = ""
    @Environment(\.presentationMode) private var presentationMode // Access the presentationMode environment variable

    
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
            
            // Paywall input field
            Text("Paywall? (Change to 1 if there is a fee to visit the machine)")
            TextField("Paywall", text: $paywall)
                .padding()
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            // Multimachine input field
            Text("Multi-machines? (Change if there are multiple machines at this location)")
            TextField("Number of machines", text: $multimachine)
                .padding()
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            Text("\(submittedName)").foregroundColor(.red)
            
            Text("When submitting, you will be ask to upload a photo for the machine.").foregroundColor(.white)
            // Submit button
            Button(action: submitRequest) {
                Text("Submit")
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .cornerRadius(10)

            AlertPresenter(showAlert: $showFinishedAlert, title: "Finished", message: "Thanks for adding this machine. We will review this request and the machine will be added shortly.")
            }
            .padding()
            
        }
        .padding()
        .navigationBarTitle("Submit Request")
    }
    
    // Function to handle the submission of the request
    private func submitRequest() {
        if name == "" || address == "" || area == "" || paywall == "" || multimachine == "" {
            submittedName = "Please enter all information"
        } else {
            
            if let request = "/create_machine?title=\(name)&address=\(address)&lat_coord=\(coords.latitude)&lon_coord=\(coords.longitude)&multimachine=\(multimachine)&paywall=\(paywall)&area=\(area)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed){
                //                let urlEncodedStringRequest = BaseURL + request
                let urlEncodedStringRequest = flaskURL + request
                
                if let url = URL(string: urlEncodedStringRequest){
                    let task = URLSession.shared.dataTask(with: url) {[ self](data, response, error) in
                        if let error = error {
                            print("Error: \(error)")
                            return
                        }
                        DispatchQueue.main.async {
                            showFinishedAlert = true
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    task.resume()
                }
            }
        }
    }
}
