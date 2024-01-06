import json
import os
import queue
import random
import sys
from datetime import datetime
from threading import Thread
from typing import Any, Dict

import pandas as pd
from flask import Flask, jsonify, request
from googlemaps import Client as GoogleMaps
from haversine import haversine
from loguru import logger
from scripts.location_differ import location_differ
from scripts.open_diff_pull_request import open_differ_pr
from thefuzz import process as fuzzysearch

from pennyme.github_update import (
    get_latest_commit_time,
    load_latest_json,
    process_machine_change,
    push_newmachine_to_github,
    wait,
)
from pennyme.locations import COUNTRIES
from pennyme.slack import (
    image_slack,
    message_slack,
    message_slack_raw,
    process_uploaded_image,
)
from pennyme.utils import find_machine_in_database

app = Flask(__name__)
request_queue = queue.Queue()


PATH_COMMENTS = os.path.join("..", "..", "images", "comments")
PATH_IMAGES = os.path.join("..", "..", "images")
PATH_MACHINES = os.path.join("..", "data", "all_locations.json")
GM_CLIENT = GoogleMaps(open("../../gpc_api_key.keypair", "r").read())

with open("blocked_ips.json", "r") as infile:
    # NOTE: blocking an IP requires restart of app.py via waitress
    blocked_ips = json.load(infile)

with open("ip_comment_dict.json", "r") as f:
    IP_COMMENT_DICT = json.load(f)


@app.route("/add_comment", methods=["GET"])
def add_comment():
    """Receives a comment and adds it to the json file."""

    comment = str(request.args.get("comment"))
    machine_id = str(request.args.get("id"))

    ip_address = request.remote_addr
    if ip_address in blocked_ips:
        return jsonify({"error": "User IP address is blocked"}), 403

    path_machine_comments = os.path.join(PATH_COMMENTS, f"{machine_id}.json")
    if os.path.exists(path_machine_comments):
        with open(path_machine_comments, "r") as infile:
            # take previous comments and add paragaph
            all_comments = json.load(infile)
    else:
        all_comments = {}

    all_comments[str(datetime.now())] = comment

    with open(path_machine_comments, "w") as outfile:
        json.dump(all_comments, outfile, indent=4)

    # send message to slack
    message_slack(machine_id, comment, ip=ip_address)

    save_comment(comment, ip_address, machine_id)

    return jsonify({"message": "Success!"}), 200


@app.route("/upload_image", methods=["POST"])
def upload_image():
    """Receives an image and saves it to the server."""
    machine_id = str(request.args.get("id"))
    ip_address = request.remote_addr
    if ip_address in blocked_ips:
        return jsonify({"error": "User IP address is blocked"}), 403

    if "image" not in request.files:
        return jsonify({"error": "No image file found"}), 400

    img_path = os.path.join(PATH_IMAGES, f"{machine_id}.jpg")
    request.files["image"].save(img_path)
    process_uploaded_image(img_path)

    # send message to slack
    image_slack(machine_id, ip=ip_address)

    return "Image uploaded successfully"


def save_comment(comment: str, ip: str, machine_id: int):
    """
    Saves a comment to the json file.

    Args:
        comment: The comment to save.
        ip: The IP address of the user.
        machine_id: The ID of the machine.
    """
    # Create dict hierarchy if needed
    if ip not in IP_COMMENT_DICT.keys():
        IP_COMMENT_DICT[ip] = {}
    if machine_id not in IP_COMMENT_DICT[ip].keys():
        IP_COMMENT_DICT[ip][machine_id] = {}

    # Add comment
    IP_COMMENT_DICT[ip][machine_id][str(datetime.now())] = comment

    # Resave the file
    with open("ip_comment_dict.json", "w") as f:
        json.dump(IP_COMMENT_DICT, f, indent=4)


