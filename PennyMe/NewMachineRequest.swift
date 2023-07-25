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
            
            // Message input field
//            TextEditor(text: $message)
//                .padding()
//                .frame(height: 150)
//                .border(Color.gray, width: 1)
            
            Text("\(submittedName)").foregroundColor(.red)
            
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
        if name == "" || address == "" {
            submittedName = "Please enter all information"
        } else {
            // TODO: send to backend
            print(coords, name, address)
            showFinishedAlert = true
            presentationMode.wrappedValue.dismiss()
        }
    }
}
