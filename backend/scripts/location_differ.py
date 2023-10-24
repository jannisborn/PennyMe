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
import logging
import os
from collections import Counter
from datetime import datetime

import pandas as pd
from googlemaps import Client as GoogleMaps
from haversine import haversine
from thefuzz import process as fuzzysearch

from pennyme.locations import COUNTRY_TO_CODE
from pennyme.pennycollector import (
    AREA_PREFIX,
    AREA_SITE,
    DAY,
    MONTH,
    UNAVAILABLE_MACHINE_STATES,
    YEAR,
    get_area_list_from_area_website,
    get_coordinates,
    get_location_list_from_location_website,
    get_prelim_geojson,
    validate_location_list,
)
from pennyme.webconfig import get_website
from pennyme.github_update import load_latest_server_locations

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
parser.add_argument(
    "--load_from_github",
    action="store_true",
    help="load the latest server_locations file from the repo",
)
parser.add_argument("-a", "--api_key", type=str, help="Google Maps API key")


def location_differ(
    output_folder: str, device_json: str, server_json: str, api_key: str, load_from_github:bool
):

    start_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    logger.info(f"======Location differ joblog from {start_time}=======")
    os.makedirs(output_folder, exist_ok=True)

    today = f"{YEAR}-{MONTH}-{DAY}"

    gmaps = GoogleMaps(api_key)

    # Load existing json data
    with open(device_json, "r") as f:
        device_data = json.load(f)

    # load server_locations from github or from data folder
    if load_from_github:
        server_data, _ = load_latest_server_locations()
        # save the file locally to compare it later
        with open(server_json, "w", encoding="utf8") as f:
            json.dump(server_data, f, ensure_ascii=False, indent=4)
        problems_old, _ = load_latest_server_locations(
            file="/data/problems.json"
        )
        problems_out_path = os.path.join(output_folder, "old_problems.json")
        with open(problems_out_path, "w", encoding="utf8") as f:
            json.dump(problems_old, f, ensure_ascii=False, indent=4)
    else:
        with open(server_json, "r") as f:
            server_data = json.load(f)

    # Saving all machines which have no external link
    no_link_list = []

    # Convert data to have links as keys
    device_dict = {}
    machine_idx = max([x["properties"]["id"] for x in device_data["features"]])
    for i, geojson in enumerate(device_data["features"]):
        url = geojson["properties"]["external_url"]
        if url == "null":
            entry = geojson["properties"].copy()
            entry["source"] = "Device"
            entry["data_idx"] = i
            no_link_list.append(entry)
        elif url not in device_dict.keys():
            device_dict[url] = [geojson]
        else:
            raise ValueError(
                f"Duplicate entry in all_locations must not occur (problem={url}) - {geojson}"
            )

    server_dict = {}
    for i, geojson in enumerate(server_data["features"]):
        url = geojson["properties"]["external_url"]
        if url == "null":
            entry = geojson["properties"].copy()
            entry["source"] = "Server"
            entry["data_idx"] = i
            no_link_list.append(entry)
        elif url not in server_dict.keys():
            server_dict[url] = [geojson]
        else:
            server_dict[url].append(geojson)
        if geojson["properties"]["id"] > machine_idx:
            machine_idx = geojson["properties"]["id"]
    server_keys = list(server_dict.keys())
    # Increas max idx by 1 to set it to the first free idx
    machine_idx += 1

    # Required to later ensure that machines are not added twice.
    no_link = pd.DataFrame(no_link_list).drop(["logs"], axis=1)
    # If a machine w/o link exists in both dicts, we only keep the one from the server
    no_link = no_link.sort_values(
        by=["id", "source"], ascending=[True, False]
    ).drop_duplicates(subset=["id"], keep="first")

    # Extract locations
    area_website = get_website(AREA_SITE)
    areas = get_area_list_from_area_website(area_website)
    valid, diff = validate_location_list(areas)
    if not valid:
        raise ValueError(f"It seems there were new locations: {diff}")

    total_changes, new, depr = 0, 0, 0
    problem_data = {"type": "FeatureCollection", "features": []}
    for i, area in enumerate(areas):
        if area == " Private Rollers" or area == "_Collector Books_":
            continue

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
            this_address = geojson["properties"]["address"]
            this_update = geojson["temporary"]["website_updated"]
            match = False
            for cur_dict, name in zip([server_dict, device_dict], ["Server", "Device"]):
                keys = list(cur_dict.keys())
                if this_link in keys:
                    cur_states = [
                        cur_dict[this_link][s]["properties"]["status"]
                        for s in range(len(cur_dict[this_link]))
                    ]
                    if len(set(cur_states)) > 1:
                        geojson['properties']['id'] = -1
                        geojson['properties']['last_updated'] = -1
                        problem_data["features"].append(geojson)
                        logger.error(
                            f"{this_link} used in multiple pins with different states, requires manual handling: {cur_dict[this_link]}"
                        )
                        continue
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
                    cur_updates = [
                        cur_dict[this_link][s]["properties"]["last_updated"]
                        for s in range(len(cur_dict[this_link]))
                    ]
                    if len(set(cur_updates)) > 1:
                        geojson['properties']['id'] = -1
                        geojson['properties']['last_updated'] = -1
                        problem_data["features"].append(geojson)
                        logger.error(
                            f"{this_link} used in multiple pins with different dates, requires manual handling: {cur_dict[this_link]}"
                        )
                        continue
                    cur_updated = cur_updates[0]

                    if this_update < cur_updated:
                        # Our machine was updated more recently than the website
                        continue
                    elif (
                        cur_state == "unvisited"
                        and this_state in UNAVAILABLE_MACHINE_STATES
                    ):
                        logger.debug(f"{this_title} is currently unavailable")
                        # Machine is currently unavailable, update this in server dict
                        if name == "Device":
                            # Easy case, we just add this machine to server_dict
                            assert len(device_dict[this_link]) == 1
                            # Retire machine
                            entry = device_dict[this_link][0]
                            entry["properties"]["status"] = "retired"
                            entry["properties"]["active"] = False
                            entry["properties"]["last_updated"] = today
                            server_data["features"].append(entry)
                        elif name == "Server":
                            if len(server_dict[this_link]) > 1:
                                logger.warning(
                                    "A url linking to multiple machines retired, "
                                    f"maybe check manually: {server_dict[this_link]}"
                                )
                            # Extract all machines of that URL (usually 1)
                            idxs = [
                                i
                                for i, geojson in enumerate(server_data["features"])
                                if geojson["properties"]["external_url"] == this_link
                            ]
                            # Retire all machines of that URL
                            for idx in idxs:
                                server_data["features"][idx]["properties"][
                                    "status"
                                ] = "retired"
                                server_data["features"][idx]["properties"][
                                    "active"
                                ] = False
                                server_data["features"][idx]["properties"][
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
                            assert len(device_dict[this_link]) == 1
                            entry = device_dict[this_link][0]
                            entry["properties"]["status"] = "unvisited"
                            entry["properties"]["active"] = True
                            entry["properties"]["last_updated"] = today
                            entry["properties"]["name"] = entry["properties"][
                                "name"
                            ].strip()
                            entry["properties"]["address"] = entry["properties"][
                                "address"
                            ].strip()
                            server_data["features"].append(entry)
                        elif name == "Server":
                            # Machine is already documented in server_dict
                            entry = server_dict[this_link]
                            if len(entry) > 1:
                                logger.warning(
                                    "A url linking to multiple machines retired, "
                                    f"maybe check manually: {entry}"
                                )

                            # Extract all machines of that URL (usually 1)
                            idxs = [
                                i
                                for i, geojson in enumerate(server_data["features"])
                                if geojson["properties"]["external_url"] == this_link
                            ]
                            if len(idxs) > 1:
                                logger.warning(
                                    f"For {this_link} found {len(idxs)} machines: {idxs}"
                                )
                            # Re-activate all machines of that URL
                            for idx in idxs:
                                server_data["features"][idx]["properties"][
                                    "status"
                                ] = "unvisited"
                                server_data["features"][idx]["properties"][
                                    "active"
                                ] = True
                                server_data["features"][idx]["properties"][
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

            tdf = no_link[no_link.area == geojson["properties"]["area"]]
            if len(tdf) > 0:
                # Verify that machine is indeed new through fuzzy search
                match, score = fuzzysearch.extract(
                    this_title, list(tdf["name"]), limit=1
                )[0]

                if score > 87:
                    # There is a match, we have to update the link
                    # Extract the entry from original data
                    m_idx = list(tdf["name"]).index(match)
                    if tdf.iloc[m_idx]["source"] == "Device":
                        cur_data = device_data
                    else:
                        cur_data = server_data

                    e_entry = cur_data["features"][tdf.iloc[m_idx]["data_idx"]]
                    logger.info(
                        f"Seeems that machine {this_title} already exists as: {match}"
                    )
                    # Update machine and save in dict
                    assert e_entry["properties"]["external_url"] == "null"
                    if tdf.iloc[m_idx]["source"] == "Device":
                        e_entry["properties"]["external_url"] = this_link
                        e_entry["properties"]["last_updated"] = today
                        server_data["features"].append(e_entry)
                    else:
                        # Machine is already in server_dict, just update content
                        i = tdf.iloc[m_idx]["data_idx"]
                        server_data["features"][i]["properties"][
                            "external_url"
                        ] = this_link
                        server_data["features"][i]["properties"]["last_updated"] = today
                    continue

                match, score = fuzzysearch.extract(
                    this_address, list(tdf["address"]), limit=1
                )[0]

                if score >= 87:
                    # There is a match, we have to update the link
                    # Extract the entry from original data
                    m_idx = list(tdf["address"]).index(match)
                    if tdf.iloc[m_idx]["source"] == "Device":
                        cur_data = device_data
                    else:
                        cur_data = server_data

                    e_entry = cur_data["features"][tdf.iloc[m_idx]["data_idx"]]
                    logger.info(
                        f"Seeems that machine {this_title} at {this_address} already exists as: {match}"
                    )
                    # Update machine and save in dict
                    assert e_entry["properties"]["external_url"] == "null"
                    if tdf.iloc[m_idx]["source"] == "Device":
                        e_entry["properties"]["external_url"] = this_link
                        e_entry["properties"]["last_updated"] = today
                        server_data["features"].append(e_entry)
                    else:
                        # Machine is already in server_dict, just update content
                        i = tdf.iloc[m_idx]["data_idx"]
                        server_data["features"][i]["properties"][
                            "external_url"
                        ] = this_link
                        server_data["features"][i]["properties"]["last_updated"] = today
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
                api=gmaps,
            )

            geojson["properties"]["latitude"] = str(lat)
            geojson["properties"]["longitude"] = str(lng)
            geojson["geometry"]["coordinates"] = [lng, lat]
            geojson["properties"]["last_updated"] = today
            geojson["properties"]["id"] = machine_idx
            del geojson["temporary"]

            if (lat, lng) == (0, 0):
                geojson['properties']['id'] = -1
                geojson['properties']['last_updated'] = -1
                changes -= 1
                new -= 1
                problem_data["features"].append(geojson)
            else:
                machine_idx += 1
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
    # Make sure that no machines occur twice in server_locations
    ids = [entry["properties"]["id"] for entry in server_data["features"]]
    counts = Counter(ids)
    if len(ids) != len(counts):
        dups = [(v, c) for v, c in counts.items() if c > 1]
        raise ValueError(f"Identified duplicate machines: {dups}")

    fn = "server_locations.json"
    with open(os.path.join(output_folder, fn), "w", encoding="utf8") as f:
        json.dump(server_data, f, ensure_ascii=False, indent=4)

    if len(problem_data["features"]) > 0:
        logger.error(
            f"Found {len(problem_data['features'])} problems that require manual intervention"
        )
        with open(
            os.path.join(output_folder, "problems.json"), "w", encoding="utf8"
        ) as f:
            json.dump(problem_data, f, ensure_ascii=False, indent=4)

    end_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    logger.info(f"======Location differ completed at {end_time}=======")


if __name__ == "__main__":
    args = parser.parse_args()
    location_differ(
        args.output_folder,
        args.device_json,
        args.server_json,
        args.api_key,
        args.load_from_github
    )
