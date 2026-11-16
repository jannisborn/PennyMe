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
    private var viewportSize = CGSize.zero
    private var imageCenter: CGPoint?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 13.0, *) {
            overrideUserInterfaceStyle = .light
        }
        
        bigImageView.image = image
        // UIScrollView owns the image view's frame and transform while zooming.
        bigImageView.translatesAutoresizingMaskIntoConstraints = true
        bigImageView.autoresizingMask = []
        bigImageView.frame = CGRect(origin: .zero, size: image?.size ?? .zero)
        scrollView.contentSize = bigImageView.bounds.size
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scrollView.bounds.size
        guard let image = image, image.size.width > 0, image.size.height > 0,
              size.width > 0, size.height > 0, size != viewportSize else { return }

        let focus = imageCenter ?? CGPoint(x: image.size.width / 2, y: image.size.height / 2)
        let relativeZoom = viewportSize == .zero ? 1 : scrollView.zoomScale / scrollView.minimumZoomScale
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        viewportSize = size
        // Expand the range first so increasing the minimum cannot exceed the current maximum.
        scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, fit * 4)
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = fit * 4
        scrollView.setZoomScale(min(max(fit * relativeZoom, fit), fit * 4), animated: false)
        centerImage()

        let point = bigImageView.convert(focus, to: scrollView)
        let inset = scrollView.contentInset
        let maximumX = max(-inset.left, scrollView.contentSize.width - size.width + inset.right)
        let maximumY = max(-inset.top, scrollView.contentSize.height - size.height + inset.bottom)
        scrollView.contentOffset = CGPoint(
            x: min(max(point.x - size.width / 2, -inset.left), maximumX),
            y: min(max(point.y - size.height / 2, -inset.top), maximumY)
        )
        rememberImageCenter()
    }

    private func centerImage() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func rememberImageCenter() {
        // Ignore scroll callbacks caused by a resize until the new fit has been applied.
        guard viewportSize != .zero, scrollView.bounds.size == viewportSize else { return }
        imageCenter = scrollView.convert(
            CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: bigImageView
        )
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        rememberImageCenter()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        rememberImageCenter()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return bigImageView
    }

}
