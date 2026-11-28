//
//  ArtworkViews.swift
//  PennyMe
//
//  Created by Jannis Born on 05.04.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import Foundation
import MapKit

final class OverlappingMachinesAnnotation: NSObject, MKAnnotation {
    let machines: [Artwork]
    let coordinate: CLLocationCoordinate2D

    init(machines: [Artwork], coordinate: CLLocationCoordinate2D) {
        self.machines = machines
        self.coordinate = coordinate
    }
}

final class ArtworkMarkerView: MKMarkerAnnotationView {
    var openDetails: ((MKAnnotation) -> Void)?
    private lazy var selectedPinTap = UITapGestureRecognizer(target: self, action: #selector(openPin))

    override func prepareForDisplay() {
        super.prepareForDisplay()
        let artwork = annotation as? Artwork
        let newMachine = annotation as? NewMachine
        markerTintColor = artwork?.markerTintColor
        titleVisibility = .adaptive
        canShowCallout = true
        calloutOffset = CGPoint(x: -5, y: 5)

        let details = UIButton(type: .custom)
        details.setTitle(artwork?.subtitle ?? newMachine?.text, for: .normal)
        details.setTitleColor(.label, for: .normal)
        details.titleLabel?.font = .systemFont(ofSize: 12)
        details.titleLabel?.numberOfLines = 0
        details.titleLabel?.lineBreakMode = .byWordWrapping
        details.contentHorizontalAlignment = .leading
        details.addTarget(self, action: #selector(openPin), for: .touchUpInside)
        detailCalloutAccessoryView = details
        leftCalloutAccessoryView = artwork?.getPaywallSymbol()

        rightCalloutAccessoryView = nil
        if artwork != nil {
            let mapsButton = UIButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
            mapsButton.setBackgroundImage(UIImage(named: "maps"), for: .normal)
            mapsButton.accessibilityLabel = "Walking directions in Maps"
            rightCalloutAccessoryView = mapsButton
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        if selected {
            addGestureRecognizer(selectedPinTap)
        } else {
            removeGestureRecognizer(selectedPinTap)
        }
    }

    @objc private func openPin() {
        if let annotation { openDetails?(annotation) }
    }
}
