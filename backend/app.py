import json
import os
from datetime import datetime
from flask import Flask, jsonify, request
from PIL import Image, ImageOps

from slack import WebClient
from slack.errors import SlackApiError

app = Flask(__name__)

PATH_COMMENTS = os.path.join("..", "..", "images", "comments")
PATH_IMAGES = os.path.join("..", "..", "images")
PATH_MACHINES = os.path.join("..", "data", "all_locations.json")
PATH_SERVER_LOCATION = os.path.join("..", "..", "images", "server_locations.json")
SLACK_TOKEN = os.environ.get("SLACK_TOKEN")
IMG_PORT = "http://37.120.179.15:8000/"

client = WebClient(token=os.environ["SLACK_TOKEN"])

with open("blocked_ips.json", "r") as infile:
    # NOTE: blocking an IP requires restart of app.py via waitress
    blocked_ips = json.load(infile)

with open(PATH_MACHINES, "r", encoding="latin-1") as infile:
    d = json.load(infile)
machine_names = {
    elem["properties"]["id"]:
    f"{elem['properties']['name']} ({elem['properties']['area']})"
    for elem in d["features"]
}
# add server location IDs
with open(PATH_SERVER_LOCATION, "r", encoding="latin-1") as infile:
    d = json.load(infile)
for elem in d["features"]:
    machine_names[elem["properties"]["id"]] = f"{elem['properties']['name']} ({elem['properties']['area']})"

@app.route("/add_comment", methods=["GET"])
def add_comment():
    """
    Receives a comment and adds it to the json file
    """

    comment = str(request.args.get("comment"))
    machine_id = str(request.args.get("id"))

    ip_address = request.remote_addr
    if ip_address in blocked_ips:
        return jsonify("Blocked IP address")

    with open("comments_by_ip.txt", "a") as myfile:
        myfile.write(f"\n{ip_address} {comment}")

    path_machine_comments = os.path.join(PATH_COMMENTS, f"{machine_id}.json")
    if os.path.exists(path_machine_comments):
        with open(path_machine_comments, "r") as infile:
            # take previous comments and add paragaph
            all_comments = json.load(infile)
    else:
        all_comments = {}

    all_comments[str(datetime.now())] = comment

    with open(path_machine_comments, "w") as outfile:
        json.dump(all_comments, outfile)

    # send message to slack
    message_slack(machine_id, comment, ip=ip_address)

    return jsonify({"response": 200})


@app.route("/upload_image", methods=["POST"])
def upload_image():
    machine_id = str(request.args.get("id"))
    ip_address = request.remote_addr
    if ip_address in blocked_ips:
        return jsonify("Blocked IP address")

    if "image" not in request.files:
        return "No image file", 400

    image = request.files["image"]
    img_path = os.path.join(PATH_IMAGES, f"{machine_id}.jpg")
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

    # send message to slack
    image_slack(machine_id, img_path=img_path, ip=ip_address)

    return "Image uploaded successfully"


def image_slack(machine_id: int, img_path: str, ip: str):
    m_name = machine_names[int(machine_id)]
    text = f"Image uploaded for machine {machine_id} - {m_name} (from {ip})"
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
                        "emoji": True
                    },
                    "image_url": f"{IMG_PORT}{machine_id}.jpg",
                    "alt_text": text
                }
            ]
        )
    except SlackApiError as e:
        print("Error sending message: ", e)
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e



def message_slack(machine_id, comment_text, ip: str):
    m_name = machine_names[int(machine_id)]
    text = f"New comment for machine {machine_id} - {m_name}: {comment_text} (from {ip})"
    try:
        response = client.chat_postMessage(
            channel="#pennyme_uploads", text=text, username="PennyMe"
        )
    except SlackApiError as e:
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e


def create_app():
    return app


if __name__ == "__main__":
    app.run(host="0.0.0.0")
