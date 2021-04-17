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
    @IBOutlet weak var own_location: UIButton!
    
    //    For search results
    @IBOutlet var searchFooter: SearchFooter!
    @IBOutlet var tableView: UITableView!
    
    let locationManager = CLLocationManager()
    let regionInMeters: Double = 10000
    // Array for annotation database
    var artworks: [Artwork] = []
    var selectedPin: Artwork?
    
    // Searchbar variables
    let searchController = UISearchController(searchResultsController: nil)
    var filteredArtworks: [Artwork] = []


    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view, typically from a nib.
        artworks = Artwork.artworks()
//        searchBar = UISearchBar()
//        searchBar.sizeToFit()
//        navigationItem.titleView = searchBar
        
        // Set up search bar
        searchController.searchResultsUpdater = self
        // Results should be displayed in same searchbar as used for searching
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search penny machines"
        // iOS 11 compatability issue
        navigationItem.searchController = searchController
        // Disable search bar if view is changed
        definesPresentationContext = true

        // Check and enable localization (blue dot)
        checkLocationServices()
        
        
        // Map initialization goes here:
        PennyMap.delegate = self
        PennyMap.showsScale = true
        PennyMap.showsPointsOfInterest = true
        
        // Register the functions to create annotated pins
        PennyMap.register(
            ArtworkMarkerView.self,
            forAnnotationViewWithReuseIdentifier:MKMapViewDefaultAnnotationViewReuseIdentifier
        )
        loadInitialData()
        PennyMap.addAnnotations(artworks)

        let button = UIButton()
        button.frame = CGRect(x: 150, y: 150, width: 100, height: 50)
        self.view.addSubview(button)
        
        addMapTrackingButton()
        
    }
    
    // center to own location
    func addMapTrackingButton(){
        let image = UIImage(systemName: "location", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold, scale: .large))?.withTintColor(.black)
        own_location.backgroundColor = .white
//        own_location.frame = CGRect(x: UIScreen.main.bounds.width-45, y: UIScreen.main.bounds.height-90, width: 40, height: 40)
        own_location.layer.cornerRadius = 0.5 * own_location.bounds.size.width
        own_location.clipsToBounds = true
        own_location.setImage(image, for: .normal)
        own_location.imageView?.contentMode = .scaleAspectFit
        own_location.addTarget(self, action: #selector(ViewController.centerMapOnUserButtonClicked), for: .touchUpInside)
        PennyMap.addSubview(own_location)
    }

    @objc func centerMapOnUserButtonClicked() {
        self.PennyMap.setUserTrackingMode(MKUserTrackingMode.follow, animated: true)
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
    
    // Search bar functionalities
    var isSearchBarEmpty: Bool {
      return searchController.searchBar.text?.isEmpty ?? true
    }
    
    // Implements the search itself
    func filterContentForSearchText(_ searchText: String,
                                    category: Artwork? = nil) {
        print("FILTERING RESULTS")
    filteredArtworks = artworks.filter { (artwork: Artwork) -> Bool in
        return artwork.title!.lowercased().contains(searchText.lowercased())
        }
        print(filteredArtworks)
      
//      tableView.reloadData()
    }
    // Whether we are currently filtering
    var isFiltering: Bool {
      return searchController.isActive && !isSearchBarEmpty
    }
    
    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      
//      if let indexPath = tableView.indexPathForSelectedRow {
//        tableView.deselectRow(at: indexPath, animated: true)
//      }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
      guard
        segue.identifier == "ShowDetailSegue",
        let indexPath = tableView.indexPathForSelectedRow,
        let pinViewController = segue.destination as? PinViewController
        else {
          return
        }
        let artwork = artworks[indexPath.row]
        pinViewController.artwork = artwork
    }
    


//    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
//        if (segue.identifier == "ShowPinViewController") {
//            let destinationViewController = segue.destination as! PinViewController
//            destinationViewController.pinData = self.selectedPin!
//        }
//    }
}


@available(iOS 13.0, *)
extension ViewController: MKMapViewDelegate {
    
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.calloutTapped))
        view.addGestureRecognizer(gesture)
    }

    @objc func calloutTapped(sender:UITapGestureRecognizer) {
        guard let annotation = (sender.view as? MKAnnotationView)?.annotation as? Artwork else { return }

        let selectedLocation = annotation.title
        // set selected pin to pass it to detail VC
        self.selectedPin = annotation
        self.performSegue(withIdentifier: "ShowPinViewController", sender: self)
    }
    
//     callout when maps button is pressed
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                 calloutAccessoryControlTapped control: UIControl) {
        let location = view.annotation as! Artwork
        if (control == view.rightCalloutAccessoryView) {
            // This would open the directions
            let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
            location.mapItem().openInMaps(launchOptions: launchOptions)
        }
        else {
            self.performSegue(withIdentifier: "ShowPinViewController", sender: nil)
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


// Searchbar updating
@available(iOS 13.0, *)
extension ViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    let searchBar = searchController.searchBar
    print("BEFORE CALLING SERARCH")
    filterContentForSearchText(searchBar.text!)
    
//    let category = Candy.Category(rawValue:
//      searchBar.scopeButtonTitles![searchBar.selectedScopeButtonIndex])
//    filterContentForSearchText(searchBar.text!, category: category)
  }
}

// Table with search results
@available(iOS 13.0, *)
extension ViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let artwork: Artwork
        if isFiltering {
          artwork = filteredArtworks[indexPath.row]
        } else {
          artwork = artworks[indexPath.row]
        }
        cell.textLabel?.text = artwork.title
        cell.detailTextLabel?.text = artwork.locationName
        return cell
    }
    func tableView(_ tableView: UITableView,
                   numberOfRowsInSection section: Int) -> Int {
      return artworks.count
    }
    
    
//    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
//        if isFiltering {
//          return filteredArtworks.count
//        }
//        return artworks.count
//      if isFiltering {
//        searchFooter.setIsFilteringToShow(filteredItemCount:
//          filteredArtworks.count, of: artworks.count)
//        return filteredArtworks.count
//      }
//
//      searchFooter.setNotFiltering()
//      return candies.count
}
