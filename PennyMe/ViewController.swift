//
//  ViewController.swift
//  PennyMe
//
//  Created by Jannis Born on 11.08.19.
//  Copyright © 2019 Jannis Born. All rights reserved.
//

import UIKit
import MapKit
import CoreLocation
import Contacts


@available(iOS 13.0, *)
class ViewController: UIViewController, UITextFieldDelegate {

    @IBOutlet weak var PennyMap: MKMapView!
    
    let locationManager = CLLocationManager()
    let regionInMeters: Double = 10000
    // Array for annotation database
    var artworks: [Artwork] = []

    

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        // Check and enable localization (blue dot)
        checkLocationServices()
        
        
        // Map initialization goes here:
        PennyMap.delegate = self
        PennyMap.showsScale = true
        PennyMap.showsPointsOfInterest = true
        
        loadInitialData()
        PennyMap.addAnnotations(artworks)

        let button = UIButton()
        button.frame = CGRect(x: 150, y: 150, width: 100, height: 50)
        self.view.addSubview(button)
        
    }
    
    
    // Check if global location services are enabled
    func checkLocationServices() {
        if CLLocationManager.locationServicesEnabled() {
            setupLocationManager()
            checkLocationAuthorization()
        } else {
            // Show alert to tell user to turn on location services
        }
    }

    func setupLocationManager(){
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    // Check whether this app has location permission
    func checkLocationAuthorization() {
        switch CLLocationManager.authorizationStatus(){
        case .authorizedWhenInUse:
            PennyMap.showsUserLocation = true
            centerViewOnUserLocation()
            //locationManager.startUpdatingLocation()
            break
        case .denied:
            // Show alert instructing how to turn on permissions
            break
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            break
        case .restricted:
            // Show alert that location can not be accessed
            break
        case .authorizedAlways:
            break
        }
    }
    
    // Set the initial map location
    func centerViewOnUserLocation() {
        // Default to user location if accessible
        if let location = locationManager.location?.coordinate{
            let region = MKCoordinateRegion.init(
                center:location,
                latitudinalMeters: regionInMeters,
                longitudinalMeters: regionInMeters
            )
            PennyMap.setRegion(region, animated: true)
        } else { // goes to Uetliberg otherwise
            let location = CLLocationCoordinate2D(
                latitude: 47.349586,
                longitude: 8.491197
            )
            let region = MKCoordinateRegion.init(
                center:location,
                latitudinalMeters: regionInMeters,
                longitudinalMeters: regionInMeters
            )
            PennyMap.setRegion(region, animated: true)
        }
    }
    
    // To load machine locations from JSON
    @available(iOS 13.0, *)
    func loadInitialData() {
        // Parse the geoJSON data from all_locations.json
        guard let fileName = Bundle.main.path(forResource: "all_locations", ofType: "json")
            else { return }
        let artworkData = try? Data(contentsOf: URL(fileURLWithPath: fileName))
        
        do {
          // 2
          let features = try MKGeoJSONDecoder()
            .decode(artworkData!)
            .compactMap { $0 as? MKGeoJSONFeature }
          // 3
          let validWorks = features.compactMap(Artwork.init)
          // 4
          artworks.append(contentsOf: validWorks)
        } catch {
          // 5
          print("Unexpected error: \(error).")
        }
    }
}


@available(iOS 13.0, *)
extension ViewController: MKMapViewDelegate {
    // 1
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {

        // Eventually possible?? Update location position
        //        PennyMap.setCenter(userLocation.coordinate, animated: true)


        // 2
        guard let annotation = annotation as? Artwork else { return nil }
        // 3
        let identifier = "marker"
        var view: MKMarkerAnnotationView
        // 4
        if let dequeuedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView {
            dequeuedView.annotation = annotation
            view = dequeuedView
        } else {
            // 5
            view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.canShowCallout = true
            view.calloutOffset = CGPoint(x: -5, y: 5)
            
            // Create left and right buttons
            view.leftCalloutAccessoryView = UIButton(type: .detailDisclosure)
            
            let mapsButton = UIButton(
                frame: CGRect(origin: CGPoint.zero,
                size: CGSize(width: 30, height: 30))
            )
            mapsButton.setBackgroundImage(UIImage(named: "GO-Button"), for: UIControl.State()
            )
            view.rightCalloutAccessoryView = mapsButton
        }
        return view
    }
    
    
    
    

    
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                 calloutAccessoryControlTapped control: UIControl) {
        let location = view.annotation as! Artwork
        
        if (control == view.rightCalloutAccessoryView) {
            // This would open the directions
            let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
            location.mapItem().openInMaps(launchOptions: launchOptions)
        }
        else {
            //Open the website when you click on the link.
            UIApplication.shared.openURL(URL(string: location.link)!)
        }

        

    }
    

}



// Global handling of GPS  localization issues
@available(iOS 13.0, *)
extension ViewController: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations : [CLLocation]) {
        // Update position on map
        guard let location = locations.last else {return}
        // Below code only executes if locations.last exists
        let center = CLLocationCoordinate2D(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: regionInMeters,
            longitudinalMeters: regionInMeters
        )
        PennyMap.setRegion(region, animated: true)



    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // called if authorization has changed
        checkLocationAuthorization()
    }
}



