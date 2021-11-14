//
//  ZoomViewController.swift
//  PennyMe
//
//  Created by Nina Wiedemann on 14.11.21.
//  Copyright © 2021 Jannis Born. All rights reserved.
//

import UIKit

class ZoomViewController: UIViewController, UIScrollViewDelegate {
    
    @IBOutlet weak var bigImageView: UIImageView!
    @IBOutlet weak var scrollView: UIScrollView!
    
    var image: UIImage!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.bigImageView.image = image
        self.view.addSubview(bigImageView)
        scrollView.delegate = self
        
        let minScale = min(scrollView.frame.size.width / bigImageView.frame.size.width, scrollView.frame.size.height / bigImageView.frame.size.height);
        scrollView.minimumZoomScale = minScale
        scrollView.maximumZoomScale = 4.0 * minScale
        scrollView.contentSize = bigImageView.frame.size
        scrollView.addSubview(bigImageView)
        
    }
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return bigImageView
    }

}
