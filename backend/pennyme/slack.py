import json
import os
from typing import Dict

from loguru import logger
from PIL import Image, ImageOps
from slack import WebClient
from slack.errors import SlackApiError

from pennyme.utils import ALL_LOCATIONS

CLIENT = WebClient(token=os.environ["SLACK_TOKEN"])
IMG_PORT = "http://37.120.179.15:8000/"
THIS_PATH = os.path.abspath(__file__)
# Construct paths based on the location of the current script
PATH_SERVER_LOCATION = os.path.join(
    os.path.dirname(THIS_PATH), "..", "..", "..", "images", "server_locations.json"
)

MACHINE_NAMES = {
    elem["properties"][
        "id"
    ]: f"{elem['properties']['name']} ({elem['properties']['area']}) "
    + f"Status={elem['properties']['machine_status']} at: {elem['properties']['external_url']}"
    for elem in ALL_LOCATIONS["features"]
}


def reload_server_data() -> Dict[str, str]:
    """
    Reloads the server data from the json file and extracts specific information, e.g.,
    to display in Slack.

    Returns:
        Dictionary with machine IDs as keys and machine names as values.
    """
    # add server location IDs
    with open(PATH_SERVER_LOCATION, "r", encoding="latin-1") as infile:
        d = json.load(infile)
    for elem in d["features"]:
        MACHINE_NAMES[elem["properties"]["id"]] = (
            f"{elem['properties']['name']} ({elem['properties']['area']})"
            + f"Status={elem['properties']['machine_status']} at: {elem['properties']['external_url']}"
        )
    return MACHINE_NAMES


def process_uploaded_image(img_path: str, basewidth: int = 1000):
    """
    Optimizes an image for size/quality and re-saves it to the server.

    Args:
        img_path: The path to save the image to.
        basewidth: width of rescaled image, defaults to 1000. Used to be 400.
    """
    img = Image.open(img_path)
    img = ImageOps.exif_transpose(img)
    wpercent = basewidth / float(img.size[0])
    if wpercent > 1:
        return "Image uploaded successfully, no resize necessary"
    # resize
    hsize = int((float(img.size[1]) * float(wpercent)))
    img = img.resize((basewidth, hsize), Image.Resampling.LANCZOS)
    img.save(img_path, quality=95)


def image_slack(
    machine_id: int,
    ip: str,
    m_name: str = None,
    img_slack_text: str = "Image uploaded for machine",
):
    """
    Post an image to Slack.

    Args:
        machine_id: The ID of the machine.
        ip: The IP address of the user.
        m_name: The name of the machine. Defaults to None.
        img_slack_text: The text to display in the Slack message. Defaults to "Image uploaded for machine".

    Raises:
        e: SlackApiError
    """
    if m_name is None:
        MACHINE_NAMES = reload_server_data()
        if int(machine_id) not in MACHINE_NAMES.keys():
            logger.error(f"Posting image, but ID {machine_id} not found in server data")
            return
        m_name = MACHINE_NAMES[int(machine_id)]
    text = f"{img_slack_text} {machine_id} - {m_name} (from {ip})"
    try:
        CLIENT.chat_postMessage(
            channel="#pennyme_uploads", text=text, username="PennyMe"
        )
        CLIENT.chat_postMessage(
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


def message_slack(machine_id: str, comment_text: str, ip: str):
    """
    Send a message to Slack.

    Args:
        machine_id: The ID of the machine, given as a string.
        comment_text: The comment to send.
        ip: The IP address of the user.

    Raises:
        e: SlackApiError, if the message could not be sent.
    """
    MACHINE_NAMES = reload_server_data()
    if int(machine_id) not in MACHINE_NAMES.keys():
        logger.error(f"Messaging slack: {comment_text} but ID {machine_id} not found.")

    m_name = MACHINE_NAMES[int(machine_id)]
    prefix = m_name.split("Status=")[0]
    postfix = "Status=" + m_name.split("Status=")[-1]
    text = f"New comment for machine {machine_id} - {prefix}: {comment_text} (from {ip}. Machine: {postfix}"

    message_slack_raw(text)


def message_slack_raw(text: str, *args, **kwargs):
    """
    Send a message to Slack, unspecific to a machine.

    Args:
        text: The message to send.
    """
    try:
        CLIENT.chat_postMessage(
            channel="#pennyme_uploads", text=text, username="PennyMe"
        )
    except SlackApiError as e:
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e
