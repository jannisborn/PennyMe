//
//  ImagePickerHelper.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 01.08.23.
//  Copyright © 2023 Jannis Born. All rights reserved.
//

import Foundation
import Photos
import SwiftUI
import UIKit

@available(iOS 13.0, *)
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImage: UIImage?
    @Environment(\.presentationMode) private var presentationMode

    // Add a new property for the source type (camera or photo library)
    var sourceType: UIImagePickerController.SourceType
    var onLocationFound: (CLLocationCoordinate2D) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let imagePicker = UIImagePickerController()
        imagePicker.delegate = context.coordinator

        // Set the source type based on the user's selection
        imagePicker.sourceType = sourceType

        return imagePicker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: ImagePicker

        init(_ imagePicker: ImagePicker) {
            parent = imagePicker
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let selectedImage = info[.originalImage] as? UIImage {
                parent.selectedImage = selectedImage
            }
            if let location = (info[.phAsset] as? PHAsset)?.location {
                parent.onLocationFound(location.coordinate)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
