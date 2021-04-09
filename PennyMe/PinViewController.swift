//
//  PinViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 09.04.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit

class PinViewController: UIViewController {

    @IBOutlet weak var scrollView: UIScrollView!
    
    override func viewDidLoad() {
            super.viewDidLoad()

        let contentWidth = UIScreen.main.bounds.width
        let contentHeight = UIScreen.main.bounds.height * 3
            scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)

            let subviewHeight = CGFloat(120)
            var currentViewOffset = CGFloat(0);

            while currentViewOffset < contentHeight {
                let frame = CGRect(x: 0, y: currentViewOffset, width: contentWidth, height: subviewHeight).insetBy(dx: 5, dy: 5)
                let hue = currentViewOffset/contentHeight
                let subview = UIView(frame: frame)
                subview.backgroundColor = UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
                scrollView.addSubview(subview)

                currentViewOffset += subviewHeight
            }
        }

}
