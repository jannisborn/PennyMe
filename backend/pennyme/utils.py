import json
from typing import List, Dict, Any
import os
import requests
import logging

logger = logging.getLogger(__name__)


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
    all_ids = [i["properties"]["id"] for i in all_locations["features"]]
    server_ids = [i["properties"]["id"] for i in server_locations]

    # identify picture IDs
    pic_ids = [int(im.split(".")[0]) for im in os.listdir(PATH_IMAGES) if "jpg" in im]

    max_id_all = max(all_ids) if len(all_ids) > 0 else 0
    max_id_server = max(server_ids) if len(server_ids) > 0 else 0
    max_id_pics = max(pic_ids) if len(pic_ids) > 0 else 0

    return max([max_id_all, max_id_server, max_id_pics]) + 1


def verify_remaining_machines(
    server_data: Dict[str, Any],
    device_data: Dict[str, Any],
    validated_links: List[str],
    problem_data: Dict[str, Any],
):
    """
    Takes the final data of all machines and verifies that all links are sane.


    Args:
        server_data (Dict[str, Any]): Compiled data to be stored on server
        device_data (Dict[str, Any]): Compiled data to be stored on device
        validated_links (List[str]): Links that have already be verified (to
            save time).
        problem_data (Dict[str, Any]): Dict with machines that produce problems

    Returns:
        problem_data: Updated problem dictionariy
    """
    extra = 0
    for data in [server_data["features"], device_data["features"]]:
        for machine in data:
            url = machine["properties"]["external_url"]

            if url not in validated_links:
                extra += 1
                resp = requests.get(url)
                if resp.reason != "OK":
                    title = machine["properties"]["external_url"]
                    area = machine["properties"]["area"]
                    msg = f"Our machine {title} in {area} shown as available but {url} responds {resp.reason} ({resp.status_code})"
                    logger.error(msg)
                    machine["properties"]["id"] = -1
                    machine["properties"]["last_updated"] = -1
                    machine["problem"] = msg
                    problem_data["features"].append(machine)
                else:
                    validated_links.append(url)
    if extra > 0:
        logger.debug(f"Found {extra} machines in data that are not listed on website.")
    return problem_data
