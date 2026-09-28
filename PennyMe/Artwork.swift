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
    let address: String
    let area : String
    let link: String
    var status: String
    let coordinate: CLLocationCoordinate2D
    let id: String
    let last_updated: String
    let text: String
    let paywall: Bool
    let multimachine: Int
    var machineStatus: String
    let numCoins: Int
    
    init(title: String, address: String, link: String, status: String, coordinate: CLLocationCoordinate2D, id: Int, last_updated: String, multimachine: Int, paywall: Bool, machineStatus: String, area: String, numCoins: Int) {
        self.title = title
        self.address = address
        self.coordinate = coordinate
        self.link = link
        self.status = status
        self.id = String(id)
        self.last_updated = last_updated
        self.text = self.title! + self.address
        self.multimachine = multimachine
        self.paywall = paywall
        self.area = area
        self.machineStatus = machineStatus
        self.numCoins = numCoins
        
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
        address = (properties["address"] as? String)!
        link = (properties["external_url"] as? String)!
        last_updated = (properties["last_updated"] as? String)!
        id = String((properties["id"] as? Int)!)
        area = String((properties["area"] as? String)!)
      
        // machine is per default active and unvisited
        machineStatus = "available"
        if let statusTemp = properties["machine_status"] as? String {
            machineStatus = statusTemp
        }
        // the user status is unvisited by default
        status = "unvisited"
                
        coordinate = point.coordinate
        
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
        // number of coins - change if exists in dict
        if let numCoinsVal = properties["num_coins"] as? Int {
            numCoins = numCoinsVal
        } else {
            numCoins = 4
        }
        
        text = title! + address + id
        super.init()
    }
    
    
    var subtitle: String? {
        return address
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
    
    func getPaywallSymbol() -> UIImageView? {
        if self.paywall {
            let paywallImageView = UIImageView (
                frame: CGRect(origin: CGPoint.zero,
                              size: CGSize(width: 30, height: 30))
            )
            if #available(iOS 13.0, *) {
                let dollarImage = UIImage(systemName: "dollarsign", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .bold, scale: .large))?.withTintColor(.red, renderingMode: .alwaysOriginal)
                paywallImageView.image = dollarImage
            }
            return paywallImageView
        }
        else {
            return nil
        }
    }
    
    var markerTintColor: UIColor  {
        if (machineStatus != "available") && (status == "unvisited") {
            return .gray
        }
        else if status == "unvisited" {
            return .red
        }
        else if status == "visited" {
            return .green
        }
        else if status == "marked" {
            return .yellow
        }
        else {
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

/// Snapshot of the server-derived fields of an `Artwork`, persisted on-disk so a prior
/// app launch's full server state survives across restarts (see `ViewController`'s
/// `cachedMachinesURL`/`loadCachedMachines`/`persistCachedMachines`). Excludes the
/// per-device `status`, which is tracked separately in `pin_status.json`.
struct CachedArtwork: Codable {
    let id: Int
    let title: String
    let address: String
    let link: String
    let lastUpdated: String
    let multimachine: Int
    let paywall: Bool
    let machineStatus: String
    let area: String
    let numCoins: Int
    let latitude: Double
    let longitude: Double
}

extension Artwork {
    var cacheSnapshot: CachedArtwork {
        CachedArtwork(
            id: Int(id) ?? 0,
            title: title ?? "",
            address: address,
            link: link,
            lastUpdated: last_updated,
            multimachine: multimachine,
            paywall: paywall,
            machineStatus: machineStatus,
            area: area,
            numCoins: numCoins,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    convenience init(cached: CachedArtwork) {
        self.init(
            title: cached.title,
            address: cached.address,
            link: cached.link,
            status: "unvisited",
            coordinate: CLLocationCoordinate2D(latitude: cached.latitude, longitude: cached.longitude),
            id: cached.id,
            last_updated: cached.lastUpdated,
            multimachine: cached.multimachine,
            paywall: cached.paywall,
            machineStatus: cached.machineStatus,
            area: cached.area,
            numCoins: cached.numCoins
        )
    }
}

