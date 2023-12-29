import json
import logging
import os
from copy import deepcopy
from typing import Any, Dict, List, Tuple

import requests

from pennyme.pennycollector import DAY, MONTH, YEAR

logger = logging.getLogger(__name__)


PATH_IMAGES = os.path.join("..", "..", "images")
TODAY = f"{YEAR}-{MONTH}-{DAY}"

THIS_PATH = os.path.abspath(__file__)
PATH_MACHINES = os.path.join(
    os.path.dirname(THIS_PATH), "..", "..", "data", "all_locations.json"
)
with open(PATH_MACHINES, "r", encoding="latin-1") as infile:
    ALL_LOCATIONS = json.load(infile)


def find_machine_in_database(
    machine_id: int, server_locations: List[Dict]
) -> Tuple[Dict[str, Any], int]:
    """
    Returns the machine information either from server_locations (if available) or
    from all_locations, as well as a boolean indicating where the entry is located

    Args:
        machine_id: ID of machine to search for
        server_locations: List of read-in server_locations.json content

    Returns:
        existing_machine_entry (dict): feature of machine
        index_in_server_locations (int): index if found in the server locations json,
                else -1
    """
    existing_machine_entry = None
    index_in_server_locations = -1
    # search in server locations
    for i, machine_entry in enumerate(server_locations):
        if machine_entry["properties"]["id"] == machine_id:
            existing_machine_entry = machine_entry
            index_in_server_locations = i
            break
    # search in all_locations
    if index_in_server_locations < 0:
        for machine_entry in ALL_LOCATIONS["features"]:
            if machine_entry["properties"]["id"] == machine_id:
                existing_machine_entry = machine_entry
                break
    return existing_machine_entry, index_in_server_locations


def get_next_free_machine_id(
    all_locations_path: str, server_locations: List[Dict]
) -> int:
    """
    Returns the next available machine ID based on all_locations and server_locations

    Args:
        all_locations_path: Path to all_locations.json
        server_locations: List of read-in server_locations.json content

    Returns:
        ID of next available machine.
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
) -> Dict[str, Any]:
    """
    Takes the final data of all machines and verifies that all links are sane.

    Args:
        server_data: Compiled data to be stored on server
        device_data: Compiled data to be stored on device
        validated_links: Links that have already be verified (to save time).

    Returns:
        Updated problem dictionary.
    """
    id_to_entry = {}
    for machine in deepcopy(device_data["features"]):
        machine["properties"]["source"] = "Device"
        id_to_entry[machine["properties"]["id"]] = machine
    for machine in deepcopy(server_data["features"]):
        machine["properties"]["source"] = "Server"
        id_to_entry[machine["properties"]["id"]] = machine

    for mid, machine in id_to_entry.items():
        url = machine["properties"]["external_url"]
        source = machine["properties"]["source"]
        status = machine["properties"]["machine_status"]
        if url == "null":
            continue
        if url not in validated_links:
            resp = requests.get(url)
            if resp.reason != "OK":
                title = machine["properties"]["name"]
                area = machine["properties"]["area"]
                msg = f"Our machine {title} in {area} from {source} shown as {status} but {url} responds {resp.reason} ({resp.status_code})"
                logger.error(msg)
                if source == "Server":
                    # Update entry in server_locations
                    for updated_machine in server_data["features"]:
                        if updated_machine["properties"]["external_url"] == url:
                            updated_machine["properties"]["external_url"] = "null"
                            updated_machine["properties"]["last_updated"] = TODAY
                else:
                    for updated_machine in device_data["features"]:
                        if updated_machine["properties"]["external_url"] == url:
                            server_machine = deepcopy(updated_machine)
                            server_machine["properties"]["external_url"] = "null"
                            server_machine["properties"]["last_updated"] = TODAY
                            server_data["features"].append(server_machine)
            else:
                validated_links.append(url)
    return server_data
