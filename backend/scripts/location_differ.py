"""
This is the main script for retrieving updates from the website. It does:
- Retrieving all countries from website (and compare to existing countries)
- Downloading data for each country in mhtml format
- Converting mhtml to JSON (no GPS coordinates) and build one huge JSON
- Comparing each entry in that JSON (ID=link) to the all_locations and the server_locations
- Differentiably adding the content to the server_location
"""
import argparse
import json
import os
import logging
import pandas as pd
from googlemaps import Client as GoogleMaps

from pennyme.locations import COUNTRY_TO_CODE, parse_location_name
from pennyme.pennycollector import (
    AREA_SITE,
    AREA_PREFIX,
    get_area_list_from_area_website,
    validate_location_list,
    get_prelim_geojson,
    get_location_list_from_location_website,
    DAY,
    MONTH,
    YEAR,
    UNAVAILABLE_MACHINE_STATES,
    get_coordinates,
)
from pennyme.webconfig import get_website
from tqdm import tqdm

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

parser = argparse.ArgumentParser()
parser.add_argument(
    "-o", "--output_folder", type=str, help="Output folder path for fresh data"
)
parser.add_argument(
    "-d",
    "--device_json",
    type=str,
    help="Path to the json with the machine data stored on the user device",
)
parser.add_argument(
    "-s",
    "--server_json",
    type=str,
    help="Path to the json with the machine data stored on the server",
)
parser.add_argument("-a", "--api_key", type=str, help="Google Maps API key")


