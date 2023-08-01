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
    var status: String
    let coordinate: CLLocationCoordinate2D
    let id: String
    let last_updated: String
    let text: String
    let paywall: Bool
    let multimachine: Int
    
    init(title: String, locationName: String, link: String, status: String, coordinate: CLLocationCoordinate2D, id: Int, last_updated: String, multimachine: Int, paywall: Bool) {
        self.title = title
        self.locationName = locationName
        self.coordinate = coordinate
        self.link = link
        self.status = status
        self.id = String(id)
        self.last_updated = last_updated
        self.text = self.title! + self.locationName
        self.multimachine = multimachine
        self.paywall = paywall
        
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
        last_updated = (properties["last_updated"] as? String)!
        id = String((properties["id"] as? Int)!)
        coordinate = point.coordinate
        text = title! + locationName
        // multimachine - add if exists
        if let multimachine_val = properties["multimachine"] as? Int {
            multimachine = multimachine_val
        } else {
            multimachine = 1
        }
        // paywall - add if exists
        if let paywall_val = properties["paywall"] as? Bool {
            paywall = paywall_val
        } else {
            paywall = false
        }
        
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
        return .green
      case "marked":
        return .yellow
      case "retired":
        return .gray
      default:
        return .black
      }
    }
}

extension Artwork {
  static func artworks() -> [Artwork] {
    guard
      let url = Bundle.main.url(forResource: "candies", withExtension: "json"),
      let data = try? Data(contentsOf: url)
      else {
        return []
    }
    
    do {
      return []
    } catch {
      return []
    }
  }
}

