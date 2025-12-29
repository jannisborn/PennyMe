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
    
    var images: [UIImage] = []
    var scrollPosition : CGFloat = 0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
        
        scrollView.delegate = self
        scrollView.isPagingEnabled = true
        
        // set the scroll view size based on the number of images
        scrollView.contentSize = CGSize(width: view.frame.width * CGFloat(images.count), height: scrollView.frame.height)
        
        // set zoom scale
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 3.0
        
        // move the scollView to the required position
        let scrollPoint = CGPoint(x: scrollPosition * scrollView.frame.width, y: 0)
        scrollView.setContentOffset(scrollPoint, animated: false)
        
        // add all images to the scrollview
        for (idx, image) in images.enumerated() {
            let imageView = UIImageView(image: image)
            let xPosition = view.frame.width * CGFloat(idx)
            imageView.frame = CGRect(x: xPosition, y: 0, width: view.frame.width, height: scrollView.frame.height)
            imageView.contentMode = .scaleAspectFit
            imageView.isUserInteractionEnabled = true
            scrollView.addSubview(imageView)
        }
        
    }
    
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return scrollView.subviews.first
    }

}
