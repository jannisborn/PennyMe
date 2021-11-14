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
  override var annotation: MKAnnotation? {
    willSet {
      // 1
      guard let artwork = newValue as? Artwork else {
        return
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

    }
  }
}
