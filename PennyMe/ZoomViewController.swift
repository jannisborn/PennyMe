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
        
//        guard let imageUrl = URL(string: self.link_to_image) else { return }
//        self.bigImageView.loadurl(url: imageUrl)
        self.bigImageView.image = image

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        
    }
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return bigImageView
    }

}