def process_machine_entry(
    new_machine_entry: Dict[str, Any],
    tmp_img_path: str,
    ip_address: str,
    title: str,
    address: str,
):
    """
    Process a new machine entry (upload image, send message to slack, etc.)
    Typically executed from a thread to avoid clash with cron job

    Args:
        new_machine_entry: The new machine entry to process.
        tmp_img_path: Temporary path to the image.
        ip_address: The IP address of the user.
        title: The title of the machine.
        address: The address of the machine.
    """

    try:
        # Wait for cron job to finish and until 5 min passed since last commit
        wait()
        # We can add machine
        new_machine_id = push_newmachine_to_github(new_machine_entry)

        # Move the image file from temporary to permanent path
        img_path = os.path.join(PATH_IMAGES, f"{new_machine_id}.jpg")
        os.rename(tmp_img_path, img_path)

        # Upload the image
        process_uploaded_image(img_path)

        # Send message to slack
        image_slack(
            new_machine_id,
            ip=ip_address,
            m_name=title,
            img_slack_text="New machine proposed:",
        )
    except Exception as e:
        message_slack_raw(
            text=f"Error when processing machine entry: {title}, {address} ({e})",
        )


def address_to_coordinates(address: str, area: str, title: str) -> (bool, tuple):
    """
    Geocode address (inputting address, area and title) and return coordinates if found

    Args:
        address: str with the machine address
        area: str of the area
        title: machine title

    Returns:
        bool: True if coordinates were found, else False
        tuple: (latitude, longitude) if found, else (None, None)
    """
    # Verify that address matches coordinates
    queries = [address, address + area, address + title]
    found_coords = False
    for query in queries:
        coordinates = GM_CLIENT.geocode(query)
        try:
            lat = coordinates[0]["geometry"]["location"]["lat"]
            lng = coordinates[0]["geometry"]["location"]["lng"]
            found_coords = True
            break
        except IndexError:
            continue
    if not found_coords:
        return False, (None, None)
    return found_coords, (lat, lng)


@app.route("/create_machine", methods=["POST"])
def create_machine():
    """Receives a comment and adds it to the json file."""
    title = str(request.args.get("title")).strip()
    address = str(request.args.get("address")).strip()
    area = str(request.args.get("area")).strip()

    # Identify area
    area, score = fuzzysearch.extract(area, COUNTRIES, limit=1)[0]
    if score < 90:
        return (
            jsonify(
                {
                    "error": "Could not match country. Provide country or US state name in English"
                }
            ),
            400,
        )

    location = (
        float(request.args.get("lon_coord")),
        float(request.args.get("lat_coord")),
    )
    # Verify that address matches coordinates
    found_coords, (lat, lng) = address_to_coordinates(address, area, title)
    if not found_coords:
        return jsonify({"error": "Google Maps does not know this address"}), 400

    dist = haversine((lat, lng), (location[1], location[0]))
    if dist > 1:  # km
        return (
            jsonify(
                {
                    "error": f"Address {address} seems >1km away from coordinates ({location[1]}, {location[0]})"
                }
            ),
            400,
        )

    out = GM_CLIENT.reverse_geocode(
        [location[1], location[0]], result_type="street_address"
    )

    b = True
    if out != []:
        ad = out[0]["formatted_address"]
        _, score = fuzzysearch.extract(ad, [address], limit=1)[0]
        if score > 85:
            # Prefer Google Maps address over user address
            address = ad
            b = False
    elif b:
        out = GM_CLIENT.reverse_geocode(
            (location[1], location[0]), result_type="point_of_interest"
        )
        if out != []:
            address = out[0]["formatted_address"]
        else:
            out = GM_CLIENT.reverse_geocode(
                (location[1], location[0]), result_type="postal_code"
            )
            if out != []:
                postal_code = out[0]["formatted_address"].split(" ")[0]
                if postal_code not in address:
                    address += out[0]["formatted_address"]

    try:
        multimachine = int(request.args.get("multimachine"))
    except ValueError:
        # just put the multimachine as a string, we need to correct it then
        multimachine = str(request.args.get("multimachine"))

    paywall = True if request.args.get("paywall") == "true" else False

    # put properties into dictionary
    properties_dict = {
        "name": title,
        "area": area,
        "address": address,
        "status": "unvisited",
        "external_url": "null",
        "internal_url": "null",
        "latitude": location[1],
        "longitude": location[0],
        "machine_status": "available",
        "id": -1,  # to be updated later
        "last_updated": str(datetime.today()).split(" ")[0],
    }
    # add multimachine or paywall only if not defaults
    if multimachine != 1:
        properties_dict["multimachine"] = multimachine
    if paywall:
        properties_dict["paywall"] = paywall
    # add new item to json
    new_machine_entry = {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": location},
        "properties": properties_dict,
    }
    ip_address = request.remote_addr

    tmp_path = os.path.join(PATH_IMAGES, f"{random.randint(-(2**16), -1)}.jpg")
    request.files["image"].save(tmp_path)

    message_slack_raw(text=f"New machine proposed: {title}, {address} ({area})")
    # Add to queue
    request_queue.put(
        (
            process_machine_entry,
            (new_machine_entry, tmp_path, ip_address, title, address),
        )
    )

    return jsonify({"message": "Success!"}), 200


