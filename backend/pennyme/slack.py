import json
import os
import re
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from threading import Thread
from typing import Any, Dict, Iterator, Optional, Tuple

import cv2
import numpy as np
from loguru import logger
from PIL import Image, ImageOps
from rembg import new_session, remove
from slack_bolt import Ack, App, Respond
from slack_bolt.adapter.socket_mode import SocketModeHandler
from slack_sdk.errors import SlackApiError
from slack_sdk.web.slack_response import SlackResponse

from pennyme.database import (
    approve_pending_change,
    find_machine_in_database,
    get_machine_display_names,
    reject_pending_change,
)
from pennyme.utils import ALL_LOCATIONS, PATH_IMAGES

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

PENDING_SLACK_STATE = (
    Path(__file__).resolve().parents[2] / "slack_pending_reviews.sqlite3"
)


@contextmanager
def pending_slack_state(change_id: int) -> Iterator[Dict[str, Any]]:
    """Lock and persist Slack delivery progress for one pending machine change.

    Args:
        change_id: ID of the pending_changes row.

    Yields:
        Message references, uploaded image blocks, and completed review steps.
        Progress is saved even when a later step fails, so retries after a
        backend restart can resume cleanup without repeating completed steps.

    Raises:
        sqlite3.Error: If the private runtime database cannot be read or written.
    """
    connection = sqlite3.connect(PENDING_SLACK_STATE, timeout=60)
    try:
        connection.execute(
            "CREATE TABLE IF NOT EXISTS reviews (change_id INTEGER PRIMARY KEY, state TEXT NOT NULL)"
        )
        connection.execute("BEGIN IMMEDIATE")
        row = connection.execute(
            "SELECT state FROM reviews WHERE change_id = ?", (change_id,)
        ).fetchone()
        state: Dict[str, Any] = json.loads(row[0]) if row else {}
        try:
            yield state
        finally:
            connection.execute(
                "INSERT OR REPLACE INTO reviews VALUES (?, ?)",
                (change_id, json.dumps(state)),
            )
            connection.commit()
    finally:
        connection.close()


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

    Pending images are uploaded to Slack so their review archive survives
    server-side renaming or deletion. Their message references are persisted
    in the private runtime database. This upload requires ``files:write``.

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
        SlackApiError: If Slack rejects the upload or message.
        OSError: If a pending image cannot be read.
        sqlite3.Error: If pending message progress cannot be persisted.
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
    if pending:
        filename = f"{fname_base}{fname_suffix}.{filetype}"
        with pending_slack_state(machine_id) as state:
            images = state.setdefault("images", {})
            if filename not in images:
                upload = CLIENT.files_upload_v2(file=str(Path(PATH_IMAGES) / filename))
                images[filename] = {
                    "block": {
                        "type": "image",
                        "slack_file": {"id": upload["files"][0]["id"]},
                        "alt_text": text,
                    }
                }
            image_message = images[filename]
            if "ts" not in image_message:
                response = message_slack_raw(
                    text, channel=channel, blocks=[image_message["block"]]
                )
                image_message.update(channel=response["channel"], ts=response["ts"])
            state["awaiting_image"] = False
        return
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


def message_slack_raw(
    text: str, channel: str = "#pennyme_uploads", **kwargs: Any
) -> SlackResponse:
    """Send a message to Slack and return the API response.

    Args:
        text: Plain-text fallback text for the Slack message.
        channel: Slack channel name, ID, or private-channel identifier.
        **kwargs: Additional arguments accepted by ``chat_postMessage``, such
            as blocks or a thread timestamp.

    Returns:
        The response mapping returned by Slack's ``chat.postMessage`` API.

    Raises:
        SlackApiError: If Slack rejects the message.
    """
    return CLIENT.chat_postMessage(
        channel=channel, text=text, username="PennyMe", **kwargs
    )


