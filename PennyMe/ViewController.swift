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
    @IBOutlet weak var ownLocation: UIButton!
    @IBOutlet var toggleMapButton: UIButton!
    
    //    For search results
    @IBOutlet var searchFooter: SearchFooter!
    @IBOutlet var searchFooterBottomConstraint: NSLayoutConstraint!
    @IBOutlet var tableView: UITableView!
    
    @IBOutlet weak var settingsbutton: UIButton!
    
    let locationManager = CLLocationManager()
    let regionInMeters: Double = 10000
    // Array for annotation database
    var artworks: [Artwork] = []
    var selectedPin: Artwork?
    
    // Searchbar variables
    let searchController = UISearchController(searchResultsController: nil)
    var filteredArtworks: [Artwork] = []
    
    // To display the search results
    lazy var locationResult : UITableView = UITableView(frame: PennyMap.frame)
    var tableShown: Bool = false
    
    //  Map type + button
    var currMap = 1
    let satelliteButton = UIButton(frame: CGRect(x: 10, y: 510, width: 50, height: 50))
    @IBOutlet weak var mapType : UISegmentedControl!


    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view, typically from a nib.
        artworks = Artwork.artworks()

        
        // Set up search bar
        searchController.searchResultsUpdater = self
        // Results should be displayed in same searchbar as used for searching
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search penny machines"
        searchController.hidesNavigationBarDuringPresentation = false
        // iOS 11 compatability issue
        navigationItem.searchController = searchController
        // Disable search bar if view is changed
        definesPresentationContext = true
        

        // Check and enable localization (blue dot)
        checkLocationServices()
        
        // Map initialization goes here:
        setDelegates()
        
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
        addSettingsButton()
        toggleMapTypeButton()
    
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // each time the view appears, check colours of the pins
        check_json_dict()
    }
    
    func setDelegates(){
        PennyMap.delegate = self
        PennyMap.showsScale = true
        PennyMap.showsPointsOfInterest = true
        locationResult.delegate = self
        locationResult.dataSource = self
        searchController.searchBar.delegate = self
    }
    
    
    // center to own location
    func addMapTrackingButton(){
        let image = UIImage(systemName: "location", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold, scale: .large))?.withTintColor(.black)
        ownLocation.backgroundColor = .white
        ownLocation.layer.cornerRadius = 0.5 * ownLocation.bounds.size.width
        ownLocation.clipsToBounds = true
        ownLocation.setImage(image, for: .normal)
        ownLocation.imageView?.contentMode = .scaleAspectFit
        ownLocation.addTarget(self, action: #selector(ViewController.centerMapOnUserButtonClicked), for: .touchUpInside)
        PennyMap.addSubview(ownLocation)
    }
    
    func addSettingsButton(){
        let image = UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold, scale: .large))?.withTintColor(.gray)
        settingsbutton.backgroundColor = .white
        settingsbutton.layer.cornerRadius = 0.5 * settingsbutton.bounds.size.width
        settingsbutton.clipsToBounds = true
        settingsbutton.setImage(image, for: .normal)
        settingsbutton.imageView?.contentMode = .scaleAspectFit
        PennyMap.addSubview(settingsbutton)
    }
    
    
    
    func toggleMapTypeButton(){
        
        var toggleMapImage:UIImage = UIImage(named: "map_symbol_without_border")!
        toggleMapImage = toggleMapImage.withRenderingMode(UIImage.RenderingMode.alwaysOriginal)
        
        toggleMapButton.setImage(toggleMapImage, for: .normal)
        toggleMapButton.imageView?.contentMode = .scaleAspectFit
        toggleMapButton.addTarget(self, action: #selector(changeMapType), for: .touchUpInside)
        self.view.addSubview(toggleMapButton)
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
    
    func check_json_dict(){
//        print("checking json dictionary")
        // initialize empty status dictionary
        var statusDict = [[String: String]()]
        //variable indicating whether we load something
        var is_empty = true
        // whole stuff required to read file
        let documentsDirectoryPathString = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let documentsDirectoryPath = NSURL(string: documentsDirectoryPathString)!
        let jsonFilePath = documentsDirectoryPath.appendingPathComponent("pin_status.json")
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: jsonFilePath!.absoluteString, isDirectory: &isDirectory) {
//            print("file path exists, try load data")
            do{
                let data = try Data(contentsOf: URL(fileURLWithPath: jsonFilePath!.absoluteString), options:.mappedIfSafe)
                
                let jsonResult = try JSONSerialization.jsonObject(with: data, options: .mutableLeaves)
                statusDict = jsonResult as! [[String:String]]
                is_empty = false
            }
            catch{
                print("file already exists but could not be read", error)
            }
        }
        // If we have saved some already:
        if !is_empty{
//            print("updating with vals from json")
            let titles_in_dict = Array(statusDict[0].keys)
            for machine in artworks{
                if titles_in_dict.contains(machine.id){
//                    print("changed", machine.title!)
                    // remove old color and add new one
                    PennyMap.removeAnnotation(machine)
                    machine.status = statusDict[0][machine.id] ?? "unvisited"
                    PennyMap.addAnnotation(machine)
                }
            }
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
          let validWorks = features.compactMap(Artwork.init)
          artworks.append(contentsOf: validWorks)
        } catch {
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
    filteredArtworks = artworks.filter { (artwork: Artwork) -> Bool in
        return artwork.title!.lowercased().contains(searchText.lowercased())
        }
        
        // This sets the table view frame to cover exactly the entire underlying map
        locationResult.frame = PennyMap.bounds
        
        // Default height of table view cell is 44 - locationResult.rowHeight does not work
        let height = CGFloat(filteredArtworks.count * 44)
        if height < PennyMap.bounds.height{
            var tableFrame = locationResult.frame
            tableFrame.size.height = height
            locationResult.frame = tableFrame
        }
        
        if !tableShown {
            PennyMap.addSubview(locationResult)
            tableShown = true
        }
        locationResult.reloadData()
    }
    
    // Whether we are currently filtering
    var isFiltering: Bool {
      return searchController.isActive && !isSearchBarEmpty
    }
    
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if (segue.identifier == "ShowPinViewController") {
            let destinationViewController = segue.destination as! PinViewController
            destinationViewController.pinData = self.selectedPin!
        }
        
    }
    
    @objc func changeMapType(sender: UIButton!) {
         switch currMap{
             case 1:
                PennyMap.mapType = .satellite
                 currMap = 2
             case 2:
                PennyMap.mapType = .hybrid
                 currMap = 3
             default:
                PennyMap.mapType = .standard
                 currMap = 1
         }
    }
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
    
    // Display the penny pin options and execture the search only if a string is entered
    // Makes sure that list is not displayed if cancel is pressed
    if searchBar.text!.count > 0 {
        filterContentForSearchText(searchBar.text!)
    }
    
//    let category = Candy.Category(rawValue:
//      searchBar.scopeButtonTitles![searchBar.selectedScopeButtonIndex])
//    filterContentForSearchText(searchBar.text!, category: category)
  }
}