def location_differ(
    output_folder: str, device_json: str, server_json: str, api_key: str
):
    today = f"{YEAR}-{MONTH:02d}-{DAY:02d}"

    gmaps = GoogleMaps(api_key)

    # Load existing json data
    with open(device_json, "r") as f:
        device_data = json.load(f)

    with open(server_json, "r") as f:
        server_data = json.load(f)

    # Saving all machines which have no external link
    no_link_list = []

    # Convert data to have links as keys
    device_dict = {}
    machine_idx = max([x["properties"]["id"] for x in device_data["features"]])
    for geojson in device_data["features"]:
        url = geojson["properties"]["external_url"]
        if url == "null":
            no_link_list.append(geojson["properties"])
        elif url not in device_dict.keys():
            device_dict[url] = [geojson]
        else:
            device_dict[url].append(geojson)

    server_dict = {}
    for geojson in server_data["features"]:
        url = geojson["properties"]["external_url"]
        print(url, type(url))
        if url == "null":
            no_link_list.append(geojson["properties"])
        elif url not in server_dict.keys():
            server_dict[url] = [geojson]
        else:
            logger.warning(f"Link already found before, machine will be ignored: {geojson['properties']}")
        if geojson["properties"]["id"] > machine_idx:
            machine_idx = geojson["properties"]["id"]
    server_keys = list(server_dict.keys())
    # Increas max idx by 1 to set it to the first free idx
    machine_idx += 1

    # TODO: In these machines, I have to make a fuzzy search to verify that the new content does not relate to them
    no_link = pd.DataFrame(no_link_list).drop(["logs"], axis=1)
    # TODO: Fuzzy search of address and title separately
    print(no_link)

    # Extract locations
    area_website = get_website(AREA_SITE)
    areas = get_area_list_from_area_website(area_website)
    valid, diff = validate_location_list(areas)
    if not valid:
        raise ValueError(f"It seems there were new locations: {diff}")

    total_changes, new, depr = 0, 0, 0
    problem_data = {"type": "FeatureCollection", "features": []}
    # TODO: make sure there are no duplicate entries in the server_locations afterwards
    # TODO: Strip the title/adress etc
    for i, area in enumerate(areas):
        if area == " Private Rollers" or area == "_Collector Books_":
            continue
        logger.info(f"Starting processing {area}")

        # Scraping data for that area
        area_id = COUNTRY_TO_CODE[area]
        url = AREA_PREFIX + str(area_id)
        website = get_website(url)

        # Extract the machine locations
        location_raw_list = get_location_list_from_location_website(website)
        changes = 0
        l = len(location_raw_list)
        for j, raw_location in enumerate(location_raw_list):
            # Convert to preliminary geo-json (no ID and no GPS coordinates)
            geojson = get_prelim_geojson(raw_location, area, add_date=True)

            this_link = geojson["properties"]["external_url"]
            this_state = geojson["properties"]["status"]
            this_title = geojson["properties"]["name"]
            match = False
            for cur_dict, name in zip([server_dict, device_dict], ["Server", "Device"]):
                keys = list(cur_dict.keys())
                if this_link in keys:
                    cur_states = [
                        cur_dict[this_link][s]["properties"]["status"]
                        for s in range(len(cur_dict[this_link]))
                    ]
                    if len(set(cur_states)) > 1:
                        # TODO: In the future we should be able to handle those
                        raise ValueError(f"Multiple states for {cur_dict['this_link']}")
                    cur_state = cur_states[0]
                    if this_state == cur_state:
                        # Existing machine with no update
                        match = True
                        break
                    elif (
                        this_state in UNAVAILABLE_MACHINE_STATES
                        and cur_state == "retired"
                    ):
                        # Machine moved/gone before and after
                        match = True
                        break

                    # The state for an already documented machine has changed.
                    elif (
                        cur_state == "unvisited"
                        and this_state in UNAVAILABLE_MACHINE_STATES
                    ):
                        logger.debug(f"{this_title} is currently unavailable")
                        # Machine is currently unavailable, update this in server dict
                        if name == "Device":
                            # Easy case, we just add this machine to server_dict
                            if len(device_dict[this_link]) > 1:
                                logger.warning(
                                    "A url linking to multiple machines retire"
                                    f"d, maybe check manually: {device_dict[this_link]}"
                                )
                            # Retire all machines of that URL (usually 1)
                            new_entry = device_dict[this_link]
                            for entry in new_entry:
                                entry["properties"]["status"] = "retired"
                                entry["properties"]["active"] = False
                                entry["properties"]["last_updated"] = today
                            server_data["features"].extend(new_entry)
                        elif name == "Server":
                            # Machine is already documented in server_dict
                            i = server_keys.index(this_link)
                            # Retire machine
                            server_data["features"][i]["properties"][
                                "status"
                            ] = "retired"
                            server_data["features"][i]["properties"]["active"] = False
                            server_data["features"][i]["properties"][
                                "last_updated"
                            ] = today
                        changes += 1  # track that we changed this machine
                        depr += 1
                        match = True  # machine was found in existing dict
                        break  # to not change a machine found in both dicts twice

                    elif cur_state == "retired" and this_state == "unvisited":
                        logger.debug(f"{this_title} is available again")
                        # A machine documented as retired is available again
                        if name == "Device":
                            # Easy case, we just add this machine to server_dict
                            if len(device_dict[this_link]) > 1:
                                logger.warning(
                                    "A url linking to multiple machines became"
                                    f"available check manually: {device_dict[this_link]}"
                                )
                            new_entry = device_dict[this_link]
                            for entry in new_entry:
                                entry["properties"]["status"] = "unvisited"
                                entry["properties"]["active"] = True
                                entry["properties"]["last_updated"] = today
                            server_data["features"].extend(new_entry)
                        elif name == "Server":
                            # Machine is already documented in server_dict
                            idx = server_keys.index(this_link)
                            # Re-activate machine
                            server_data["features"][idx]["properties"][
                                "status"
                            ] = "unvisited"
                            server_data["features"][idx]["properties"]["active"] = True
                            server_data["features"][i]["properties"][
                                "last_updated"
                            ] = today

                        changes += 1  # track that we changed this machine
                        new += 1
                        match = True  # machine was found in existing dict
                        break  # to not change a machine found in both dicts twice

                    else:
                        raise ValueError(
                            f"Unknown state combinations: {cur_state}, {this_state}"
                        )

            if match:
                continue

            # This is a new machine since the key was not found in both dicts
            if this_state in UNAVAILABLE_MACHINE_STATES:
                # Untracked machine that is not available, hence we can skip
                continue

            logger.debug(
                f"{j}/{l}: Found machine to be added: {geojson['properties']['name']}"
            )
            changes += 1
            new += 1

            # Find the coordinates of the new machine
            lat, lng = get_coordinates(
                title=geojson["properties"]["name"],
                subtitle=geojson["properties"]["address"],
                api=gmaps
            )

            geojson["properties"]["latitude"] = str(lat)
            geojson["properties"]["longitude"] = str(lng)
            geojson["geometry"]["coordinates"] = [lng, lat]
            geojson["properties"]["last_updated"] = today
            geojson["properties"]["id"] = machine_idx
            machine_idx += 1
            del geojson["temporary"]

            if (lat, lng) == (0, 0):
                problem_data["features"].append(geojson)
            else:
                server_data["features"].append(geojson)

        logger.info(
            f"Location {area} ({i}/{len(areas)}): Changes in {changes}/"
            f"{len(location_raw_list)} machines found."
        )
        total_changes += changes

    logger.info(
        f"\n Result: {total_changes} changes, {new} new machines found"
        f" and {depr} machines retired"
    )

    fn = "server_locations.json"
    os.makedirs(output_folder, exist_ok=True)
    with open(os.path.join(output_folder, fn), "w", encoding="utf8") as f:
        json.dump(server_data, f, ensure_ascii=False, indent=4)

    if len(problem_data["features"]) > 0:
        logger.error(
            f"Found {len(problem_data['features'])} problems that require manual intervention"
        )
    pn = f"problems_{YEAR}_{MONTH}_{DAY}.json"
    with open(os.path.join(output_folder, pn), "w", encoding="utf8") as f:
        json.dump(problem_data, f, ensure_ascii=False, indent=4)


if __name__ == "__main__":
    args = parser.parse_args()
    location_differ(
        args.output_folder,
        args.device_json,
        args.server_json,
        args.api_key,
    )
