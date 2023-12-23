import json
import os
import time
from datetime import datetime
from threading import Thread
from typing import Any, Dict

from flask import Flask, jsonify, request
from googlemaps import Client as GoogleMaps
from haversine import haversine
from thefuzz import process as fuzzysearch
from werkzeug.datastructures import FileStorage

from pennyme.github_update import isbusy, push_newmachine_to_github
from pennyme.locations import COUNTRIES
from pennyme.slack import (
    image_slack,
    message_slack,
    message_slack_raw,
    process_uploaded_image,
)

app = Flask(__name__)

PATH_COMMENTS = os.path.join("..", "..", "images", "comments")
PATH_IMAGES = os.path.join("..", "..", "images")
PATH_MACHINES = os.path.join("..", "data", "all_locations.json")
GM_CLIENT = GoogleMaps(open("../../gpc_api_key.keypair", "r").read())

with open("blocked_ips.json", "r") as infile:
    # NOTE: blocking an IP requires restart of app.py via waitress
    blocked_ips = json.load(infile)

with open(PATH_MACHINES, "r", encoding="latin-1") as infile:
    d = json.load(infile)
MACHINE_NAMES = {
    elem["properties"][
        "id"
    ]: f"{elem['properties']['name']} ({elem['properties']['area']}) Status={elem['properties']['machine_status']}"
    for elem in d["features"]
}

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

    image = request.files["image"]
    img_path = os.path.join(PATH_IMAGES, f"{machine_id}.jpg")
    process_uploaded_image(image, img_path)

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
    image: FileStorage,
    ip_address: str,
    title: str,
    address: str,
):
    """
    Process a new machine entry (upload image, send message to slack, etc.)
    Typically executed from a thread to avoid clash with cron job

    Args:
        new_machine_entry: The new machine entry to process.
        image: The image to save, obtained via Flask's request.files["image"].
        ip_address: The IP address of the user.
        title: The title of the machine.
        address: The address of the machine.
    """
    try:
        # Optional waiting if cron job is running
        if isbusy():
            message_slack_raw(
                ip=ip_address,
                text="Found conflicting cron job, waiting for it to finish...",
            )
            counter = 0
            while isbusy() and counter < 60:
                time.sleep(300)  # Retry every 5min
                counter += 1
            if counter == 60:
                message_slack_raw(
                    ip=ip_address,
                    text="Timeout of 5h reached, cron job still runs, aborting...",
                )
                return

        # Cron job has finished, we can add machine
        new_machine_id = push_newmachine_to_github(new_machine_entry)

        # Upload the image
        if image:
            img_path = os.path.join(PATH_IMAGES, f"{new_machine_id}.jpg")
            process_uploaded_image(image, img_path)

            # Send message to slack
            image_slack(
                new_machine_id,
                ip=ip_address,
                m_name=title,
                img_slack_text="New machine proposed:",
            )
        else:
            message_slack(
                new_machine_id,
                ip=ip_address,
                m_name=title,
                img_slack_text="Picture missing for machine!",
            )
    except Exception as e:
        message_slack_raw(
            ip=ip_address,
            text=f"Error when processing machine entry: {title}, {address} ({e})",
        )


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
    queries = [address, address + area, address + title]
    for query in queries:
        coordinates = GM_CLIENT.geocode(query)
        try:
            lat = coordinates[0]["geometry"]["location"]["lat"]
            lng = coordinates[0]["geometry"]["location"]["lng"]
            break
        except IndexError:
            continue
    try:
        lat, lng
    except NameError:
        return jsonify({"error": "Google Maps does not know this address"}), 400

    dist = haversine((lat, lng), (location[1], location[0]))
    if dist > 1:  # km
        return (
            jsonify(
                {
                    "error": f"Address {query} seems >1km away from coordinates ({lat}, {lng})"
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
    image = request.files.get("image", None)
    message_slack_raw(
        ip=ip_address, text=f"New machine proposed: {title}, {address} ({area})"
    )

    # Create and start the thread
    thread = Thread(
        target=process_machine_entry,
        args=(new_machine_entry, image, ip_address, title, address),
    )
    thread.start()

    return jsonify({"message": "Success!"}), 200


def create_app():
    return app


if __name__ == "__main__":
    app.run(host="0.0.0.0")
