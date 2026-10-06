//
//  ImagePickerHelper.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 01.08.23.
//  Copyright © 2023 Jannis Born. All rights reserved.
//

import Foundation
import ImageIO
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
        imagePicker.imageExportPreset = .current

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
            let coordinate = (info[.phAsset] as? PHAsset)?.location?.coordinate
                ?? coordinateFromImage(at: info[.imageURL] as? URL)
            if let coordinate = coordinate {
                print("Selected photo GPS: \(coordinate.latitude), \(coordinate.longitude)")
                parent.onLocationFound(coordinate)
            } else {
                print("Selected photo has no accessible GPS metadata")
            }
            parent.presentationMode.wrappedValue.dismiss()
        }

        private func coordinateFromImage(at url: URL?) -> CLLocationCoordinate2D? {
            guard let url = url,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                  let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
                  let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue else {
                return nil
            }

            let latitudeSign = gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S" ? -1.0 : 1.0
            let longitudeSign = gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "W" ? -1.0 : 1.0
            let coordinate = CLLocationCoordinate2D(
                latitude: latitude * latitudeSign,
                longitude: longitude * longitudeSign
            )
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