@app.route("/change_machine", methods=["POST"])
def change_machine():
    """
    Receives a request for change of a machine and commits to the `DATA_BRANCH`.
    """
    machine_id = int(request.args.get("id"))
    title = str(request.args.get("title")).strip()
    address = str(request.args.get("address")).strip()
    area = str(request.args.get("area")).strip()
    status = str(request.args.get("status")).strip()
    latitude = float(request.args.get("lat_coord"))
    longitude = float(request.args.get("lon_coord"))
    ip = request.remote_addr

    # Load server locations and find existing machine info
    server_locations, latest_commit_sha = load_latest_json()
    (
        existing_machine_infos,
        index_in_server_locations,
    ) = find_machine_in_database(machine_id, server_locations["features"])

    msg = " - Changed:\n"

    latest_commit = get_latest_commit_time("main")
    latest_change = pd.to_datetime(existing_machine_infos["properties"]["last_updated"])
    if latest_change.date() >= latest_commit.date():
        msg += "Machine with pending changes is getting changed *AGAIN* @jannisborn @NinaWie:\n"

    # Start new dictionary
    updated_machine_entry = existing_machine_infos.copy()
    updated_machine_entry["properties"]["last_updated"] = str(datetime.today()).split(
        " "
    )[0]

    # Case 1: status was changed:
    if status != existing_machine_infos["properties"]["machine_status"]:
        msg += f"\tStatus from: {updated_machine_entry['properties']['machine_status']} to: {status}\n"
        updated_machine_entry["properties"]["machine_status"] = status

    # Case 2: if area was changed -> match to available areas
    if area != existing_machine_infos["properties"]["area"]:
        # Identify area
        area, score = fuzzysearch.extract(area, COUNTRIES, limit=1)[0]
        if score < 90:
            return (
                jsonify(
                    {
                        "error": "Could not match country. Provide country or US state name in English"
                    }
                ),
                400,
            )
        updated_machine_entry["properties"]["area"] = area
        msg += (
            f"\tArea from: {existing_machine_infos['properties']['area']} to: {area} \n"
        )

    # Case 3: Title changed
    if title != existing_machine_infos["properties"]["name"]:
        msg += f"\tTitle from: {existing_machine_infos['properties']['name']} to: {title}\n"
        updated_machine_entry["properties"]["name"] = title

    # Case 4: multimachine changed
    try:
        multimachine_new = int(request.args.get("multimachine"))
    except ValueError:
        # just put the multimachine as a string, we need to correct it then
        multimachine_new = "TODO" + str(request.args.get("multimachine"))
    multimachine_old = existing_machine_infos["properties"].get("multimachine", 1)
    if multimachine_new != multimachine_old:
        updated_machine_entry["properties"]["multimachine"] = multimachine_new
        msg += f"\tMultimachine from: {multimachine_old} to: {multimachine_new}\n"

    # Case 5: paywall reported
    paywall_new = request.args.get("paywall") == "true"
    paywall_old = existing_machine_infos["properties"].get("paywall", False)
    if paywall_new != paywall_old:
        updated_machine_entry["properties"]["paywall"] = paywall_new
        msg += f"\t Paywall from: {paywall_old} to: {paywall_new}\n"

    # Case 6: address and / or location changed --> check for their correspondence
    (lng_old, lat_old) = existing_machine_infos["geometry"]["coordinates"]
    old_address = existing_machine_infos["properties"]["address"]
    # if address or coordinates were changed, compare them and return warning if needed
    address_okay = True
    if latitude != lat_old or longitude != lng_old or address != old_address:
        # Verify that address matches coordinates
        found_coords, (lat, lng) = address_to_coordinates(address, area, title)
        # if address was changed but is not found (error only if address was changed)
        if (not found_coords) and address != old_address:
            return jsonify({"error": "Google Maps does not know this address"}), 400

        dist = haversine((lat, lng), (latitude, longitude))
        if dist > 1:  # km
            address_okay = False  # triggers warning

        # adapt dictionary entries
        updated_machine_entry["properties"]["address"] = address
        updated_machine_entry["properties"]["latitude"] = str(latitude)
        updated_machine_entry["properties"]["longitude"] = str(longitude)
        updated_machine_entry["geometry"]["coordinates"] = [longitude, latitude]
        if address != old_address:
            msg += f"\tAddress from {old_address} to: {address}\n"
        if latitude != lat_old or longitude != lng_old:
            msg += f"\t Location from {lat_old:.4f}, {lng_old:.4f} to: {latitude:.4f}, {longitude:.4f}."

    request_queue.put((process_machine_change, (updated_machine_entry, ip, msg)))

    # return warning if the address and coordinates do not correspond
    if not address_okay:
        return (
            jsonify(
                {
                    "error": f"Change request submitted successfully. However, the address ({address}) seems >1km away from coordinates ({latitude}, {longitude}). Consider adjusting your edits such that coordinates and address are aligned."
                }
            ),
            300,
        )
    return jsonify({"message": "Success!"}), 200


