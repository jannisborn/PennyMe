//
//  ArtworkViews.swift
//  PennyMe
//
//  Created by Jannis Born on 05.04.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import Foundation
import MapKit

class ArtworkMarkerView: MKMarkerAnnotationView {

  var clusterPins: Bool = true
  override var annotation: MKAnnotation? {

    willSet {
      // 1
        let check = newValue?.title
        if check == "New Machine"{
            guard let newmachine = newValue as? NewMachine else {
                return
            }
            // Create view when marker is pressed
            let identifier = "markerNewMachine"
            var view: MKMarkerAnnotationView
            view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.canShowCallout = true
            view.calloutOffset = CGPoint(x: 0, y: 0)
           // Multiline subtitles
           let detailLabel = UILabel()
           detailLabel.numberOfLines = 0
           detailLabel.font = detailLabel.font.withSize(12)
           detailLabel.text = newmachine.text
           detailCalloutAccessoryView = detailLabel
           rightCalloutAccessoryView = nil
        }
        else {
            guard let artwork = newValue as? Artwork else {
                return
            }
            clusterPins = UserDefaults.standard.bool(forKey: "clusterPinSwitch")
        
            if !clusterPins {
                displayPriority = MKFeatureDisplayPriority.required
            }

            // Set marker color
            markerTintColor = artwork.markerTintColor
            
            // Create view when marker is pressed
            let identifier = "marker"
            var view: MKMarkerAnnotationView
            view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.canShowCallout = true
            view.calloutOffset = CGPoint(x: -5, y: 5)
            
            // Create right button
            rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            let mapsButton = UIButton(
                frame: CGRect(origin: CGPoint.zero,
                              size: CGSize(width: 30, height: 30))
            )
            mapsButton.setBackgroundImage(UIImage(named: "maps"), for: UIControl.State())
            rightCalloutAccessoryView = mapsButton
            
            // Multiline subtitles
            let detailLabel = UILabel()
            detailLabel.numberOfLines = 0
            detailLabel.font = detailLabel.font.withSize(12)
            detailLabel.text = artwork.subtitle
            detailCalloutAccessoryView = detailLabel

            // create left button
            if artwork.paywall {
                let paywallImageView = UIImageView (
                    frame: CGRect(origin: CGPoint.zero,
                    size: CGSize(width: 30, height: 30))
                )
                if #available(iOS 13.0, *) {
                    let dollarImage = UIImage(systemName: "dollarsign", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .bold, scale: .large))?.withTintColor(.red, renderingMode: .alwaysOriginal)
                    paywallImageView.image = dollarImage
                }
                leftCalloutAccessoryView = paywallImageView
            }
    }
  }
}
