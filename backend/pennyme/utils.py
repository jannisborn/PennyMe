import json
import os
import sys
from contextlib import contextmanager
from copy import deepcopy
from math import cos, radians
from typing import Any, Dict, List, Optional, Tuple

import requests
from haversine import haversine
from loguru import logger
from thefuzz import process as fuzzysearch

from pennyme.pennycollector import DAY, MONTH, YEAR

PATH_IMAGES = os.path.join("..", "..", "images")
TODAY = f"{YEAR}-{MONTH}-{DAY}"

THIS_PATH = os.path.abspath(__file__)
PATH_MACHINES = os.path.join(
    os.path.dirname(THIS_PATH), "..", "..", "data", "all_locations.json"
)
PATH_SERVER_MACHINES = os.path.join(
    os.path.dirname(THIS_PATH), "..", "..", "data", "server_locations.json"
)
with open(PATH_MACHINES, "r", encoding="utf-8") as infile:
    ALL_LOCATIONS = json.load(infile)
if os.path.exists(PATH_SERVER_MACHINES):
    with open(PATH_SERVER_MACHINES, "r", encoding="utf-8") as infile:
        SERVER_LOCATIONS = json.load(infile)
else:
    SERVER_LOCATIONS = {"features": []}


def find_machine_in_database(machine_id: int) -> Optional[Dict[str, Any]]:
    """
    Returns the machine feature for the given ID, checking the database first
    and falling back to all_locations.json.

    Args:
        machine_id: ID of machine to search for

    Returns:
        GeoJSON feature dict, or None if not found anywhere.
    """
    from pennyme.database import get_machine_as_geojson

    try:
        return get_machine_as_geojson(machine_id)
    except KeyError:
        pass
    for machine_entry in ALL_LOCATIONS["features"]:
        if machine_entry["properties"]["id"] == machine_id:
            return machine_entry
    return None


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

    # identify picture IDs (ignore coin IDs)
    pic_ids = [
        int(stem_ext[0])
        for name in os.listdir(PATH_IMAGES)
        if "coin" not in name.lower()
        and os.path.isfile(os.path.join(PATH_IMAGES, name))
        and (stem_ext := os.path.splitext(name))[1].lower() in {".jpg", ".jpeg", ".png"}
        and stem_ext[0].lstrip("-").isdigit()
    ]

    max_id_all = max(all_ids) if len(all_ids) > 0 else 0
    max_id_server = max(server_ids) if len(server_ids) > 0 else 0
    max_id_pics = max(pic_ids) if len(pic_ids) > 0 else 0

    return max([max_id_all, max_id_server, max_id_pics]) + 1


def get_nearby_machines(
    lat: float, lon: float, area: str, radius_m: int = 150
) -> List[Dict]:
    """Find machines near a coordinate.

    Args:
        lat: Latitude of the submitted machine.
        lon: Longitude of the submitted machine.
        area: Area of the submitted machine.
        radius_m: Search radius in meters.

    Returns:
        Nearby machine summaries sorted by ascending distance.
    """

    radius_km = radius_m / 1000
    lat_delta = radius_km / 111
    lon_delta = radius_km / (111 * max(abs(cos(radians(lat))), 0.01))
    machines = {
        machine["properties"]["id"]: machine for machine in ALL_LOCATIONS["features"]
    }
    for machine in SERVER_LOCATIONS["features"]:
        machines[machine["properties"]["id"]] = machine

    nearby = []
    for machine in machines.values():
        props = machine["properties"]
        if props["area"] != area:
            continue
        machine_lon, machine_lat = machine["geometry"]["coordinates"]
        # Michael's trick
        if not (
            lat - lat_delta <= machine_lat <= lat + lat_delta
            and lon - lon_delta <= machine_lon <= lon + lon_delta
        ):
            continue
        distance_m = 1000 * haversine((lat, lon), (machine_lat, machine_lon))
        if distance_m < radius_m:
            nearby.append(
                {
                    "id": props["id"],
                    "name": props["name"],
                    "address": props["address"],
                    "area": props["area"],
                    "machine_status": props.get("machine_status", "available"),
                    "distance_m": round(distance_m),
                }
            )
    return sorted(nearby, key=lambda machine: machine["distance_m"])


def find_machine_name_conflict(
    title: str, nearby_machines: List[Dict]
) -> Tuple[Optional[str], Optional[Dict], Optional[int]]:
    """Find an exact or fuzzy title conflict among nearby machines.

    Exact matches compare lowercased, stripped names and take priority over fuzzy
    matches. This lets callers present a known duplicate differently from a title
    that merely needs to be made more distinct.

    Args:
        title: The proposed machine name.
        nearby_machines: Machine summaries returned by ``get_nearby_machines``.

    Returns:
        A tuple of conflict kind (``exact`` or ``similar``), matching machine, and
        fuzzy score. All values are ``None`` when there is no conflict.
    """

    normalized_title = title.strip().lower()
    for machine in nearby_machines:
        if machine["name"].strip().lower() == normalized_title:
            return "exact", machine, 100

    for machine in nearby_machines:
        _, score = fuzzysearch.extract(title, [machine["name"]], limit=1)[0]
        if score > 90:
            return "similar", machine, score

    return None, None, None


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


@contextmanager
def setup_locdiffer_logger():
    log_file = "/root/PennyMe/new_data/cron.log"
    # Remove cron.log if it exists
    if os.path.exists(log_file):
        os.remove(log_file)

    # Configure Loguru logger
    handler_id = logger.add(
        log_file,
        rotation="10 MB",
        level="INFO",
        format="{time:YYYY-MM-DD HH:mm:ss} {level} {message}",
    )
    # Optionally, remove the default stderr handler to prevent logging to the terminal
    default_handler_id = logger.add(
        sys.stderr, level="INFO", format="{time} {level} {message}", enqueue=True
    )
    logger.remove(default_handler_id)
    try:
        yield
    finally:
        # Remove the file handler after the job is done, restoring default logging behavior
        logger.remove(handler_id)
