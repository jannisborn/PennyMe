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

@available(iOS 13.0, *)
struct MapViewRepresentable: UIViewRepresentable {
    @Binding var mapType: MKMapType
    @Binding var centerCoordinate: CLLocationCoordinate2D

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        view.mapType = mapType
        let region = MKCoordinateRegion(center: centerCoordinate, latitudinalMeters: regionInMeters, longitudinalMeters: regionInMeters)
        view.setRegion(region, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewRepresentable

        init(_ parent: MapViewRepresentable) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.centerCoordinate = mapView.centerCoordinate
        }
    }
}


@available(iOS 14.0, *)
struct MapView: View {
    @State private var region: MKCoordinateRegion
    @State private var showDoneAlert = false
    @Binding private var centerCoordinate: CLLocationCoordinate2D
    @Environment(\.presentationMode) private var presentationMode
    let initalCenterCoords: CLLocationCoordinate2D
    @State private var mapType: MKMapType = .standard

    
    init(centerCoordinate: Binding<CLLocationCoordinate2D>, initialCenter: CLLocationCoordinate2D) {
            _centerCoordinate = centerCoordinate
            let regionTemp = MKCoordinateRegion(
                center: initialCenter,
                latitudinalMeters: regionInMeters,
                longitudinalMeters: regionInMeters
            )
            _region = State(initialValue: regionTemp)
            initalCenterCoords = initialCenter
    }
    
    var body: some View {
        ZStack {
            // Custom MapViewRepresentable for map type switching
            MapViewRepresentable(mapType: $mapType, centerCoordinate: $centerCoordinate)
                .edgesIgnoringSafeArea(.all)
            
            // Overlay the marker at the center coordinate
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(.red)
                .font(.title)
                .offset(y: -20) // Offset to position the marker correctly
            
            VStack{
                Spacer()
                Button("Finished") {
                    showDoneAlert.toggle()
                }
                .padding(20)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
                .padding(.bottom, 20) // Padding at the bottom
                .alert(isPresented: $showDoneAlert) {
                    Alert(
                        title: Text("Moved pin location successfully from (\(initalCenterCoords.latitude), \(initalCenterCoords.longitude)) to (\(centerCoordinate.latitude), \(centerCoordinate.longitude))."),
                        primaryButton: .default(Text("Save")) {
                            showDoneAlert = false
                            self.presentationMode.wrappedValue.dismiss()
                        },
                        secondaryButton: .cancel(Text("Continue editing")) {
                            showDoneAlert = false
                        }
                    )
                }
            }
            VStack{
                Spacer()
                HStack{
                    Button(
                        action: {
                            switch mapType {
                            case .standard:
                                mapType = .satellite
                            case .satellite:
                                mapType = .hybrid
                            default:
                                mapType = .standard
                            }
                        }){
                            Image("map_symbol_without_border")
                                .renderingMode(.original)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40)
                                .padding()
                                .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 2)
                                .foregroundColor(.white)
                        }
                        .padding(.leading, 2)
                    Spacer()
                }
            }
        }.ignoresSafeArea(.all) // Ignore safe area for the entire ZStack
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
    @State private var multimachine: String = ""
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
        _multimachine = State(initialValue: String(pinData.multimachine))
        
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
            
            // Display coordinates and make button to select them on map
            let rounded_lat = String(format: "%.4f", selectedLocation.latitude)
            let rounded_lon = String(format: "%.4f", selectedLocation.longitude)
            //(selectedLocation.longitude * 1000).rounded() / 1000)
            VStack(alignment: .leading, spacing: 5) {
                Text("Lat/lon: \(rounded_lat), \(rounded_lon)").padding(3)
                Button(action: {
                    isMapPresented = true
                }) {
                    Text("Change location on map")
                        .padding()
                        .foregroundColor(Color.black)
                        .frame(maxWidth: .infinity)
                        .background(Color.yellow)
                        .cornerRadius(10)
                }
                .sheet(isPresented: $isMapPresented) {
                    MapView(centerCoordinate: $selectedLocation, initialCenter: coords)
                }.padding(3)
            }.padding(3)
            
            // Area input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Area").foregroundColor(Color.gray)
                TextField("Area", text: $area)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(3)
            
            // Multimachine input field
            VStack(alignment: .leading, spacing: 5) {
                Text("Number of machines").foregroundColor(Color.gray)
                TextField("Number of machines", text: $multimachine)
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
        if name == "" || address == "" || area == "" || multimachine == "" {
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
            (multimachine == String(pinDataStored.multimachine)) && 
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
            URLQueryItem(name: "multimachine", value: multimachine),
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
