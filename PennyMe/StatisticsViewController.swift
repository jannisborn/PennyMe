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

    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var crownImage: UIImageView!
    @IBOutlet weak var numberLabel: UILabel!
    
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

        crownImage.image = UIImage(systemName:"crown.fill")
        var text = ""
        var color: UIColor = .black
        if visitedCount >= 100 {
            color = goldColor
            text = "Collector status: Gold! "
        }
        else if visitedCount >= 50{
            color = silverColor
            text = "Collector status: Silver! "
        }
        else if visitedCount >= 10 {
            color = bronzeColor
            text = "Collector status: Bronze! "
        }
        crownImage.tintColor = color
        
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
        totalMachinesLabel.text = "machines visited \n from \(totalMachines) active machines in total"

        setBarChartType(sender: showPercentSwitch)
    }
    
    @objc func setBarChartType(sender:UISwitch!) {
        if sender.isOn{
            setupBarChart(mode: "percent")
        }
        else{
            setupBarChart(mode: "absolute")
        }
    }
    
    func setupBarChart(mode: String) {
        // Sort the dictionary and get the top 5 countries
        let topFiveCountries = visitedByArea.sorted { $0.value > $1.value }.prefix(5).reversed()

        // Create entries for the bar chart
        var barChartEntries: [BarChartDataEntry] = []
        var countryNames: [String] = []

        // Assign colors to each bar
        var barColors: [UIColor] = [] // [.orange, .red, .purple, UIColor.systemBlue, UIColor.systemGreen]
        
        for (index, country) in topFiveCountries.enumerated() {
            var barValue: Double = 0
            if mode == "absolute" {
                barValue = Double(country.value)
            }
            else {
                barValue = Double(country.value) / Double(machinesByArea[country.key]!) * 100
            }
            let entry = BarChartDataEntry(x: Double(index), y: barValue)
            
            barChartEntries.append(entry)
            
            countryNames.append(country.key)
            barColors.append(colorForValue(value: country.value))
        }

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

    func colorForValue(value: Int) -> UIColor {
        // Define the minimum and maximum values for the range
        let minValue = 0
        let maxValue = 20 // from 20 machines per country onwards, it's green
        
        // Normalize the value to a range of 0 to 1
        let normalizedValue = CGFloat((value - minValue)) / CGFloat((maxValue - minValue))
        
        // Gradually transition from blue (low) to green (high)
        let startColor = UIColor.systemBlue
        let endColor = UIColor.systemGreen
        
        // Get the RGB components of both start and end colors
        var startRed: CGFloat = 0, startGreen: CGFloat = 0, startBlue: CGFloat = 0, startAlpha: CGFloat = 0
        var endRed: CGFloat = 0, endGreen: CGFloat = 0, endBlue: CGFloat = 0, endAlpha: CGFloat = 0
        
        startColor.getRed(&startRed, green: &startGreen, blue: &startBlue, alpha: &startAlpha)
        endColor.getRed(&endRed, green: &endGreen, blue: &endBlue, alpha: &endAlpha)
        
        // Interpolate between the start and end colors
        let red = startRed + (endRed - startRed) * normalizedValue
        let green = startGreen + (endGreen - startGreen) * normalizedValue
        let blue = startBlue + (endBlue - startBlue) * normalizedValue
        
        return UIColor(red: red, green: green, blue: blue, alpha: 0.75)
    }


    }

    // Custom formatter to show integer values
    class IntegerValueFormatter: NSObject, ValueFormatter {
        func stringForValue(_ value: Double, entry: ChartDataEntry, dataSetIndex: Int, viewPortHandler: ViewPortHandler?) -> String {
            return String(Int(value)) // Round to an integer and return as a string
        }
    }
