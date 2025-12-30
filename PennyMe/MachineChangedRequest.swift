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

import SwiftUI
import MapKit
import CoreLocation

// variable defining how large the shown region is when changing coordinates
let regionInMeters: Double = 100

struct IdentifiableCoordinate: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

@available(iOS 14.0, *)
struct InteractiveMapView: View {
    @Binding var selectedLocation: CLLocationCoordinate2D

    @State private var region: MKCoordinateRegion

    init(selectedLocation: Binding<CLLocationCoordinate2D>) {
        _selectedLocation = selectedLocation
        _region = State(initialValue: MKCoordinateRegion(
            center: selectedLocation.wrappedValue,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }

    var body: some View {
        Map(coordinateRegion: $region, annotationItems: [IdentifiableCoordinate(coordinate: selectedLocation)]) { item in
            MapMarker(coordinate: item.coordinate, tint: .red)
        }
        .onChange(of: region.center) { newCenter in
            selectedLocation = newCenter
        }
        .frame(height: 200)
        .cornerRadius(10)
    }
}
    

@available(iOS 14.0, *)
struct MachineChangedForm: View {
    // Properties to hold user input
    var coords: CLLocationCoordinate2D
    var pinDataStored: Artwork
    
    let statusDict = [0: "available", 1: "out-of-order", 2: "retired"]
    @State private var name: String = ""
    @State private var address: String = ""
    @State private var area: String = ""
    @State private var paywall: Bool = false
    @State private var selectedSegment: Int = 0
    @State private var lonLat: String = ""
    
    // to select the location on the map
    @State private var showMap = false
    @State private var selectedLocation: CLLocationCoordinate2D
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
        _selectedLocation = State(initialValue: coords)
        _address = State(initialValue: pinData.address)
        _area = State(initialValue: pinData.area)
        _paywall = State(initialValue: pinData.paywall)
        
        let lonLatConverted = "\(coords.latitude)° N, \(coords.longitude)° O".replacingOccurrences(of: ".", with: ",")
        _lonLat = State(initialValue: lonLatConverted)

        switch pinData.machineStatus {
            case "available":
                _selectedSegment = State(initialValue: 0)
            case "out-of-order":
                _selectedSegment = State(initialValue: 1)
            case "retired":
                _selectedSegment = State(initialValue: 2)
            default:
                _selectedSegment = State(initialValue: 0)
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
            .padding(3)
            
            // adress input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Address").foregroundColor(Color.gray) // Label above TextField
                TextField("Address", text: $address)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(3)
            
            Section(header: Text("Change location").foregroundColor(.gray)) {
                InteractiveMapView(selectedLocation: $selectedLocation)

                Text("Lat: \(String(format: "%.4f", selectedLocation.latitude)), Lon: \(String(format: "%.4f", selectedLocation.longitude))")
                    .font(.footnote)
                    .foregroundColor(.gray)
            }
            
            // Area input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Area").foregroundColor(Color.gray)
                TextField("Area", text: $area)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(3)
            
            
            // Paywall checkbox
            Toggle(isOn: $paywall) {
                            Text("Is there a fee / paywall?").foregroundColor(Color.gray)
                        }
                        .padding(3)
            
            // Status segment control
            VStack(alignment: .leading, spacing: 5) {
                Text("Machine status").foregroundColor(Color.gray)
                Picker(selection: $selectedSegment, label: Text("Machine status")) {
                    Text("Available").tag(0)
                    Text("Out-of-order").tag(1)
                    Text("Retired").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
            }.padding(3)
            
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
                }.padding(3).disabled(isLoading)
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
    
    // Function to handle the submission of the request
    private func submitRequest() {
        isLoading = true
        
        // check if any field is empty
        if name == "" || address == "" || area == "" {
            finishLoading(message: "Please do not leave empty fields.")
            return
        }
        
        let lat_coord = selectedLocation.latitude
        let lon_coord = selectedLocation.longitude

        let statusNew = statusDict[selectedSegment]!
        
        // check if anything was changed at all, otherwise abort
        if (name == pinDataStored.title!) &&
            (address == pinDataStored.address) &&
            (area == pinDataStored.area) &&
            (paywall == pinDataStored.paywall) &&
            (lat_coord == pinDataStored.coordinate.latitude) &&
            (lon_coord == pinDataStored.coordinate.longitude) &&
            (statusNew == pinDataStored.machineStatus) {
            finishLoading(message: "Nothing was changed - not submitting.")
            return
        }

        var urlComponents = URLComponents(string: flaskURL)!
        urlComponents.path = "/change_machine"
        urlComponents.queryItems = [
            URLQueryItem(name: "id", value: pinDataStored.id),
            URLQueryItem(name: "title", value: name),
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "area", value: area),
            URLQueryItem(name: "multimachine", value: String(pinDataStored.multimachine)),
            URLQueryItem(name:"paywall", value: String(paywall)),
            URLQueryItem(name: "lon_coord", value: "\(lon_coord)"),
            URLQueryItem(name: "lat_coord", value: "\(lat_coord)"),
            URLQueryItem(name: "status", value: statusNew),
        ]
        urlComponents.percentEncodedQuery = urlComponents.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: urlComponents.url!)
     
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

// helper methods - make locations equatable
extension CLLocationCoordinate2D: Equatable {}
public func ==(lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
    return lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
}
// make marker identifiable
@available(iOS 14.0, *)
struct Marker: Identifiable {
    let id = UUID()
    var location: MapMarker
}
