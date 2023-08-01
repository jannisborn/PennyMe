//
//  NewMachine.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 20.10.22.
//  Copyright © 2022 Jannis Born. All rights reserved.
//

import Foundation

import MapKit
import Contacts


class NewMachine: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    let text: String
    let title: String?
    
    init(coordinate: CLLocationCoordinate2D){
        self.text = "Click to send us a new machine"
        self.title = "New Machine"
        self.coordinate = coordinate
        super.init()
    }
    
    func mapItem() -> MKMapItem {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = self.text
        return mapItem
    }
}
