import json
from typing import List, Dict
import os

PATH_IMAGES = os.path.join("..", "..", "images")


def get_next_free_machine_id(
    all_locations_path: str, server_locations: List[Dict]
) -> int:
    """
    Returns the next available machine ID based on all_locations and server_locations

    Args:
        all_locations_path (str): Path to all_locations.json
        server_locations (List[Dict]): List of read-in server_locations.json content

    Returns:
        int: Next ID
    """
    with open(all_locations_path, "r") as infile:
        all_locations = json.load(infile)

    # Identify IDs in existing data
    all_ids = max([i["properties"]["id"] for i in all_locations["features"]])
    server_ids = max([i["properties"]["id"] for i in server_locations])

    # identify picture IDs
    pic_ids = max([int(im.split(".")[0]) for im in os.listdir(PATH_IMAGES) if "jpg" in im])

    return max(all_ids, server_ids, pic_ids) + 1
