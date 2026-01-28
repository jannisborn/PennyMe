from typing import Final

import cv2
import numpy as np
from PIL import Image


def count_foreground_objects(
    bin_mask: np.ndarray,
    min_fraction: float = 0.10,
) -> int:
    """
    Count contiguous foreground regions in a binary mask.

    Args:
        bin_mask:
            2D uint8 array with values 0 (background) and 1 (foreground).
        min_fraction:
            Minimum component area as a fraction of the total image area.
            Components smaller than this are treated as noise and ignored.

    Returns:
        Number of contiguous foreground objects whose area is at least
        ``min_fraction`` of the total image area.
    """
    if bin_mask.ndim != 2:
        raise ValueError("bin_mask must be a 2D array")

    total_pixels = bin_mask.shape[0] * bin_mask.shape[1]
    min_area: int = int(min_fraction * total_pixels)

    # connectedComponentsWithStats expects 0/255, not 0/1
    mask255 = (bin_mask * 255).astype("uint8")

    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(
        mask255, connectivity=8
    )

    # Label 0 is background
    count = 0
    for label in range(1, num_labels):
        area = int(stats[label, cv2.CC_STAT_AREA])
        if area >= min_area:
            count += 1

    return count


def is_coin(
    original: Image.Image,  # kept for API compatibility; not used in shape test
    foreground: Image.Image,
    *,
    min_area_fraction: float = 0.02,
) -> bool:
    """
    Decide whether the foreground looks like a single elongated coin,
    based *only* on connectedness and contour shape.

    The check is intentionally simple and strict:

    1. Build a binary foreground mask from the alpha channel.
    2. Find connected components and keep only components whose area
       is at least ``min_area_fraction`` of the full image.
       - If there are 0 such components → not a coin.
       - If there is more than 1 such component → not a coin.
    3. For the single remaining component:
       a) Extract its contour.
       b) Fit a rotated ellipse using ``cv2.fitEllipse``.
       c) Compute:
          - Axis ratio (major / minor)          → must be elongated.
          - Ellipse-fit error (how well the contour lies on the ellipse).
            This is a curvature-sensitive proxy: rectangles and complex
            shapes deviate strongly from a smooth ellipse.

    Parameters
    ----------
    original:
        Original image (currently unused, kept for backwards compatibility).
    foreground:
        RGBA image returned by ``rembg.remove(original)``.
    min_area_fraction:
        Minimum area a component must occupy (as a fraction of the total
        image area) to be considered. Defaults to 0.02 (2%).

    Returns
    -------
    bool
        True if the foreground likely contains exactly one elongated,
        ellipse-like object (a pressed coin). False otherwise.
    """
    rgba = np.array(foreground)
    if rgba.ndim != 3 or rgba.shape[2] < 4:
        return False

    alpha = rgba[:, :, 3]
    bin_mask = (alpha > 0).astype("uint8")

    h_img, w_img = bin_mask.shape
    total_pixels: float = float(h_img * w_img)
    if total_pixels == 0:
        return False

    # ------------------------------
    # 1. Connected components
    # ------------------------------
    mask255 = (bin_mask * 255).astype("uint8")
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(
        mask255, connectivity=8
    )

    # Collect components that are "big enough"
    big_labels: list[int] = []
    for label in range(1, num_labels):  # 0 is background
        area = float(stats[label, cv2.CC_STAT_AREA])
        if area / total_pixels >= min_area_fraction:
            big_labels.append(label)

    # Must have exactly one significant object
    if len(big_labels) != 1:
        # print(f"Rejected: {len(big_labels)} large components")
        return False

    label = big_labels[0]
    # Mask for that component only
    component_mask = (labels == label).astype("uint8")
    component_mask255 = (component_mask * 255).astype("uint8")

    # ------------------------------
    # 2. Contour and ellipse fitting
    # ------------------------------
    contours, _ = cv2.findContours(
        component_mask255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return False

    contour = max(contours, key=cv2.contourArea)

    # Need at least 5 points to fit an ellipse
    if contour.shape[0] < 5:
        return False

    ellipse = cv2.fitEllipse(contour)  # ((cx, cy), (width, height), angle)
    (cx, cy), (w_ell, h_ell), angle_deg = ellipse

    # Guard against degenerate ellipses
    if w_ell <= 0 or h_ell <= 0:
        return False

    # Major/minor axis and aspect ratio (elongation)
    major = float(max(w_ell, h_ell))
    minor = float(min(w_ell, h_ell))
    aspect = major / minor

    # ------------------------------
    # 3. Ellipse fit error
    # ------------------------------
    # Transform contour points into the ellipse's local coordinate system,
    # then evaluate the implicit ellipse equation:
    #   (x/a)^2 + (y/b)^2 = 1  for points on the ellipse.
    #
    # We measure how far each point deviates from 1; rectangles and complex
    # shapes give large errors.
    a = major / 2.0
    b = minor / 2.0
    theta = np.deg2rad(angle_deg)

    # Center and rotate contour points
    pts = contour[:, 0, :].astype("float64")  # shape (N, 2)
    pts_centered = pts - np.array([[cx, cy]])
    rot_mat = np.array(
        [[np.cos(theta), np.sin(theta)], [-np.sin(theta), np.cos(theta)]]
    )
    pts_rot = pts_centered @ rot_mat.T

    x = pts_rot[:, 0]
    y = pts_rot[:, 1]
    vals = (x / a) ** 2 + (y / b) ** 2  # ideal ellipse → ~1 everywhere

    errors = np.abs(vals - 1.0)
    mean_error = float(errors.mean())
    max_error = float(errors.max())

    # ------------------------------
    # Thresholds (tune on your data)
    # ------------------------------
    # - Pressed coins are elongated but not crazy: aspect maybe ~1.8–3.
    # - Mean ellipse-error should be small for smooth coins.
    #   Rectangular machines or complex shapes will have larger errors.
    ASPECT_MIN: Final[float] = 1.4
    ASPECT_MAX: Final[float] = 3.5
    MEAN_ERR_MAX: Final[float] = 1
    MAX_ERR_MAX: Final[float] = 2

    aspect_ok = ASPECT_MIN <= aspect <= ASPECT_MAX
    mean_err_ok = mean_error <= MEAN_ERR_MAX
    max_err_ok = max_error <= MAX_ERR_MAX

    # Debug prints, if you want to see why things are rejected:
    if not aspect_ok:
        print("Aspect failed:", aspect)
    if not mean_err_ok:
        print("Mean ellipse error failed:", mean_error)
    if not max_err_ok:
        print("Max ellipse error failed:", max_error)

    return aspect_ok and mean_err_ok and max_err_ok
