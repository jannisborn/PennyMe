import os
from pathlib import Path
from threading import Thread
from typing import Any, Dict, Optional, Tuple

import cv2
import numpy as np
from loguru import logger
from PIL import Image, ImageOps
from rembg import new_session, remove
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from slack_sdk.errors import SlackApiError

from pennyme.database import (
    approve_pending_change,
    get_machine_display_names,
    reject_pending_change,
)
from pennyme.utils import ALL_LOCATIONS

SLACK_APP = App(token=os.environ["SLACK_TOKEN"])
CLIENT = SLACK_APP.client
IMG_PORT = "http://37.120.179.15:8000/"
THIS_PATH = os.path.abspath(__file__)

MACHINE_NAMES = {
    elem["properties"][
        "id"
    ]: f"{elem['properties']['name']} ({elem['properties']['area']}) "
    + f"Status={elem['properties']['machine_status']} at: {elem['properties']['external_url']}"
    for elem in ALL_LOCATIONS["features"]
}

# Maps pending_changes.id -> (channel, ts) of its Slack image message, so the
# image can be deleted once the change is approved/rejected. In-memory only:
# lost on restart, in which case deletion is silently skipped.
_PENDING_IMAGE_MESSAGES: Dict[int, Tuple[str, str]] = {}


def format_machine_fields(fields: Dict[str, Any]) -> str:
    """Format non-None machine fields as readable 'field_name: value' lines.

    Latitude/longitude are skipped since they are rendered as a Maps link
    instead (see `message_slack_pending_change`).
    """
    lines = []
    for key, value in fields.items():
        if value is None or key in ("latitude", "longitude"):
            continue
        lines.append(f"{key}: {value}")
    return "\n".join(lines)


def save_image(
    img: Image.Image, output_path: str, max_size_bytes: int = 500 * 1024
) -> None:
    """Save an image, shrinking it until it fits within the byte limit."""
    while True:
        img.save(output_path, quality=95, optimize=True)
        if Path(output_path).stat().st_size <= max_size_bytes:
            return
        if img.size == (1, 1):
            Path(output_path).unlink()
            raise ValueError(f"Could not compress image below {max_size_bytes} bytes")
        img.thumbnail(
            tuple(max(1, dimension // 2) for dimension in img.size),
            Image.Resampling.LANCZOS,
        )


def reload_server_data() -> Dict[str, str]:
    """
    Reloads the machine display names from the database, e.g., to display in Slack.

    Returns:
        Dictionary with machine IDs as keys and machine names as values.
    """
    MACHINE_NAMES.update(get_machine_display_names())
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
    img.thumbnail((basewidth, basewidth), Image.Resampling.LANCZOS)

    # If image is a coin, apply background separation and always save as PNG.
    output_path = img_path
    if "coin" in img_path:
        img = remove(img, session=new_session("u2netp"))
        # Coin images are saved as PNG to support transparency
        in_path = Path(img_path)
        out_path = in_path.with_suffix(".png")
        output_path = str(out_path)

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
        save_image(img, output_path)
        # delete original image if we wrote to a different path
        if out_path != in_path:
            in_path.unlink()
        return 200, "OK", output_path

    save_image(img, output_path)
    return 200, "OK", output_path


def image_slack(
    machine_id: int,
    fname_suffix: str = "",
    m_name: Optional[str] = None,
    img_slack_text: str = "Image uploaded for machine",
    filetype: Optional[str] = None,
    pending: bool = False,
) -> None:
    """Post an image to Slack.

    Args:
        machine_id: The ID of the machine (or pending_changes row when pending=True).
        fname_suffix: The suffix of the filename ("" or "_coin_x"). Defaults to "".
        m_name: The name of the machine. Defaults to None.
        img_slack_text: The text to display in the Slack message. Defaults to "Image uploaded for machine".
        filetype: Explicit uploaded image file extension, when known.
        pending: When True, the image is a pending submission — uses pending_{machine_id}
            as the filename and posts to #pennyme_approvals.

    Returns:
        None.

    Raises:
        e: SlackApiError
    """
    if pending:
        fname_base = f"pending_{machine_id}"
        channel = "#pennyme_approvals"
        text = f"{img_slack_text} (pending #{machine_id})"
    else:
        fname_base = str(machine_id)
        channel = "#pennyme_uploads"
        if m_name is None:
            MACHINE_NAMES = reload_server_data()
            if int(machine_id) not in MACHINE_NAMES.keys():
                logger.error(
                    f"Posting image, but ID {machine_id} not found in server data"
                )
                return
            m_name = MACHINE_NAMES[int(machine_id)]
        text = f"{img_slack_text} {machine_id} - {m_name}"
    if not filetype:
        filetype = "png" if "coin" in fname_suffix else "jpg"
    try:
        response = CLIENT.chat_postMessage(
            channel=channel,
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
                    "image_url": f"{IMG_PORT}{fname_base}{fname_suffix}.{filetype}",
                    "alt_text": text,
                }
            ],
        )
        if pending:
            _PENDING_IMAGE_MESSAGES[int(machine_id)] = (
                response["channel"],
                response["ts"],
            )
    except SlackApiError as e:
        print("Error sending message: ", e)
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e


def message_slack(machine_id: str, comment_text: str) -> None:
    """Send a comment notification to Slack.

    Args:
        machine_id: The ID of the machine, given as a string.
        comment_text: The comment to send.

    Returns:
        None.

    Raises:
        e: SlackApiError, if the message could not be sent.
    """
    MACHINE_NAMES = reload_server_data()
    if int(machine_id) not in MACHINE_NAMES.keys():
        logger.error(f"Messaging slack: {comment_text} but ID {machine_id} not found.")

    m_name = MACHINE_NAMES[int(machine_id)]
    prefix = m_name.split("Status=")[0]
    postfix = "Status=" + m_name.split("Status=")[-1]
    text = (
        f"New comment for machine {machine_id} - {prefix}: "
        f"{comment_text}. Machine: {postfix}"
    )

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


