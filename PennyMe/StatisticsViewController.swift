//
//  StatisticsViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 02.10.24.
//  Copyright © 2024 Jannis Born. All rights reserved.
//

import UIKit
import Charts
import DGCharts


@available(iOS 13.0, *)
class StatisticsViewController: UIViewController {
    let bronzeCutoff: Int = 10
    let silverCutoff: Int = 50
    let goldCutoff: Int = 100
    let goldproCutoff: Int = 500
    let goldlegendCutoff: Int = 1000
//    // DEBUGGING
//    let bronzeCutoff: Int = 12
//    let silverCutoff: Int = 13
//    let goldCutoff: Int = 14
//    let goldproCutoff: Int = 15
//    let goldlegendCutoff: Int = 16

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var crownImage: UIImageView!
    @IBOutlet weak var numberLabel: UILabel!
    @IBOutlet weak var thirdCrown: UIImageView!
    @IBOutlet weak var secondCrown: UIImageView!
    @IBOutlet weak var totalLabel: UILabel!
    @IBOutlet weak var showPercentSwitch: UISwitch!
    @IBOutlet weak var byCountryLabel: UILabel!
    @IBOutlet weak var barChartView: HorizontalBarChartView!
    @IBOutlet weak var totalMachinesLabel: UILabel!
    // Bronze Color (RGB: 205, 127, 50)
    let bronzeColor = UIColor(red: 205/255.0, green: 127/255.0, blue: 50/255.0, alpha: 1.0)

    // Silver Color (RGB: 192, 192, 192)
    let silverColor = UIColor(red: 192/255.0, green: 192/255.0, blue: 192/255.0, alpha: 1.0)

    // Gold Color (RGB: 255, 215, 0)
    let goldColor = UIColor(red: 255/255.0, green: 215/255.0, blue: 0/255.0, alpha: 1.0)

    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let user_settings = UserDefaults.standard
        let userSawLast = user_settings.value(forKey: "userSawLast") as? Int ?? 0

        crownImage.image = UIImage(systemName:"crown.fill")
        var text = ""
        var color: UIColor = .black
        if visitedCount >= goldCutoff {
            color = goldColor
            text = "Collector status: Gold!"
            checkPopupNeeded(userSawLast: userSawLast, aboveCount: goldCutoff, statusName: "Gold",  furtherText: "Keep on collecting to get a second crown at \(goldproCutoff) visited machines.")
        }
        else if visitedCount >= silverCutoff{
            color = silverColor
            text = "Collector status: Silver!"
            checkPopupNeeded(userSawLast: userSawLast, aboveCount: silverCutoff, statusName: "Silver", furtherText: "Keep on collecting to reach Gold status at \(goldCutoff) visited machines.")
        }
        else if visitedCount >= bronzeCutoff {
            color = bronzeColor
            text = "Collector status: Bronze!"
            checkPopupNeeded(userSawLast: userSawLast, aboveCount: bronzeCutoff, statusName: "Bronze", furtherText: "Keep on collecting to reach Silver status at \(silverCutoff) visited machines.")
        }
        
        // add second crown
        if visitedCount >= goldproCutoff {
            secondCrown.image = UIImage(systemName:"crown.fill")
            checkPopupNeeded(userSawLast: userSawLast, aboveCount: goldproCutoff, statusName: "Gold Pro", furtherText: "Keep on collecting to get a third crown at \(goldlegendCutoff) visited machines.")
            secondCrown.tintColor = goldColor
            text = "Collector status: Gold Pro!"
        }
        
        // add third crown
        if visitedCount >= goldlegendCutoff {
            thirdCrown.image = UIImage(systemName:"crown.fill")
            checkPopupNeeded(userSawLast: userSawLast, aboveCount: goldlegendCutoff, statusName: "Gold Legend", furtherText: "")
            thirdCrown.tintColor = goldColor
            text = "Collector status: Gold Legend!"
        }
        
        // update variable indicating what status the user has seen
        UserDefaults.standard.set(visitedCount, forKey: "userSawLast")
        UserDefaults.standard.synchronize()
        
