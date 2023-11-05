//
//  MachineChangedRequest.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 04.11.23.
//  Copyright © 2023 Jannis Born. All rights reserved.
//

import Foundation
import SwiftUI
import MapKit
import Combine

//// Code for picking coordinates on a map - did not work yet, only showing a map
//let regionInMeters: Double = 10000
//@available(iOS 14.0, *)
//struct MapView: View {
////    @Binding var selectedLocation: CLLocationCoordinate2D?
//    @State var region: MKCoordinateRegion
//    
//    init(selectedLocation: CLLocationCoordinate2D?) {
//        if let location = PennyMe.locationManager.location?.coordinate{
//            let regionTemp = MKCoordinateRegion.init(
//                center:location,
//                latitudinalMeters: regionInMeters,
//                longitudinalMeters: regionInMeters
//            )
//            _region = State(initialValue: regionTemp)
//        } else { // goes to Uetliberg otherwise
//            let location = CLLocationCoordinate2D(
//                latitude: 47.349586,
//                longitude: 8.491197
//            )
//            let regionTemp = MKCoordinateRegion.init(
//                center:location,
//                latitudinalMeters: regionInMeters,
//                longitudinalMeters: regionInMeters
//            )
//            _region = State(initialValue: regionTemp)
//        }
//    }
//    var body: some View {
//        Map(coordinateRegion: $region)
//    }
//}
    

@available(iOS 14.0, *)
struct MachineChangedForm: View {
    // Properties to hold user input
    var coords: CLLocationCoordinate2D
    var pinDataStored: Artwork
    
    let statusDict = [0: "active", 1: "out_of_order", 2: "retired"]
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var area: String = ""
    @State private var paywall: Bool = false
    @State private var multimachine: String = ""
    @State private var selectedSegment: Int = 0
    @State private var lonLat: String = ""
    
    // to select the location on the map
    @State private var showMap = false
    @State private var selectedLocation: CLLocationCoordinate2D?
    @State private var isMapPresented = false
    
    @State private var showFinishedAlert = false
    @State private var displayResponse: String = ""
    @Environment(\.presentationMode) private var presentationMode // Access the presentationMode environment variable
    @State private var showAlert = false
    @State private var isLoading = false

    @State private var keyboardHeight: CGFloat = 0
    private var keyboardObserver: AnyCancellable?

    init(pinData: Artwork) {
        pinDataStored = pinData
        _name = State(initialValue: pinData.title!)
        coords = pinData.coordinate
        _address = State(initialValue: pinData.address)
        _area = State(initialValue: pinData.area)
        _paywall = State(initialValue: pinData.paywall)
        _multimachine = State(initialValue: String(pinData.multimachine))
        
        let lonLatConverted = "\(coords.latitude)° N, \(coords.longitude)° O".replacingOccurrences(of: ".", with: ",")
        _lonLat = State(initialValue: lonLatConverted)
        // TODO: Change once we have out of order in the json file
        if pinData.status == "retired" {
            _selectedSegment = State(initialValue: 2)
        }
        // Observe keyboard frame changes
        keyboardObserver = NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
                .compactMap { $0.userInfo?["UIKeyboardFrameEndUserInfoKey"] as? CGRect }
                .map { $0.height }
                .subscribe(on: DispatchQueue.main)
                .assign(to: \.keyboardHeight, on: self)
    }
    