# ---------------------------------------------------------------------------
# Slack Socket Mode — interactive button handlers
# ---------------------------------------------------------------------------


def _delete_pending_image_message(change_id: int) -> None:
    """Delete the Slack image message posted for a pending change, if any."""
    location = _PENDING_IMAGE_MESSAGES.pop(change_id, None)
    if location is None:
        return
    channel, ts = location
    try:
        CLIENT.chat_delete(channel=channel, ts=ts)
    except SlackApiError as e:
        logger.error(f"Error deleting image message for pending #{change_id}: {e}")


@SLACK_APP.action("approve_change")
def handle_approve_change(ack, body, respond) -> None:
    """Approve a pending change when the Approve button is clicked."""
    ack()
    change_id = int(body["actions"][0]["value"])
    user_name = body.get("user", {}).get("name", "unknown")
    try:
        result = approve_pending_change(change_id)
    except (KeyError, ValueError) as e:
        result_text = f":warning: Error approving change #{change_id}: {e}"
        logger.error(result_text)
    else:
        if result.applied:
            result_text = (
                f":white_check_mark: Pending change #{change_id} *approved* by "
                f"{user_name} — machine ID {result.machine_id}."
            )
        else:
            result_text = f":information_source: Pending change #{change_id} was already handled (status: {result.status})."
    _delete_pending_image_message(change_id)
    respond(replace_original=True, text=result_text)


@SLACK_APP.action("reject_change")
def handle_reject_change(ack, body, respond) -> None:
    """Reject a pending change when the Reject button is clicked."""
    ack()
    change_id = int(body["actions"][0]["value"])
    user_name = body.get("user", {}).get("name", "unknown")
    try:
        result = reject_pending_change(change_id)
    except KeyError as e:
        result_text = f":warning: Error rejecting change #{change_id}: {e}"
        logger.error(result_text)
    else:
        if result.applied:
            result_text = f":x: Pending change #{change_id} *rejected* by {user_name}."
        else:
            result_text = f":information_source: Pending change #{change_id} was already handled (status: {result.status})."
    _delete_pending_image_message(change_id)
    respond(replace_original=True, text=result_text)


def start_socket_mode_handler() -> None:
    """Start the Slack Socket Mode handler in a daemon thread.

    Requires the ``SLACK_APP_TOKEN`` environment variable — an App-Level Token
    with the ``connections:write`` scope (starts with ``xapp-``).
    Has no effect if the variable is not set.
    """
    app_token = os.environ.get("SLACK_APP_TOKEN", "")
    if not app_token:
        logger.warning(
            "SLACK_APP_TOKEN not set — Slack interactive buttons will not work"
        )
        return
    handler = SocketModeHandler(SLACK_APP, app_token)
    Thread(target=handler.start, daemon=True).start()
    logger.info("Slack Socket Mode handler started")


# ---------------------------------------------------------------------------
# Outgoing Slack helpers
# ---------------------------------------------------------------------------


def message_slack_pending_change(
    change_id: int,
    change_type: str,
    title: str,
    area: str,
    change_summary: str,
    machine_id: Optional[int] = None,
    latitude: Optional[float] = None,
    longitude: Optional[float] = None,
) -> None:
    """Post a pending change notification to Slack with Approve/Reject buttons.

    Args:
        change_id: The ID of the pending_changes row.
        change_type: ``'create'`` or ``'update'``.
        title: Machine name.
        area: Machine area/country.
        change_summary: Human-readable description of what changed.
        machine_id: Existing machine ID for updates, None for new machines.
        latitude: Machine latitude, to render a Google Maps link. Defaults to None.
        longitude: Machine longitude, to render a Google Maps link. Defaults to None.

    Raises:
        SlackApiError: If the Slack API call fails.
    """
    if change_type == "create":
        header = f":new: *New machine proposed (pending #{change_id})*"
    else:
        header = (
            f":pencil2: *Machine {machine_id} change proposed (pending #{change_id})*"
        )

    summary_text = change_summary.strip() or "(no summary)"
    if latitude is not None and longitude is not None:
        maps_url = f"https://www.google.com/maps?q={latitude},{longitude}"
        summary_text += f"\n<{maps_url}|View on Google Maps>"
    plain_text = f"{header}\n*{title}* ({area})\n{summary_text}"

    blocks = [
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"{header}\n*{title}* ({area})\n{summary_text}",
            },
        },
        {
            "type": "actions",
            "block_id": f"pending_{change_id}",
            "elements": [
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "Approve", "emoji": True},
                    "style": "primary",
                    "value": str(change_id),
                    "action_id": "approve_change",
                },
                {
                    "type": "button",
                    "text": {"type": "plain_text", "text": "Reject", "emoji": True},
                    "style": "danger",
                    "value": str(change_id),
                    "action_id": "reject_change",
                    "confirm": {
                        "title": {"type": "plain_text", "text": "Reject this change?"},
                        "text": {
                            "type": "mrkdwn",
                            "text": f"Permanently reject pending change #{change_id}?",
                        },
                        "confirm": {"type": "plain_text", "text": "Yes, reject"},
                        "deny": {"type": "plain_text", "text": "Cancel"},
                    },
                },
            ],
        },
    ]

    try:
        CLIENT.chat_postMessage(
            channel="#pennyme_approvals",
            text=plain_text,
            username="PennyMe",
            blocks=blocks,
        )
    except SlackApiError as e:
        logger.error(f"Error sending pending change message to Slack: {e}")
        raise e