def message_slack_report(
    text: str, machine_id: str, target_kind: str, target_id: str, images_path: str
) -> None:
    """Post a UGC report and its relevant content to the approvals channel.

    The initial message contains the report alert, including its ``@channel``
    mention, the reported content, and Approve/Reject buttons. Content beyond
    Slack's 50-block message limit is posted in the thread immediately. On
    review, the visible content is archived in that thread before the root
    message is replaced with the decision.

    Args:
        text: Report alert text to use for the thread's root message.
        machine_id: ID of the machine containing the reported content.
        target_kind: One of ``comment``, ``image``, or ``machine``.
        target_id: Client-provided identifier for the reported content.
        images_path: Root directory containing machine images and comments.

    Raises:
        SlackApiError: If any Slack message cannot be delivered.
        ValueError: If ``machine_id`` is not an integer.
    """
    machine_id = str(int(machine_id))
    root = Path(images_path)
    content_blocks: list[Dict[str, Any]] = []
    content: Dict[str, Any] = {}
    if target_kind == "machine":
        content["listing"] = find_machine_in_database(int(machine_id))
    if target_kind in {"machine", "comment"}:
        path = root / "comments" / f"{machine_id}.json"
        comments = json.loads(path.read_text()) if path.exists() else {}
        content["comments"] = (
            comments
            if target_kind == "machine" or target_id == "all"
            else {target_id: comments.get(target_id, "Comment unavailable")}
        )
    if content:
        serialized = json.dumps(content, ensure_ascii=False, indent=2)
        for offset in range(0, len(serialized), 3000):
            chunk = serialized[offset : offset + 3000]
            content_blocks.append(
                {"type": "section", "text": {"type": "plain_text", "text": chunk}}
            )
    if target_kind in {"machine", "image"}:
        for path in sorted(root.glob(f"{machine_id}*")):
            if not re.fullmatch(
                rf"{machine_id}(_coin_\d+)?\.(jpg|jpeg|png)", path.name
            ):
                continue
            image_id = path.stem.removeprefix(machine_id).lstrip("_") or "machine"
            if target_kind == "image" and target_id != image_id:
                continue
            content_blocks.append(
                {
                    "type": "image",
                    "image_url": f"{IMG_PORT}{path.name}",
                    "alt_text": path.name,
                }
            )

    buttons: list[Dict[str, Any]] = []
    for label, style in (("Approve", "primary"), ("Reject", "danger")):
        buttons.append(
            {
                "type": "button",
                "text": {"type": "plain_text", "text": label, "emoji": True},
                "style": style,
                "action_id": f"{label.lower()}_report",
                "value": machine_id,
            }
        )
    blocks = [
        {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        *content_blocks[:48],
        {"type": "actions", "elements": buttons},
    ]
    response = message_slack_raw(text, channel="#pennyme_approvals", blocks=blocks)
    for offset in range(48, len(content_blocks), 50):
        message_slack_raw(
            "Additional reported content",
            channel="#pennyme_approvals",
            thread_ts=response["ts"],
            blocks=content_blocks[offset : offset + 50],
        )


# ---------------------------------------------------------------------------
# Slack Socket Mode — interactive button handlers
# ---------------------------------------------------------------------------


@SLACK_APP.action("approve_report")
@SLACK_APP.action("reject_report")
def handle_report_review(ack: Ack, body: Dict[str, Any], respond: Respond) -> None:
    """Archive a UGC report in its thread and record the Slack review decision.

    Args:
        ack: Callback acknowledging the button click immediately.
        body: Slack action payload containing the original message and reviewer.
        respond: Callback replacing the root message or reporting a retryable error.

    The archive retains the submitted text and image blocks without buttons or
    a second channel mention. It must be delivered before the root is cleared.
    These decisions affect the Slack report only; they do not delete app content.
    """
    ack()
    message = body["message"]
    action = body["actions"][0]
    approved = action["action_id"] == "approve_report"
    decision = "approved" if approved else "rejected"
    icon = ":white_check_mark:" if approved else ":x:"
    reviewer_id = body["user"]["id"]
    archive_blocks: list[Dict[str, Any]] = [
        {
            "type": "section",
            "text": {
                "type": "plain_text",
                "text": message["text"].replace("<!channel>", "@channel"),
            },
        },
        *[block for block in message["blocks"][1:] if block["type"] != "actions"],
    ]
    try:
        message_slack_raw(
            "Original UGC report",
            channel=body["channel"]["id"],
            thread_ts=message["ts"],
            blocks=archive_blocks,
        )
    except SlackApiError:
        logger.exception("Could not archive UGC report before review")
        respond(
            text="Could not archive the report. Please try again.",
            response_type="ephemeral",
            replace_original=False,
        )
        return

    respond(
        replace_original=True,
        text=(
            f"{icon} UGC report for machine {action['value']} *{decision}* "
            f"by <@{reviewer_id}>. Details preserved in this thread."
        ),
        blocks=[],
    )


def recover_pending_images(
    change_id: int, body: Dict[str, Any], state: Dict[str, Any]
) -> None:
    """Recover image references for submissions posted before durable tracking.

    Args:
        change_id: Pending change whose images need recovery.
        body: Original Slack message and channel from the review action.
        state: Durable review progress to populate with recovered image references.

    Channel history is paginated from the proposal timestamp. Only this bot's
    image messages with exact pending-image URLs are selected. This migration
    requires channel-history read access; failures leave the proposal intact.
    """
    message = body["message"]
    images = state.setdefault("images", {})
    cursor = None
    while True:
        history = CLIENT.conversations_history(
            channel=body["channel"]["id"],
            oldest=message["ts"],
            inclusive=True,
            limit=100,
            cursor=cursor,
        )
        for candidate in history["messages"]:
            if (
                not message.get("bot_id")
                or candidate.get("bot_id") != message["bot_id"]
            ):
                continue
            for block in candidate.get("blocks", []):
                url = block.get("image_url", "")
                filename = url.removeprefix(IMG_PORT)
                if not url.startswith(IMG_PORT) or not re.fullmatch(
                    rf"pending_{change_id}(_coin_\d+)?\.(jpg|jpeg|png)", filename
                ):
                    continue
                if candidate["ts"] not in images:
                    upload = CLIENT.files_upload_v2(
                        file=str(Path(PATH_IMAGES) / filename)
                    )
                    images[candidate["ts"]] = {
                        "channel": body["channel"]["id"],
                        "ts": candidate["ts"],
                        "block": {
                            "type": "image",
                            "slack_file": {"id": upload["files"][0]["id"]},
                            "alt_text": block.get("alt_text", filename),
                        },
                    }
        cursor = history.get("response_metadata", {}).get("next_cursor")
        if not cursor:
            break
    state["awaiting_image"] = False


@SLACK_APP.action("approve_change")
@SLACK_APP.action("reject_change")
def handle_pending_change_review(
    ack: Ack, body: Dict[str, Any], respond: Respond
) -> None:
    """Archive a machine submission, apply the decision, and clean up Slack.

    Args:
        ack: Callback acknowledging the button click immediately.
        body: Slack action payload containing the submission and reviewer.
        respond: Callback reporting a retryable error without replacing the submission.

    Details and Slack-hosted images are copied into the original message's
    thread before approval can rename, or rejection can delete, server images.
    Stored progress survives restarts and serializes competing button clicks.
    The root message and buttons stay available if any step fails; a retry
    resumes the saved decision and unfinished cleanup.
    """
    ack()
    change_id = int(body["actions"][0]["value"])
    approved = body["actions"][0]["action_id"] == "approve_change"
    message = body["message"]
    channel = body["channel"]["id"]
    try:
        with pending_slack_state(change_id) as state:
            if (
                "awaiting_image" not in state
                and "New machine proposed" in message["text"]
            ):
                recover_pending_images(change_id, body, state)
            if state.get("awaiting_image"):
                respond(
                    text="The submission image is still being processed. Please retry shortly.",
                    response_type="ephemeral",
                    replace_original=False,
                )
                return
            if not state.get("details_archived"):
                blocks = [
                    block
                    for block in message.get("blocks", [])
                    if block["type"] != "actions"
                ]
                message_slack_raw(
                    message["text"],
                    channel=channel,
                    thread_ts=message["ts"],
                    blocks=blocks,
                )
                state["details_archived"] = True
            for image_message in state.get("images", {}).values():
                if not image_message.get("archived"):
                    message_slack_raw(
                        "Submitted image",
                        channel=channel,
                        thread_ts=message["ts"],
                        blocks=[image_message["block"]],
                    )
                    image_message["archived"] = True

            if "result_text" not in state:
                review = approve_pending_change if approved else reject_pending_change
                result = review(change_id)
                if result.applied:
                    decision = "approved" if approved else "rejected"
                    icon = ":white_check_mark:" if approved else ":x:"
                    reviewer_id = body["user"]["id"]
                    result_text = f"{icon} Pending change #{change_id} *{decision}* by <@{reviewer_id}>."
                    if approved:
                        result_text += f" Machine ID {result.machine_id}."
                else:
                    result_text = f":information_source: Pending change #{change_id} was already handled (status: {result.status})."
                state["result_text"] = (
                    result_text + " Details preserved in this thread."
                )

            for image_message in state.get("images", {}).values():
                if "ts" in image_message and not image_message.get("deleted"):
                    try:
                        CLIENT.chat_delete(
                            channel=image_message["channel"], ts=image_message["ts"]
                        )
                    except SlackApiError as error:
                        if error.response["error"] != "message_not_found":
                            raise
                    image_message["deleted"] = True
            CLIENT.chat_update(
                channel=channel, ts=message["ts"], text=state["result_text"], blocks=[]
            )
    except Exception:
        logger.exception(
            f"Could not finish Slack review for pending change #{change_id}"
        )
        respond(
            text="Review or Slack cleanup could not finish. Please retry; completed steps are preserved.",
            response_type="ephemeral",
            replace_original=False,
        )


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

    with pending_slack_state(change_id) as state:
        state.setdefault("awaiting_image", change_type == "create")
        message_slack_raw(plain_text, channel="#pennyme_approvals", blocks=blocks)
