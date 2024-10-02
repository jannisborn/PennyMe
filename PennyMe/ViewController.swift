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
import SwiftUI

let locationManager = CLLocationManager()
let LAT_DEGREE_TO_KM = 110.948
let closeNotifyDist = 0.3 // in km, send "you are very close" at this distance
var radius = 20.0

var totalMachines = 0
var visitedCount = 0
var visitedByArea: [String: Int] = [:]

@available(iOS 13.0, *)
class ViewController: UIViewController, UITextFieldDelegate, UIGestureRecognizerDelegate {

    @IBOutlet weak var PennyMap: MKMapView!
    @IBOutlet weak var ownLocation: UIButton!
    @IBOutlet var toggleMapButton: UIButton!
    @IBOutlet weak var userStatsButton: UIButton!
    
    @IBOutlet weak var navigationbar: UINavigationItem!
    
    //    For search results
    @IBOutlet var searchFooter: SearchFooter!
    @IBOutlet var searchFooterBottomConstraint: NSLayoutConstraint!
    @IBOutlet var tableView: UITableView!
    
    @IBOutlet weak var settingsbutton: UIButton!
    
    let regionInMeters: Double = 10000
    // Array for annotation database
    var artworks: [Artwork] = []
    var pinIdDict : [String:Int] = [:]
    var isVisible : [String:Bool] = [:]
    var selectedPin: Artwork?
    var isLoadingServerLocations: Bool = false
    var lastDataLoad: Date?
    
    // variables to handle the toggles on the Settings screen
    var includedStates : [String] = []
    let relevantUserDefauls : [String] = ["unvisitedSwitch", "visitedSwitch", "markedSwitch", "retiredSwitch"]
    let default_switches: [String: Bool] = [
        "unvisitedSwitch": true,
        "visitedSwitch": true,
        "markedSwitch": true,
        "retiredSwitch": false,
        "clusterPinSwitch": false
    ]
    
    // Searchbar variables
    let searchController = UISearchController(searchResultsController: nil)
    var filteredArtworks: [Artwork] = []
    var pastNearby : Array<Int> = []
    // this variable is to notify once when we are very close to a machine (-1 as placeholder)
    var lastClosestID: Int = -1
    
    // To display the search results
    lazy var locationResult : UITableView = UITableView(frame: PennyMap.frame)
    var tableShown: Bool = false
    
    //  Map type + button
    var currMap = 1
    let satelliteButton = UIButton(frame: CGRect(x: 10, y: 510, width: 50, height: 50))
    @IBOutlet weak var mapType : UISegmentedControl!

    // new machine annotation
    var newMachineAnnotation: [MKAnnotation] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        self.navigationbar.standardAppearance = UINavigationBarAppearance()
        self.navigationbar.standardAppearance?.titleTextAttributes = [NSAttributedString.Key.foregroundColor: UIColor.black]


        // Do any additional setup after loading the view, typically from a nib.
        artworks = Artwork.artworks()

        
        // Set up search bar
        searchController.searchResultsUpdater = self
        // Results should be displayed in same searchbar as used for searching
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search penny machines"
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.overrideUserInterfaceStyle = .light
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

        // check settings toggles
        updateIncludedStates()
        
        // load data
        loadInitialData()
        addAnnotationsIteratively()

        let button = UIButton()
        button.frame = CGRect(x: 150, y: 150, width: 100, height: 50)
        self.view.addSubview(button)
        
        addMapTrackingButton()
        addSettingsButton()
        toggleMapTypeButton()
        initUserStatsButton()
        
        // long gesture recognizer
        let lpgr = UILongPressGestureRecognizer(target: self, action:#selector(handleLongPress))
        lpgr.minimumPressDuration = 0.5
        lpgr.delaysTouchesBegan = true
        lpgr.delegate = self
        PennyMap.addGestureRecognizer(lpgr)

        // Check whether version is new
        VersionManager.shared.showVersionInfoAlertIfNeeded()
    }
    
    @objc func handleLongPress(gestureRecognizer: UILongPressGestureRecognizer) {
        let location = gestureRecognizer.location(in: PennyMap)
        let coordinate = PennyMap.convert(location, toCoordinateFrom: PennyMap)
        let annotation = NewMachine(coordinate: coordinate)
        PennyMap.addAnnotation(annotation)
        if gestureRecognizer.state != UIGestureRecognizer.State.ended {
            PennyMap.selectAnnotation(annotation, animated: true)
        }
        self.newMachineAnnotation.append(annotation)
    }
    
