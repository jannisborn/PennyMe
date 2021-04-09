//
//  Artwork.swift
//  PennyMe
//
//  Created by Jannis Born on 21.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import Foundation
import MapKit
import Contacts


class Artwork: NSObject, MKAnnotation {
    let title: String?
    let locationName: String
    let link: String
    let status: String
    let coordinate: CLLocationCoordinate2D
    
    init(title: String, locationName: String, link: String, status: String, coordinate: CLLocationCoordinate2D) {
        self.title = title
        self.locationName = locationName
        self.coordinate = coordinate
        self.link = link
        self.status = status
        
        super.init()
    }
    
    // Read in data from dictionary
    @available(iOS 13.0, *)
    init?(feature: MKGeoJSONFeature) {
      // Extract location and properties from GeoJSON object
      guard
        let point = feature.geometry.first as? MKPointAnnotation,
        let propertiesData = feature.properties,
        let json = try? JSONSerialization.jsonObject(with: propertiesData),
        let properties = json as? [String: Any]
        else {
          return nil
        }
        // Extract class variables
        title = properties["name"] as? String
        locationName = (properties["address"] as? String)!
        link = (properties["external_url"] as? String)!
        status = (properties["status"] as? String)!
        coordinate = point.coordinate
        super.init()
    }
    
    
    var subtitle: String? {
        return locationName
    }
    
    // To get directions in map
    // Annotation right callout accessory opens this mapItem in Maps app
    func mapItem() -> MKMapItem {
        let addressDict = [CNPostalAddressStreetKey: subtitle!]
        let placemark = MKPlacemark(coordinate: coordinate, addressDictionary: addressDict)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = title
        return mapItem
    }
    
    func getLink() -> String {
        return self.link
    }
    
    var markerTintColor: UIColor  {
      switch status {
      case "unvisited":
        return .red
      case "visited":
        return .yellow
      case "collected":
        return .green
      case "retired":
        return .gray
      default:
        return .black
      }
    }
}