@available(iOS 13.0, *)
extension ViewController: UISearchBarDelegate {
    
    //  Cancel button execution
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        locationResult.removeFromSuperview()
        tableShown = false
    }

}

// Table with search results
@available(iOS 13.0, *)
extension ViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "location")
        
//        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
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
    
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isFiltering {
          return filteredArtworks.count
        }
        return artworks.count
      if isFiltering {
        searchFooter.setIsFilteringToShow(filteredItemCount:
          filteredArtworks.count, of: artworks.count)
        return filteredArtworks.count
      }

      searchFooter.setNotFiltering()
      return artworks.count
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath){
        self.selectedPin = filteredArtworks[indexPath.row]
        // TODO: update map location to selected
        let center = self.selectedPin!.coordinate
        let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        self.PennyMap.setRegion(region, animated: true)
        locationResult.removeFromSuperview()
        tableShown = false
        searchController.searchBar.text = ""
        
        self.performSegue(withIdentifier: "ShowPinViewController", sender: self)
    }
}

extension UISearchBar {

    private var textField: UITextField? {
        return subviews.first?.subviews.compactMap { $0 as? UITextField }.first
    }

    private var activityIndicator: UIActivityIndicatorView? {
        return textField?.leftView?.subviews.compactMap{ $0 as? UIActivityIndicatorView }.first
    }

    var isLoading: Bool {
        get {
            return activityIndicator != nil
        } set {
            if newValue {
                if activityIndicator == nil {
                    let newActivityIndicator = UIActivityIndicatorView(style: .gray)
                    newActivityIndicator.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
                    newActivityIndicator.startAnimating()
                    newActivityIndicator.backgroundColor = UIColor.white
                    textField?.leftView?.addSubview(newActivityIndicator)
                    let leftViewSize = textField?.leftView?.frame.size ?? CGSize.zero
                    newActivityIndicator.center = CGPoint(x: leftViewSize.width/2, y: leftViewSize.height/2)
                }
            } else {
                activityIndicator?.removeFromSuperview()
            }
        }
    }
}