    func removeNewMachinePin() -> Void {
        if !newMachineAnnotation.isEmpty {
            PennyMap.removeAnnotations(self.newMachineAnnotation)
            self.newMachineAnnotation = []
        }
    }
        
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        //  Check whether reload has to be triggered
        // only triggered if it's not already running
        if shouldReloadData() && (!isLoadingServerLocations) {
            PennyMap.removeAnnotations(artworks)
            artworks = Artwork.artworks()
            isVisible = [:]
            pinIdDict = [:]
            loadInitialData()
            addAnnotationsIteratively()
        }
        // each time the view appears, check colours of the pins
        check_json_dict()
        // check whether some setting has changed, if yes, reload all data on the map
        if SettingsViewController.hasChanged {
            updateIncludedStates()
            addAnnotationsIteratively()
            SettingsViewController.hasChanged = false
        }
        if SettingsViewController.clusterHasChanged {
            // reload all annotations in that case
            PennyMap.removeAnnotations(artworks)
            isVisible = [:]
            addAnnotationsIteratively()
            SettingsViewController.clusterHasChanged = false

        }
        // always remove pins for new machines if there are any
        removeNewMachinePin()
        
    }

    func updateIncludedStates() {
        includedStates = []
        for userdefault in relevantUserDefauls {
            let user_settings = UserDefaults.standard
            let value = (user_settings.value(forKey: userdefault) as? Bool ?? default_switches[userdefault])
            if value! {
                let partStr = String( userdefault.prefix(userdefault.count - 6))
                includedStates.append(partStr)
            }
        }
    }
    
    func addAnnotationsIteratively() {
        for artwork in artworks {
            // check if this machine should be visible based on the status
            let shouldBeShown = checkMachineShouldBeVisible(status: artwork.status, machineStatus: artwork.machineStatus)
            if (!(isVisible[artwork.id] ?? false)) && shouldBeShown {
                PennyMap.addAnnotation(artwork)
                isVisible[artwork.id] = true
            } else if (isVisible[artwork.id] ?? false) && !shouldBeShown {
                PennyMap.removeAnnotation(artwork)
                isVisible[artwork.id] = false
            }
        }
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
        let image = UIImage(systemName: "location", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold, scale: .large))?.withTintColor(.white)
        ownLocation.backgroundColor = .white
        ownLocation.layer.cornerRadius = 0.5 * ownLocation.bounds.size.width
        ownLocation.clipsToBounds = true
        ownLocation.setImage(image, for: .normal)
        ownLocation.imageView?.contentMode = .scaleAspectFit
        ownLocation.addTarget(self, action: #selector(ViewController.centerMapOnUserButtonClicked), for: .touchUpInside)
        
        // Add shadow
        ownLocation.layer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.25).cgColor
        ownLocation.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        ownLocation.layer.shadowOpacity = 1.0
        ownLocation.layer.shadowRadius = 0.0
        ownLocation.layer.masksToBounds = false
        
        PennyMap.addSubview(ownLocation)
    }
    
    func addSettingsButton(){
        let image = UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold, scale: .large))?.withTintColor(.gray)
        settingsbutton.backgroundColor = .white
        settingsbutton.layer.cornerRadius = 0.5 * settingsbutton.bounds.size.width
        settingsbutton.clipsToBounds = true
        settingsbutton.setImage(image, for: .normal)
        settingsbutton.imageView?.contentMode = .scaleAspectFit

        // Add shadow
        settingsbutton.layer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.25).cgColor
        settingsbutton.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        settingsbutton.layer.shadowOpacity = 1.0
        settingsbutton.layer.shadowRadius = 0.0
        settingsbutton.layer.masksToBounds = false

        PennyMap.addSubview(settingsbutton)
    }
    
    func initUserStatsButton(){
        let image = UIImage(systemName: "person.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold, scale: .large))?.withTintColor(.gray)
        userStatsButton.tintColor = .black
        userStatsButton.backgroundColor = .white
        userStatsButton.layer.cornerRadius = 0.5 * userStatsButton.bounds.size.width
        userStatsButton.clipsToBounds = true
        userStatsButton.setImage(image, for: .normal)
        userStatsButton.imageView?.contentMode = .scaleAspectFit

        // Add shadow
        userStatsButton.layer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.25).cgColor
        userStatsButton.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        userStatsButton.layer.shadowOpacity = 1.0
        userStatsButton.layer.shadowRadius = 0.0
        userStatsButton.layer.masksToBounds = false
        
        PennyMap.addSubview(userStatsButton)
        
    }
    
    func toggleMapTypeButton(){
        
        var toggleMapImage:UIImage = UIImage(named: "map_symbol_without_border")!
        toggleMapImage = toggleMapImage.withRenderingMode(UIImage.RenderingMode.alwaysOriginal)
        toggleMapButton.setImage(toggleMapImage, for: .normal)
        toggleMapButton.imageView?.contentMode = .scaleAspectFit
        toggleMapButton.addTarget(self, action: #selector(changeMapType), for: .touchUpInside)
        
        // Add shadow
        toggleMapButton.layer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.25).cgColor
        toggleMapButton.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
        toggleMapButton.layer.shadowOpacity = 1.0
        toggleMapButton.layer.shadowRadius = 0.0
        toggleMapButton.layer.masksToBounds = false
        toggleMapButton.layer.cornerRadius = 4.0
        
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
        }
    }

    func setupLocationManager(){
        PennyMe.locationManager.delegate = self
        PennyMe.locationManager.desiredAccuracy = kCLLocationAccuracyBest
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
            PennyMe.locationManager.requestWhenInUseAuthorization()
            break
        case .restricted:
            // Show alert that location can not be accessed
            break
        case .authorizedAlways:
            PennyMap.showsUserLocation = true
            centerViewOnUserLocation()
            break
        }
    }
    
    // Set the initial map location
    func centerViewOnUserLocation() {
        // Default to user location if accessible
        if let location = PennyMe.locationManager.location?.coordinate{
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
    
    
    func checkMachineShouldBeVisible(status: String, machineStatus: String) -> Bool {
        //checks based on the status and the current user defaults whether a machine should be visible
        // should be shown if available and status toggle is on, or if not available and retired toggle is on
        return ((includedStates.contains(status) && (machineStatus == "available")) || (includedStates.contains("retired") && (machineStatus != "available")))
    }
    
    func check_json_dict(){
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
        
        // Set visited to zero again
        visitedCount = 0
        visitedByArea = [:]
        
        // If we have saved some already:
        if !is_empty{
            let ids_in_dict = Array(statusDict[0].keys)
            // iterate over saved IDs and update status on map
            for id_machine in ids_in_dict{
                if let pinId = pinIdDict[id_machine] {
                    let machine = artworks[pinId]
                    let personalStatus = statusDict[0][machine.id] ?? "unvisited"
                    machine.status = personalStatus
                    
                    // Count how many machines have the personalStatus "visited"
                    if personalStatus == "visited" {
                        print("Visited machine", machine.id, machine.area)
                        // Increment the total visited count
                        visitedCount += 1
                        
                        // Increment the count for the specific area
                        let area = machine.area ?? "Unknown Area"
                        visitedByArea[area, default: 0] += 1
                    }
                    
                    // check if machine should be displayed based on settings
                    let shouldDisplayMachine = checkMachineShouldBeVisible(status: personalStatus, machineStatus: machine.machineStatus)
                    
                    // remove machine in any case because we need the new pin colour
                    PennyMap.removeAnnotation(machine)
                    isVisible[id_machine] = false
                    // add pin if it should be shown and is not shown at the moment
                    if shouldDisplayMachine {
                        PennyMap.addAnnotation(machine)
                        isVisible[id_machine] = true
                    }
                } else {
                    // Error reason: User has a local change of a machine not in list of artworks.
                    // E.g., if server_locations.json is badly formatted (and user changed one of the server-locations-only-machines)
                    // or if user has local change of a machine not anymore in all_locations.json
                    print("id_machine \(id_machine) not found in pinIdDict")
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
          let features = try MKGeoJSONDecoder()
            .decode(artworkData!)
            .compactMap { $0 as? MKGeoJSONFeature }
          let validWorks = features.compactMap(Artwork.init)
          artworks.append(contentsOf: validWorks)
        // put IDs into a dictionary
            for (ind, pin) in artworks.enumerated(){
                pinIdDict[pin.id] = ind
            }
        } catch {
          print("Unexpected error: \(error).")
        }
        
        // Load json file from server
        loadServerLocations()
    }
    
    func loadServerLocations(){
        isLoadingServerLocations = true
        // load from server
        let link_to_json = "http://37.120.179.15:8000/server_locations.json"
        guard let jsonURL = URL(string: link_to_json) else { return }
        
        DispatchQueue.global().async { [weak self] in
          if let serverJsonData = try? Data(contentsOf: jsonURL) {
                do{
                    let serverJsonAsMap = try MKGeoJSONDecoder()
                        .decode(serverJsonData)
                        .compactMap { $0 as? MKGeoJSONFeature }
                    let pinsFromServer = serverJsonAsMap.compactMap(Artwork.init)
                    var pinsFromServerList: [Artwork] = []
                    pinsFromServerList.append(contentsOf: pinsFromServer)
                
                    DispatchQueue.main.async {
                        // remove all artworks
                        self?.PennyMap.removeAnnotations(self?.artworks ?? [])
                        
                        // update artwork list
                        for pin in pinsFromServerList{
                            // Case 1: pin already exists
                            let pinIndex = self?.pinIdDict[pin.id]
                            if (pinIndex != nil){
                                // overwrite the pin in the list
                                self?.artworks[pinIndex!] = pin
                            }
                            // Case 2: pin is new
                            else{
                                // add to list and to dictionary
                                self?.artworks.append(pin)
                                self?.pinIdDict[pin.id] = (self?.artworks.count ?? 0) - 1
                            }
                        }
                        // re-add annotations here
                        self?.isVisible = [:]
                        self?.addAnnotationsIteratively()
                        
                        // count how many machines we have in total
                        totalMachines = 0
                        for machine in self!.artworks {
                            if machine.machineStatus != "retired" {
                                totalMachines += 1
                            }
                        }
                        
                        // check colours of the pins with user annotations
                        self?.check_json_dict()
                        //                        }
                        self?.lastDataLoad = Date()
                        self?.isLoadingServerLocations = false
                    }
                } catch {
                    self?.isLoadingServerLocations = false
                    // this is an error on our side
                    print("Error in decoding the server locations json file")
                }
                
            }
            else {
                self?.isLoadingServerLocations = false
                DispatchQueue.main.async {
                    self?.showServerNotLoadedAlert()
                }
            }
        }
    }
    private func showServerNotLoadedAlert() {
        let alertController = UIAlertController(title:"Offline mode", message:"The pin information is outdated since the latest data could not be loaded. Check your internet connection.", preferredStyle: .alert)
        let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
        alertController.addAction(okAction)
        present(alertController, animated: true, completion: nil)
    }
    
    // Search bar functionalities
    var isSearchBarEmpty: Bool {
      return searchController.searchBar.text?.isEmpty ?? true
    }
    
    // Implements the search itself
    func filterContentForSearchText(_ searchText: String, category: Artwork? = nil) {
        filteredArtworks = artworks.filter {
            (artwork: Artwork) -> Bool in return artwork.text.lowercased().contains(searchText.lowercased())
        }
        filteredArtworks = filteredArtworks.sorted(by: {$0.title! < $1.title! })
        
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
    
    func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        if let gestureRecognizers = view.gestureRecognizers {
            for gestureRecognizer in gestureRecognizers {
                view.removeGestureRecognizer(gestureRecognizer)
            }
        }
    }

    @objc func calloutTapped(sender:UITapGestureRecognizer) {
        guard let annotation = (sender.view as? MKAnnotationView)?.annotation  else {return}
        // first option: it's a new machine pin - present form
        if let newmachine = annotation as? NewMachine {
            if #available(iOS 14.0, *) {
                let swiftUIViewController = UIHostingController(rootView: NewMachineFormView(coordinate: newmachine.coordinate)
                )
                present(swiftUIViewController, animated: true, completion: removeNewMachinePin)
                
            }
        // second option: it's a regular machine
        } else if let artworkAnnotation = annotation as? Artwork {
            let selectedLocation = artworkAnnotation.title
            // set selected pin to pass it to detail VC
            self.selectedPin = artworkAnnotation
            self.performSegue(withIdentifier: "ShowPinViewController", sender: self)
        } else {return}
    }
    
    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                 calloutAccessoryControlTapped control: UIControl) {
        //     callout when maps button is pressed
        let location = view.annotation as! Artwork
        if (control == view.rightCalloutAccessoryView) {
            // This would open the directions
            let launchOptions = [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking]
            location.mapItem().openInMaps(launchOptions: launchOptions)
        }
    }
}




// Global handling of GPS  localization issues
@available(iOS 13.0, *)
extension ViewController: CLLocationManagerDelegate {
    // location manager fail
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
       manager.stopMonitoringSignificantLocationChanges()
        print("Stopped monitoring because of error", error)
        return
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations : [CLLocation]) {
        // Update position on map
        guard let location = locations.last else {return}

        // Get closest pins
        let lonCurrent = location.coordinate.longitude // 168.823 // 8.5490 // here are we!
        let latCurrent =  location.coordinate.latitude // -44.9408  // 47.3899
        let (pennyCounter, minDist, closestID, foundIndices) = getCandidates(artworks: artworks, curLat: latCurrent, curLon: lonCurrent, radius:radius)
        // check whether we have found any new machines
        let doPush = determinePush(currentNearby: foundIndices)
        if doPush && (pennyCounter > 0){
            let notificationString = "There are \(pennyCounter) machines nearby. The closest is \(round(minDist * 10)/10)km away \(artworks[closestID].title!)"
            pushNotification(notificationString: notificationString)
        }
        // push with other notification if one is really close
        // Do this only once (variable sendVeryCloseNotification)
        if pennyCounter > 0 && minDist < closeNotifyDist && closestID != lastClosestID{
            let notificationString = "You are very close to a Penny! It is only \(round(minDist * 10)/10)km away \(artworks[closestID].title!)"
            pushNotification(notificationString: notificationString)
            // this is to prevent that the "nearby" notification is sent only once (per location)
            lastClosestID = closestID
        }
    }
    
    // Send user a local notification if they have the app running in the bg
    func pushNotification(notificationString: String) {
        // print("SENT PUSH", notificationString)
        let notification = UILocalNotification()
        notification.alertAction = "Check PennyMe"
        notification.alertBody = notificationString
        notification.fireDate = Date(timeIntervalSinceNow: 1)
        UIApplication.shared.scheduleLocalNotification(notification)
    }
    
    func determinePush(currentNearby:Array<Int>) -> Bool {
        // Decide whether a push notification is sent to the user.
        // If any of the found nearby machines has not been nearby at previous lookup, send a notification.
        var doPush = false
        for i in currentNearby {
            if !pastNearby.contains(i) {
                doPush = true
                break
            }
        }
        self.pastNearby = currentNearby
        return doPush
    }

    // Function to measure distances to pins
    func getCoordinateRange(lat: Double, long: Double, radius: Double) -> (Double, Double, Double, Double) {
        
        // Determine the range of latitude/longitude values that we have to search
        let latDegreeChange = radius / LAT_DEGREE_TO_KM
        let longDegreeChange = radius / (LAT_DEGREE_TO_KM * cos(lat*(Double.pi/180)))
        let minLat = lat - latDegreeChange
        let maxLat = lat + latDegreeChange
        let minLong = long - longDegreeChange
        let maxLong = long + longDegreeChange
        
        return (minLat, maxLat, minLong, maxLong)
    }
    
    // Function to compute haversine distance between two points
    func haversineDinstance(la1: Double, lo1: Double, la2: Double, lo2: Double, radius: Double = 6367444.7) -> Double {

        let haversin = { (angle: Double) -> Double in
            return (1 - cos(angle))/2
        }

        let ahaversin = { (angle: Double) -> Double in
            return 2*asin(sqrt(angle))
        }

        // Converts from degrees to radians
        let dToR = { (angle: Double) -> Double in
            return (angle / 360) * 2 * Double.pi
        }

        let lat1 = dToR(la1)
        let lon1 = dToR(lo1)
        let lat2 = dToR(la2)
        let lon2 = dToR(lo2)

        return radius * ahaversin(haversin(lat2 - lat1) + cos(lat1) * cos(lat2) * haversin(lon2 - lon1))
    }
    func searchLatIndex(artworks: [Artwork], minLat: Double, curIndex: Int, totalIndex: Int) -> Int{
        let curLength = artworks.count
        if curLength == 1{
            return totalIndex
        }
        if artworks[curIndex].coordinate.latitude > minLat{
            let nextIndex = Int(curIndex/2)
            return searchLatIndex(artworks: Array(artworks[0..<curIndex]), minLat: minLat, curIndex: nextIndex, totalIndex: totalIndex - curIndex + nextIndex)
        }
        else if artworks[curIndex].coordinate.latitude < minLat{
            let nextMiddle = (Double(curLength-curIndex)/2.0)
            let nextIndex = Int(ceil(nextMiddle))
            return searchLatIndex(artworks: Array(artworks[curIndex..<curLength]), minLat: minLat, curIndex: nextIndex, totalIndex: nextIndex + totalIndex)
        }
        else{
            return totalIndex
        }
    }

    func getCandidates(artworks: [Artwork], curLat:Double, curLon: Double, radius: Double) -> (Int, Double, Int, [Int]){
        let (minLat, maxLat, minLon, maxLon) = getCoordinateRange(lat: curLat, long: curLon, radius: radius)
//        print("min and max", (minLat, maxLat, minLon, maxLon))
        
        let guess = Int(artworks.count/2)
        let startIndex = searchLatIndex(artworks: artworks, minLat: minLat, curIndex: guess, totalIndex: guess)

        // helpers
        var lat: Double
        var lon: Double
        var index = startIndex
        // returns
        var minDist = radius
        var pennyCounter = 0
        var closestID = 0
        var foundIndices: [Int] = []
        
        // iterate over artworks
        for artwork in artworks[startIndex..<artworks.count] {
            lat = artwork.coordinate.latitude
            lon = artwork.coordinate.longitude
            if lat > maxLat {
                break
            }

            // Check whether the pin is in the square
            if minLon < lon && lon < maxLon && artwork.status == "unvisited"{
                let distInKm = haversineDinstance(la1: curLat, lo1: curLon, la2: lat, lo2: lon)/1000
                // check whether in circle
                if distInKm < radius{
                    pennyCounter += 1
                    if distInKm < minDist{
                        minDist = distInKm
                        closestID = index
                    }
                    foundIndices.append(index)
                }
            }
            index += 1

        }
        return (pennyCounter, minDist, closestID, foundIndices)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // called if authorization has changed
        checkLocationAuthorization()
    }
    // Function to check if a certain time period has passed since the last successful load
    func shouldReloadData() -> Bool {
        let reloadTimeInterval: TimeInterval = 7 * 24 * 60 * 60 // One week in seconds
        if let lastTimestamp = lastDataLoad {
            // Calculate the time difference between now and the last successful load
            let timeSinceLastLoad = Date().timeIntervalSince(lastTimestamp)
            return timeSinceLastLoad >= reloadTimeInterval // Check if the time period has passed
        }
        return true
    }
}


// Searchbar updating
@available(iOS 13.0, *)
extension ViewController: UISearchResultsUpdating {
  func updateSearchResults(for searchController: UISearchController) {
    let searchBar = searchController.searchBar
    
    // Display the penny pin options and execute the search only if a string is entered
    // Makes sure that list is not displayed if cancel is pressed
    if searchBar.text!.count > 0 {
        filterContentForSearchText(searchBar.text!)
    }
    
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
        let artwork: Artwork
        if isFiltering {
            artwork = filteredArtworks[indexPath.row]
        } else {
            artwork = artworks[indexPath.row]
        }
        cell.textLabel?.text = artwork.title
        cell.detailTextLabel?.text = artwork.address
        // Set the custom color for the cell based on the artwork color
        cell.backgroundColor = artwork.markerTintColor.withAlphaComponent(0.15)
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
        let center = self.selectedPin!.coordinate
        let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
        self.PennyMap.setRegion(region, animated: true)
        locationResult.removeFromSuperview()
        tableShown = false
        searchController.searchBar.endEditing(true)
        
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