        crownImage.tintColor = color
        // Enable user interaction on the image view
        crownImage.isUserInteractionEnabled = true
        // Create a tap gesture recognizer and attach it to the image view
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(showPopUp))
        crownImage.addGestureRecognizer(tapGesture)
        
        showPercentSwitch.onTintColor = UIColor.black
        showPercentSwitch.addTarget(self, action: #selector(setBarChartType), for: .valueChanged)
        
        byCountryLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        
        titleLabel.textColor = .gray
        titleLabel.text = text
        titleLabel.numberOfLines = 0
        titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        numberLabel.font = UIFont.systemFont(ofSize: 60, weight: .bold)
        numberLabel.shadowColor = UIColor.gray // Shadow color
        numberLabel.shadowOffset = CGSize(width: 2, height: 2)
        numberLabel.textColor = color
        numberLabel.text = "\(visitedCount)"
        
        totalMachinesLabel.numberOfLines = 0
        totalMachinesLabel.text = "machines visited"
        totalLabel.text = "/ \(totalMachines)"

        setBarChartType(sender: showPercentSwitch)
    }
    
    // The function that will be called when the image is tapped
    @objc func showPopUp() {
        // Create the alert controller (pop-up window)
        let alertController = UIAlertController(title: "Collection status", message: "Visit machines to raise your status!\n \(bronzeCutoff): Bronze\n\(silverCutoff): Gold\n\(goldCutoff): Gold\n\(goldproCutoff): Gold Pro\n\(goldlegendCutoff): Gold Legend", preferredStyle: .alert)

        // Add an action button to the alert
        let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
        alertController.addAction(okAction)

        // Present the alert to the user
        self.present(alertController, animated: true, completion: nil)
    }

    @objc func setBarChartType(sender:UISwitch!) {
        if sender.isOn{
            setupBarChart(mode: "percent")
        }
        else{
            setupBarChart(mode: "absolute")
        }
    }
    
    func checkPopupNeeded(userSawLast: Int, aboveCount: Int, statusName: String, furtherText: String) {
        if aboveCount > userSawLast {
            let alertMessage = "You have reached \(statusName) status since you collected \(aboveCount) pennies. \(furtherText)"

            // Create the alert controller
            let alertController = UIAlertController(title: "Congrats!", message: alertMessage, preferredStyle: .alert)

            // Add an action button to the alert
            let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
            alertController.addAction(okAction)

            // Present the alert
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    func setupBarChart(mode: String) {
        // Sort the dictionary and get the top 5 countries
        var topFiveCountries = visitedByArea.sorted { $0.value > $1.value }.prefix(5)
        // if percent: sort by percentage
        if mode != "absolute" {
            topFiveCountries = visitedByArea.sorted {
                // ensure it is at least 1
                let totalMachines1 = max(machinesByArea[$0.key] ?? 0, 1)
                let totalMachines2 = max(machinesByArea[$1.key] ?? 0, 1)
                // compute percentage
                let percentage1 = Double($0.value) / Double(totalMachines1)
                let percentage2 = Double($1.value) / Double(totalMachines2)

                return percentage1 > percentage2
            }.prefix(5)
        }

        // Create entries for the bar chart
        var barChartEntries: [BarChartDataEntry] = []
        var countryNames: [String] = []
        var nameSizes: [String] = []

        // Assign colors to each bar
        var barColors: [UIColor] = []
        
        for (index, country) in topFiveCountries.reversed().enumerated() {
            var barValue: Double = 0
            if mode == "absolute" {
                barValue = Double(country.value)
            }
            else {
                let totalMachinesCountry = max(machinesByArea[country.key] ?? 0, 1)
                barValue = Double(country.value) / Double(totalMachinesCountry) * 100
            }
            let entry = BarChartDataEntry(x: Double(index), y: barValue)
            
            barChartEntries.append(entry)
            // add name
            let name = country.key
            let maxNameLength = 12 // Example threshold, adjust as needed
            let formattedName = ((name.count > maxNameLength) && name.contains(" ")) ? insertLineBreaksInCountryName(name, maxLength: maxNameLength) : name
            countryNames.append(formattedName)
            // append size for scaling
            nameSizes.append(contentsOf: formattedName.components(separatedBy: "\n"))
            barColors.append(colorForValue(value: Int(barValue), mode: mode))
        }

        // Calculate the longest country name with line breaks and update padding accordingly
        let longestName = nameSizes.max(by: { $1.count > $0.count }) ?? ""
        let longestNameLength = longestName.count

        // Adjust the left padding to accommodate the longest label
        barChartView.extraLeftOffset = CGFloat(longestNameLength) * 2.0
//        barChartView.extraRightOffset = 10.0
        
        // Create the BarChartDataSet
        let dataSet = BarChartDataSet(entries: barChartEntries, label: "Collected Pennies")
        dataSet.colors = barColors
        dataSet.valueFont = .systemFont(ofSize: 15)

        // Apply custom integer formatter
        dataSet.valueFormatter = IntegerValueFormatter()
        dataSet.drawValuesEnabled = true

        // Create the BarChartData object
        let data = BarChartData(dataSet: dataSet)
        
        // Reduce the bar width to make bars smaller
        data.barWidth = 0.5 // Smaller bars, default is 1.0
        
        barChartView.data = data
        barChartView.animate(xAxisDuration: 1.0, yAxisDuration: 1.0)

        // Customize the x-axis labels (which is now the vertical axis) with country names
        barChartView.xAxis.valueFormatter = IndexAxisValueFormatter(values: countryNames)
        barChartView.xAxis.granularity = 1
        barChartView.xAxis.labelPosition = .bottom // Horizontal bar chart has labels at the bottom
        // Adjust the bar chart's font size to make room for two-line labels
        barChartView.xAxis.granularityEnabled = true
        barChartView.xAxis.wordWrapEnabled = true
        barChartView.xAxis.avoidFirstLastClippingEnabled = true
        // Increase font size of the x-axis (country labels)
        barChartView.xAxis.labelFont = .systemFont(ofSize: 16)

        // Disable grid lines for clarity
        barChartView.xAxis.drawGridLinesEnabled = false
        barChartView.leftAxis.drawGridLinesEnabled = false

        // Configure the left and right axes
        barChartView.leftAxis.enabled = false
        barChartView.rightAxis.enabled = false
        barChartView.leftAxis.axisMinimum = 0
        
        // Disable the legend
        barChartView.legend.enabled = false
        
        barChartView.data?.setDrawValues(true)

        // Refresh the chart
        barChartView.notifyDataSetChanged()
    }

    func insertLineBreaksInCountryName(_ name: String, maxLength: Int) -> String {
        // Split the string into chunks and insert line breaks at a reasonable spot
        let words = name.split(separator: " ")
        var currentLineLength = 0
        var result = ""
        // iterate over words
        for word in words {
            currentLineLength += word.count + 1 // +1 for space
            if (currentLineLength > maxLength) && (result.count > 0) {
                result += "\n" + word
                currentLineLength = word.count
            } else {
                result += (result.isEmpty ? "" : " ") + word
            }
        }
        return result
    }
    
    func colorForValue(value: Int, mode: String) -> UIColor {
        // Define the minimum and maximum values for the range
        let minValue = 1
        let maxValue = 25 // Adjust according to your data range

        // Clip to range minValue, maxValue
        var valueClipped = max(min(value, maxValue), minValue) - 1
        if mode != "absolute" {
            //scale colors to 0-50 for percent
            valueClipped = valueClipped / 2
        }
        return colorGradient[valueClipped]
    }
}

// Custom formatter to show integer values
class IntegerValueFormatter: NSObject, ValueFormatter {
    func stringForValue(_ value: Double, entry: ChartDataEntry, dataSetIndex: Int, viewPortHandler: ViewPortHandler?) -> String {
        return String(Int(value)) // Round to an integer and return as a string
    }
}

let colorGradient: [UIColor] = [
    UIColor(red: 0.7294117647058824, green: 0.8978085351787775, blue: 0.8618223760092272, alpha: 1.0),
    UIColor(red: 0.6854901960784314, green: 0.8805843906189927, blue: 0.8368473663975394, alpha: 1.0),
    UIColor(red: 0.6352941176470589, green: 0.8608996539792388, blue: 0.8083044982698963, alpha: 1.0),
    UIColor(red: 0.5913725490196078, green: 0.8433371780084583, blue: 0.7819761630142252, alpha: 1.0),
    UIColor(red: 0.5411764705882353, green: 0.821683967704729, blue: 0.7455594002306805, alpha: 1.0),
    UIColor(red: 0.4972549019607843, green: 0.8027374086889658, blue: 0.7136947327950789, alpha: 1.0),
    UIColor(red: 0.4470588235294118, green: 0.7810841983852365, blue: 0.6772779700115341, alpha: 1.0),
    UIColor(red: 0.3977239523260285, green: 0.7595540176855056, blue: 0.6403075740099962, alpha: 1.0),
    UIColor(red: 0.3658592848904268, green: 0.7423298731257209, blue: 0.6006920415224914, alpha: 1.0),
    UIColor(red: 0.32944252210688196, green: 0.722645136485967, blue: 0.5554171472510573, alpha: 1.0),
    UIColor(red: 0.2975778546712803, green: 0.7054209919261822, blue: 0.5158016147635525, alpha: 1.0),
    UIColor(red: 0.26116109188773545, green: 0.6857362552864283, blue: 0.4705267204921184, alpha: 1.0),
    UIColor(red: 0.23414071510957324, green: 0.6581314878892733, blue: 0.42883506343713956, alpha: 1.0),
    UIColor(red: 0.20461361014994234, green: 0.6236831987697039, blue: 0.38060745866974244, alpha: 1.0),
    UIColor(red: 0.17877739331026538, green: 0.5935409457900809, blue: 0.3384083044982701, alpha: 1.0),
    UIColor(red: 0.14925028835063436, green: 0.5590926566705113, blue: 0.2901806997308727, alpha: 1.0),
    UIColor(red: 0.12110726643598617, green: 0.5312572087658592, blue: 0.2590542099192618, alpha: 1.0),
    UIColor(red: 0.08665897731641677, green: 0.5017301038062283, blue: 0.2344482891195694, alpha: 1.0),
    UIColor(red: 0.05651672433679354, green: 0.47589388696655127, blue: 0.21291810841983852, alpha: 1.0),
    UIColor(red: 0.02206843521722414, green: 0.44636678200692037, blue: 0.1883121876201461, alpha: 1.0),
    UIColor(red: 0.0, green: 0.41799307958477505, blue: 0.16862745098039217, alpha: 1.0),
    UIColor(red: 0.0, green: 0.3776393694732795, blue: 0.1518954248366013, alpha: 1.0),
    UIColor(red: 0.0, green: 0.3423298731257209, blue: 0.13725490196078433, alpha: 1.0),
    UIColor(red: 0.0, green: 0.30197616301422525, blue: 0.12052287581699346, alpha: 1.0),
    UIColor(red: 0.0, green: 0.26666666666666666, blue: 0.10588235294117647, alpha: 1.0),
]
