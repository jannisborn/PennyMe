import json
import os
import time
from datetime import datetime
from typing import Any, Dict

from flask import Flask, jsonify, request
from googlemaps import Client as GoogleMaps
from PIL import Image, ImageOps

from haversine import haversine
from pennyme.locations import COUNTRIES
from pull_request import push_to_github_and_open_pr, get_latest_data_update
from slack import WebClient
from slack.errors import SlackApiError
from thefuzz import process as fuzzysearch

app = Flask(__name__)

PATH_COMMENTS = os.path.join("..", "..", "images", "comments")
PATH_IMAGES = os.path.join("..", "..", "images")
PATH_MACHINES = os.path.join("..", "data", "all_locations.json")
PATH_SERVER_LOCATION = os.path.join("..", "..", "images", "server_locations.json")
SLACK_TOKEN = os.environ.get("SLACK_TOKEN")
IMG_PORT = "http://37.120.179.15:8000/"
GM_API_KEY = open("../../gpc_api_key.keypair", "r").read()

client = WebClient(token=os.environ["SLACK_TOKEN"])
gm_client = GoogleMaps(GM_API_KEY)

with open("blocked_ips.json", "r") as infile:
    # NOTE: blocking an IP requires restart of app.py via waitress
    blocked_ips = json.load(infile)

with open(PATH_MACHINES, "r", encoding="latin-1") as infile:
    d = json.load(infile)
MACHINE_NAMES = {
    elem["properties"][
        "id"
    ]: f"{elem['properties']['name']} ({elem['properties']['area']})"
    for elem in d["features"]
}

with open("ip_comment_dict.json", "r") as f:
    IP_COMMENT_DICT = json.load(f)


def reload_server_data():
    # add server location IDs
    with open(PATH_SERVER_LOCATION, "r", encoding="latin-1") as infile:
        d = json.load(infile)
    for elem in d["features"]:
        MACHINE_NAMES[
            elem["properties"]["id"]
        ] = f"{elem['properties']['name']} ({elem['properties']['area']})"
    return MACHINE_NAMES


@app.route("/add_comment", methods=["GET"])
def add_comment():
    """
    Receives a comment and adds it to the json file
    """

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


def process_uploaded_image(image, img_path):
    image.save(img_path)

    # optimize file size
    img = Image.open(img_path)
    img = ImageOps.exif_transpose(img)
    basewidth = 400
    wpercent = basewidth / float(img.size[0])
    if wpercent > 1:
        return "Image uploaded successfully, no resize necessary"
    # resize
    hsize = int((float(img.size[1]) * float(wpercent)))
    img = img.resize((basewidth, hsize), Image.Resampling.LANCZOS)
    img.save(img_path, quality=95)


@app.route("/upload_image", methods=["POST"])
def upload_image():
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


def image_slack(
    machine_id: int,
    ip: str,
    m_name: str = None,
    img_slack_text: str = "Image uploaded for machine",
):

    if m_name is None:
        MACHINE_NAMES = reload_server_data()
        m_name = MACHINE_NAMES[int(machine_id)]
    text = f"{img_slack_text} {machine_id} - {m_name} (from {ip})"
    try:
        response = client.chat_postMessage(
            channel="#pennyme_uploads", text=text, username="PennyMe"
        )
        response = client.chat_postMessage(
            channel="#pennyme_uploads",
            text=text,
            username="PennyMe",
            blocks=[
                {
                    "type": "image",
                    "title": {
                        "type": "plain_text",
                        "text": "NEW Image!",
                        "emoji": True,
                    },
                    "image_url": f"{IMG_PORT}{machine_id}.jpg",
                    "alt_text": text,
                }
            ],
        )
    except SlackApiError as e:
        print("Error sending message: ", e)
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e


def message_slack(machine_id, comment_text, ip: str):
    MACHINE_NAMES = reload_server_data()
    m_name = MACHINE_NAMES[int(machine_id)]
    text = (
        f"New comment for machine {machine_id} - {m_name}: {comment_text} (from {ip})"
    )
    try:
        response = client.chat_postMessage(
            channel="#pennyme_uploads", text=text, username="PennyMe"
        )
    except SlackApiError as e:
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e


def save_comment(comment: str, ip: str, machine_id: int):

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


@app.route("/create_machine", methods=["POST"])
def create_machine():
    """
    Receives a comment and adds it to the json file
    """
    title = str(request.args.get("title")).strip()
    address = str(request.args.get("address")).strip()
    area = str(request.args.get("area")).strip()

    # Identify area
    area, score = fuzzysearch.extract(area, COUNTRIES, limit=1)
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
        coordinates = gm_client.geocode(query)
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

    out = gm_client.reverse_geocode((location[1], location[0]), result_type="address")

    b = True
    if out != []:
        ad = out[0]["formatted_address"]
        _, score = fuzzysearch.extract(ad, [address], limit=1)
        if score > 85:
            # Prefer Google Maps address over user address
            address = ad
            b = False
    elif b:
        out = gm_client.reverse_geocode(
            (location[1], location[0]), result_type="point_of_interest"
        )
        if out != []:
            address = out[0]["formatted_address"]
        else:
            out = gm_client.reverse_geocode(
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

    potential_new_machines = [
        int(im.split(".")[0]) for im in os.listdir(PATH_IMAGES) if "jpg" in im
    ]
    # note: this is not the final id yet, we double check with the max in the server
    # locations file
    new_machine_id = max(potential_new_machines) + 1

    # put properties into dictionary
    properties_dict = {
        "name": title,
        "active": True,
        "area": area,
        "address": address,
        "status": "unvisited",
        "external_url": "null",
        "internal_url": "null",
        "latitude": location[1],
        "longitude": location[0],
        "id": new_machine_id,
        "last_updated": str(datetime.today()).split(" ")[0],
    }
    # add multimachine or paywall only if not defaults
    if multimachine != 1:
        properties_dict["multimachine"] = multimachine
    if paywall:
        properties_dict["paywall"] = paywall
    # add new item to json
    new_machines_entry = {
        {
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": location},
            "properties": properties_dict,
        }
    }
    # If pushing to new branch: set unique branch name
    # branch_name = f"new_machine_{round(time.time())}"
    new_machine_id = push_to_github(server_locations)

    # Upload the image
    if "image" not in request.files:
        return "No image file", 400
    image = request.files["image"]
    ip_address = request.remote_addr
    # crop and save the image
    img_path = os.path.join(PATH_IMAGES, f"{new_machine_id}.jpg")
    process_uploaded_image(image, img_path)

    # send message to slack
    image_slack(
        new_machine_id,
        ip=ip_address,
        m_name=title,
        img_slack_text="New machine proposed:",
    )

    return jsonify({"message": "Success!"}), 200


def create_app():
    return app


if __name__ == "__main__":
    app.run(host="0.0.0.0")