@app.route("/trigger_location_differ", methods=["POST"])
def trigger_location_differ():
    """
    Triggers the location differ script.
    """
    request_queue.put((run_location_differ, ()))
    return jsonify({"message": "Success!"}), 200


def run_location_differ():
    f = open("/root/PennyMe/new_data/cron.log", "w")
    sys.stdout = f
    sys.stderr = f

    old_json_file = "/root/PennyMe/new_data/old_server_locations.json"
    new_json_file = "/root/PennyMe/new_data/server_locations.json"
    new_problems_json_file = "/root/PennyMe/new_data/problems.json"
    debug_path = "/root/PennyMe/debug_new_data"

    # Make sure all preceding jobs are finished
    wait()

    location_differ(
        output_folder="/root/PennyMe/new_data",
        device_json="/root/PennyMe/data/all_locations.json",
        server_json=old_json_file,
        api_key=os.getenv("GCLOUD_KEY"),
        load_from_github=True,
    )
    open_differ_pr(locations_path=new_json_file, problems_path=new_problems_json_file)

    # Move files
    os.rename(
        new_problems_json_file,
        os.path.join(debug_path, os.path.basename(new_problems_json_file)),
    )
    os.rename(new_json_file, os.path.join(debug_path, os.path.basename(new_json_file)))

    f.close()


def worker():
    """
    Worker thread that processes the machine change requests.
    """
    while True:
        function, args = request_queue.get()
        try:
            function(*args)
        finally:
            request_queue.task_done()


# Start the worker thread
Thread(target=worker, daemon=True).start()


def create_app():
    logger.remove()
    logger.add(sys.stderr, level="DEBUG")  # Add stderr handler

    return app


if __name__ == "__main__":
    app.run(host="0.0.0.0")
