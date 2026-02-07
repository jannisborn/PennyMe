import json
import os
from pathlib import Path
from typing import Dict, Optional, Tuple

import cv2
import numpy as np
from loguru import logger
from PIL import Image, ImageOps
from rembg import new_session, remove
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

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


def process_uploaded_image(
    img_path: str,
    basewidth: int = 1000,
    min_area: int = 2000,
) -> Tuple[int, str, str]:
    """
    Optimizes an image for size/quality and re-saves it to the server.

    Args:
        img_path: The path to save the image to.
        basewidth: width of rescaled image, defaults to 1000. Used to be 400.
        min_area: minimal pixel count for a connected-area to be counted in coin
            foreground separation.

    Returns:
        String with success message
    """
    img = ImageOps.exif_transpose(Image.open(img_path))
    wpercent = basewidth / float(img.size[0])
    if wpercent <= 1:
        hsize = int((float(img.size[1]) * float(wpercent)))
        img = img.resize((basewidth, hsize), Image.Resampling.LANCZOS)

    # If image is a coin, apply background separation and always save as PNG.
    output_path = img_path
    if "coin" in img_path:
        img = remove(img, session=new_session("u2netp"))
        # Coin images are saved as PNG to support transparency
        output_path = img_path.replace(".jpg", ".png")

        # Return error if more than one connected comp
        m = (np.array(img)[:, :, 3] > 15).astype(np.uint8)
        n, _, s, _ = cv2.connectedComponentsWithStats(m, 8)
        keep = np.where(s[1:, 4] >= min_area)[0] + 1

        if keep.size == 0:
            return 422, "No foreground object found", img_path
        if keep.size > 1:
            return 409, f"Multiple foreground objects found ({keep.size})", img_path

        # Crop coin out of the image
        x, y, w, h = map(int, s[int(keep[0]), :4])
        pad = 20

        img = img.crop((max(0, x - pad), max(0, y - pad), x + w + pad, y + h + pad))
        img.save(output_path, quality=95)
        return 200, "OK", output_path

    img.save(output_path, quality=95)
    return 200, "OK", output_path


def image_slack(
    machine_id: int,
    ip: str,
    fname_suffix: str = "",
    m_name: str = None,
    img_slack_text: str = "Image uploaded for machine",
    filetype: Optional[str] = None,
):
    """
    Post an image to Slack.

    Args:
        machine_id: The ID of the machine.
        ip: The IP address of the user.
        fname_suffix: The suffix of the filename ("" or "_coin_x"). Defaults to "".
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
    if not filetype:
        filetype = "png" if "coin" in fname_suffix else "jpg"
    try:
        CLIENT.chat_postMessage(
            channel="#pennyme_uploads",
            text=text,
            username="PennyMe",
            blocks=[
                {
                    "type": "image",
                    "title": {
                        "type": "plain_text",
                        "text": text,
                        "emoji": True,
                    },
                    "image_url": f"{IMG_PORT}{machine_id}{fname_suffix}.{filetype}",
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
