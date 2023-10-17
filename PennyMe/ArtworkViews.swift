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
            // define subtitle subtitles
            let detailLabel = UILabel()
            detailLabel.numberOfLines = 0
            detailLabel.font = detailLabel.font.withSize(12)
            
            // 1
            let check = newValue?.title
            if check == "New Machine"{
                guard let newmachine = newValue as? NewMachine else {
                    return
                }
                // define annotation view
                var view: MKMarkerAnnotationView
                let identifier = "newmachine"
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.canShowCallout = true
                view.calloutOffset = CGPoint(x: -5, y: 5)
                
                // add callouts (only address as subtitle)
                detailLabel.text = newmachine.text
                detailCalloutAccessoryView = detailLabel
                rightCalloutAccessoryView = nil
                leftCalloutAccessoryView = nil
            }
            else {
                guard let artwork = newValue as? Artwork else {
                    return
                }
                clusterPins = UserDefaults.standard.bool(forKey: "clusterPinSwitch")
                
                if !clusterPins {
                    displayPriority = MKFeatureDisplayPriority.required
                }
                
                // define annotation view
                var view: MKMarkerAnnotationView
                let identifier = artwork.title
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.canShowCallout = true
                view.calloutOffset = CGPoint(x: -5, y: 5)
                
                // Set marker color
                markerTintColor = artwork.markerTintColor
                
                // Create right button
                rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
                let mapsButton = UIButton(
                    frame: CGRect(origin: CGPoint.zero,
                                  size: CGSize(width: 30, height: 30))
                )
                mapsButton.setBackgroundImage(UIImage(named: "maps"), for: UIControl.State())
                rightCalloutAccessoryView = mapsButton
                
                // Multiline subtitles
                detailLabel.text = artwork.subtitle
                detailCalloutAccessoryView = detailLabel
                
                // create left paywall image if required
                leftCalloutAccessoryView = artwork.getPaywallSymbol()
            }
        }
    }
}