    var body: some View {
        ScrollView{
        VStack(alignment: .leading, spacing: 5) {
            // Machine title
            VStack(alignment: .leading, spacing: 5) {
                Text("Machine title").foregroundColor(Color.gray) // Label above TextField
                TextField("Machine title", text: $name)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            
            // adress input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Address").foregroundColor(Color.gray) // Label above TextField
                TextField("Address", text: $address)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            
            // Area input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Area").foregroundColor(Color.gray)
                TextField("Area", text: $area)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            
            // Multimachine input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Number of machines").foregroundColor(Color.gray)
                TextField("Number of machines", text: $multimachine)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding()
            
            // Paywall checkbox
            Toggle(isOn: $paywall) {
                            Text("Is there a fee / paywall?").foregroundColor(Color.gray)
                        }
                        .padding()
            
            // Status segment control
            VStack(alignment: .leading, spacing: 5) {
                Text("Machine status").foregroundColor(Color.gray)
                Picker(selection: $selectedSegment, label: Text("Machine status")) {
                    Text("Active").tag(0)
                    Text("Out-of-order").tag(1)
                    Text("Removed").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
            }.padding()
            // show map
//            Button(action: {
//                                isMapPresented = true
//                            }) {
//                                Text("Select Location on Map")
//                            }
//                            .sheet(isPresented: $isMapPresented) {
//                                MapView(selectedLocation: selectedLocation ?? nil)
//                            }
            
            VStack(alignment: .leading, spacing: 5) {
                Text("To change longitude and latitude, go to Maps, tap on a location, and copy the coordinates here").foregroundColor(Color.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    TextField("Coordinates", text: $lonLat).textFieldStyle(RoundedBorderTextFieldStyle())
                    Button(action: {
                        goToMaps()
                    }) {
                        Text("Maps")
                            .padding(10)
                            .foregroundColor(Color.white)
                            .background(Color.gray)
                            .cornerRadius(10)
                    }
                }
            }.padding()
            
            // Submit button
            if isLoading {
                ProgressView("Loading...")
                    .padding()
            } else {
                Button(action: {
                    submitRequest()
                }) {
                    Text("Submit")
                        .padding()
                        .foregroundColor(Color.white)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .cornerRadius(10)
                }.padding().disabled(isLoading)
            }
            
            AlertPresenter(showAlert: $showFinishedAlert, title: "Finished", message: "Thanks for suggesting this change. We will review this request shortly. Note that it can take up to a few days until the machine is updated.")
                .padding()
        }
        .alert(isPresented: $showAlert) {
                    Alert(title: Text("Attention!"), message: Text(displayResponse), dismissButton: .default(Text("Dismiss")))
                }
        .padding()
        .navigationBarTitle("Suggest machine change")
        }
        .padding(.bottom, keyboardHeight)
    }
    
    private func finishLoading(message: String) {
        displayResponse = message
        showAlert = true
        isLoading = false
    }
    
    private func goToMaps() {
        pinDataStored.mapItem().openInMaps()
    }
    
    private func convertCoordsBack(matchedSubstring: String) -> (Double, Double) {
        let components = matchedSubstring.split(separator: " ").map(String.init)
        if components.count > 2 {
            let latitudeString = components[0]
            let longitudeString = components[2]
            
            // Clean up the strings by removing commas and the "°" symbol
            let cleanLatitudeString = latitudeString.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "°", with: "")
            let cleanLongitudeString = longitudeString.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "°", with: "")
            print(cleanLatitudeString, cleanLongitudeString)
            if let latitude = Double(cleanLatitudeString), let longitude = Double(cleanLongitudeString) {
                return (latitude, longitude)
            } else {
                return (0, 0)
            }
        }
        else {
            return (0, 0)
        }
    }
    
    // Function to handle the submission of the request
    private func submitRequest() {
        isLoading = true
        
        // check if any field is empty
        if name == "" || address == "" || area == "" || multimachine == "" {
            finishLoading(message: "Please do not leave empty fields.")
            return
        }
        
        // check if the coordinates are okay
        let pattern = #"(\d+,\d+° N, \d+,\d+° O)"#
        let wrongPatternMessage = "Please make sure that the coordinates are in the required format (e.g., 47,2384° N, 8,4568° O)."
        var lat_coord: Double = 0
        var lon_coord: Double = 0
        if let range = lonLat.range(of: pattern, options: .regularExpression) {
            let matchedSubstring = lonLat[range]
            (lat_coord, lon_coord) = convertCoordsBack(matchedSubstring: String(matchedSubstring))
            if lat_coord == 0 {
                finishLoading(message:wrongPatternMessage)
                return
            }
        }
        else {
            finishLoading(message: wrongPatternMessage)
            return
        }
        let statusNew = statusDict[selectedSegment]!
        
        // prepare URL
        let urlString = flaskURL+"/change_machine?id=\(pinDataStored.id)& title=\(name)&address=\(address)&lat_coord=\(lat_coord)&lon_coord=\(lon_coord)&status=\(statusNew)&multimachine=\(multimachine)&paywall=\(paywall)&area=\(area)"
        guard let url = URL(string: urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "None"
        ) else {
            finishLoading(message: "Something went wrong. Please try to re-enter the information")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        // Create a URLSessionDataTask to send the request
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            if error != nil {
                finishLoading(message: "Something went wrong. Please check your internet connection and try again")
                return
            }
            // Check if a valid HTTP response was received
            guard let httpResponse = response as? HTTPURLResponse else {
                finishLoading(message: "Something went wrong. Please check your internet connection and try again")
                return
            }
            // Extract the status code from the HTTP response
            let statusCode = httpResponse.statusCode
            
            // Check if the status code indicates success (e.g., 200 OK)
            if 200 ..< 300 ~= statusCode {
                // everything worked, finish
                DispatchQueue.main.async {
                    self.showFinishedAlert = true
                    self.presentationMode.wrappedValue.dismiss()
                    isLoading = false
                }
            }
            else {
                if let responseData = data {
                    do {
                        // Parse the JSON response
                        if let json = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
                            // Handle the JSON data here
                            if let answerString = json["error"] as? String {
                                finishLoading(message: answerString)
                                return
                            }
                        }
                    } catch {
                        print("JSON parsing error: \(error)")
                        finishLoading(message: "Something went wrong. Please check your internet connection and try again")
                    }
                }
            }
        }
        task.resume()
    }
}
