import json
import os
import re
from filecmp import cmp
from shutil import copy2
from pathlib import Path
from threading import Thread
from typing import Any, Dict, List, Literal, Optional, Tuple

import cv2
import numpy as np
from loguru import logger
from PIL import Image, ImageOps
from rembg import new_session, remove
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from slack_sdk.errors import SlackApiError

from pennyme.database import (
    NearbyMachine,
    archive_and_delete_machine,
    approve_pending_change,
    find_machine_in_database,
    get_machine_display_names,
    reject_pending_change,
)
from pennyme.moderation import MachineContentBackup, ModerationStore
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

# Maps pending_changes.id to its Slack image messages, so submitted and nearby
# machine photos can be deleted once the change is approved/rejected. In-memory only:
# lost on restart, in which case deletion is silently skipped.
_PENDING_IMAGE_MESSAGES: Dict[int, List[Tuple[str, str]]] = {}
_MODERATION = ModerationStore(
    Path(os.path.join("..", "content_attribution.json")),
    Path(os.path.join("..", "moderation_reports.jsonl")),
)


def _approval_actions(
    value: str,
    block_id: str,
    approve_action: str,
    reject_action: str,
    subject: str,
) -> Dict[str, Any]:
    """Build the shared Approve/Reject controls used in Slack."""
    return {
        "type": "actions",
        "block_id": block_id,
        "elements": [
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "Approve", "emoji": True},
                "style": "primary",
                "value": value,
                "action_id": approve_action,
            },
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "Reject", "emoji": True},
                "style": "danger",
                "value": value,
                "action_id": reject_action,
                "confirm": {
                    "title": {"type": "plain_text", "text": "Reject this change?"},
                    "text": {
                        "type": "mrkdwn",
                        "text": f"Permanently reject {subject}?",
                    },
                    "confirm": {"type": "plain_text", "text": "Yes, reject"},
                    "deny": {"type": "plain_text", "text": "Cancel"},
                },
            },
        ],
    }


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


def slack_markdown_sections(text: str, max_length: int = 3000) -> List[Dict[str, Any]]:
    """Split text into valid Slack Markdown section blocks.

    Args:
        text: Markdown text to split.
        max_length: Maximum characters in each section. Slack permits at most
            3,000 characters in a section text object.

    Returns:
        Slack Block Kit section dictionaries. Line boundaries are preferred
        when a split is required.
    """
    sections: List[Dict[str, Any]] = []
    while text:
        split_at = min(len(text), max_length)
        if split_at < len(text):
            newline = text.rfind("\n", 0, split_at + 1)
            if newline > 0:
                split_at = newline
        chunk = text[:split_at]
        sections.append({"type": "section", "text": {"type": "mrkdwn", "text": chunk}})
        text = text[split_at:].lstrip("\n")
    return sections


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
            _PENDING_IMAGE_MESSAGES.setdefault(int(machine_id), []).append(
                (str(response["channel"]), str(response["ts"]))
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
) -> Dict[str, Any]:
    """Send a message to Slack and return the API response.

    Args:
        text: Plain-text fallback text for the Slack message.
        channel: Slack channel name, ID, or private-channel identifier.
        **kwargs: Additional arguments accepted by ``chat_postMessage``, such
            as blocks or a thread timestamp.

    Returns:
        The response mapping returned by Slack's ``chat.postMessage`` API.

    Raises:
        SlackApiError: If Slack rejects the message or cannot be reached.
    """
    return CLIENT.chat_postMessage(
        channel=channel, text=text, username="PennyMe", **kwargs
    )


def message_slack_report(
    text: str,
    report_id: str,
    comment: str,
    machine_id: str,
    target_kind: str,
    target_id: str,
    images_path: str,
) -> None:
    """Post a UGC report and its relevant content to the approvals channel.

    The initial message contains the report alert, its ``@channel`` mention,
    and approval controls. The explanation and reported content are posted in
    the thread so they remain available after a decision replaces the root
    message.

    Args:
        text: Report alert text to use for the thread's root message.
        report_id: Unique identifier stored in the approval button values.
        comment: The reporter's explanation.
        machine_id: ID of the machine containing the reported content.
        target_kind: One of ``comment``, ``image``, or ``machine``.
        target_id: Client-provided identifier for the reported content.
        images_path: Root directory containing machine images and comments.

    Raises:
        SlackApiError: If any Slack message cannot be delivered.
        ValueError: If ``machine_id`` is not an integer.
    """
    blocks: List[Dict[str, Any]] = [
        {"type": "section", "text": {"type": "mrkdwn", "text": text}}
    ]
    blocks.append(
        _approval_actions(
            report_id,
            f"report_{report_id}",
            "approve_report",
            "reject_report",
            f"report {report_id}",
        )
    )
    response = message_slack_raw(text, channel="#pennyme_approvals", blocks=blocks)
    thread_channel = str(response.get("channel", "#pennyme_approvals"))
    thread_timestamp = str(response["ts"])
    thread_arguments: Dict[str, str] = {
        "channel": thread_channel,
        "thread_ts": thread_timestamp,
    }
    machine_id = str(int(machine_id))
    root = Path(images_path)
    report_details = (
        f"{text.removeprefix('<!channel> ')}\nReporter explanation: {comment}"
    )
    message_slack_raw(
        report_details,
        **thread_arguments,
        blocks=[
            {
                "type": "section",
                "text": {
                    "type": "plain_text",
                    "text": report_details,
                },
            }
        ],
    )
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
            message_slack_raw(
                chunk,
                **thread_arguments,
                blocks=[
                    {"type": "section", "text": {"type": "plain_text", "text": chunk}}
                ],
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
            if target_kind in {"image", "machine"}:
                # Keep the review image available after the original is moved.
                snapshot = root / "reported" / f"{report_id}_{path.name}"
                snapshot.parent.mkdir(exist_ok=True)
                if snapshot.exists():
                    if not cmp(path, snapshot, shallow=False):
                        raise FileExistsError(snapshot)
                else:
                    copy2(path, snapshot)
                image_url = f"{IMG_PORT}reported/{snapshot.name}"
            else:
                image_url = f"{IMG_PORT}{path.name}"
            message_slack_raw(
                path.name,
                **thread_arguments,
                blocks=[
                    {
                        "type": "image",
                        "alt_text": path.name,
                        "image_url": image_url,
                    }
                ],
            )


# ---------------------------------------------------------------------------
# Slack Socket Mode — interactive button handlers
# ---------------------------------------------------------------------------


def delete_pending_image_messages(change_id: int) -> None:
    """Delete submitted and nearby-image messages for a pending change.

    Args:
        change_id: Pending-change ID used to track temporary Slack messages.
    """
    for channel, timestamp in _PENDING_IMAGE_MESSAGES.pop(change_id, []):
        try:
            CLIENT.chat_delete(channel=channel, ts=timestamp)
        except SlackApiError as error:
            logger.error(
                f"Error deleting image message for pending #{change_id}: {error}"
            )


def _reported_content_path(
    report: Dict[str, Any], images_path: Optional[str] = None
) -> Path:
    """Resolve the server file represented by an actionable UGC report.

    Args:
        report: Stored report fields from :class:`ModerationStore`.
        images_path: Root directory containing images and comment JSON files.

    Returns:
        The exact image or comment file to move when the report is approved.

    Raises:
        ValueError: If the stored report does not identify actionable content.
    """
    machine_id = str(int(report["machine_id"]))
    target_kind = report.get("target_kind")
    target_id = report.get("target_id")
    root = Path(images_path or PATH_IMAGES)
    if target_kind == "comment" and target_id == "all":
        return root / "comments" / f"{machine_id}.json"
    if target_kind == "image" and target_id == "machine":
        return root / f"{machine_id}.jpg"
    if target_kind == "image" and re.fullmatch(r"coin_\d+", str(target_id)):
        return root / f"{machine_id}_{target_id}.png"
    raise ValueError("Report does not identify an image or comment file")


def _quarantine_report_content(
    report: Dict[str, Any], images_path: Optional[str] = None
) -> Path:
    """Move approved UGC into the flat ``images/reported`` directory.

    Args:
        report: Stored report fields from :class:`ModerationStore`.
        images_path: Root directory containing images and comment JSON files.

    Returns:
        Destination path of the moved content.

    Raises:
        FileNotFoundError: If neither the live nor reported file exists.
        FileExistsError: If both paths exist and choosing one would lose data.
        ValueError: If the report does not identify actionable content.
    """
    root = images_path or PATH_IMAGES
    source = _reported_content_path(report, root)
    destination = Path(root) / "reported" / source.name
    if not source.exists():
        if destination.exists():
            return destination
        raise FileNotFoundError(source)
    if destination.exists():
        raise FileExistsError(destination)
    destination.parent.mkdir(exist_ok=True)
    return source.rename(destination)


def handle_report_review(
    body: Dict[str, Any],
    respond: Any,
    decision: Literal["approved", "rejected"],
) -> None:
    """Apply one Slack UGC-report decision and update its root message.

    Approval of a machine report first stages filesystem backups, then archives
    and deletes the SQL row transactionally, and finally removes the live files.
    Rejection records the review without modifying machine data or files.

    Args:
        body: Slack action payload containing the report and reviewer IDs.
        respond: Slack Bolt response callback for replacing the action message.
        decision: Either ``approved`` or ``rejected``.
    """
    report_id = str(body["actions"][0]["value"])
    action = "approve" if decision == "approved" else "reject"
    reviewer = body.get("user", {})
    reviewer_id = str(reviewer.get("id") or reviewer.get("name") or "unknown")
    reviewer_name = str(reviewer.get("name") or reviewer_id)
    try:
        report, existing_decision = _MODERATION.report_status(report_id)
        if report is None:
            raise ValueError(f"Unknown report {report_id}")
        if existing_decision:
            result_text = (
                f":information_source: UGC report {report_id} was already "
                f"{existing_decision}. Details remain in this thread."
            )
        else:
            target_kind = report.get("target_kind")
            if target_kind not in {"comment", "image", "machine"}:
                raise ValueError(f"Unknown report target: {target_kind}")
            if decision == "approved":
                if target_kind == "machine":
                    backup = MachineContentBackup.stage(
                        int(report["machine_id"]),
                        str(report["report_id"]),
                        Path(PATH_IMAGES),
                    )
                    try:
                        archive_and_delete_machine(
                            int(report["machine_id"]), reviewer_id, report_id
                        )
                    except Exception:
                        backup.discard()
                        raise
                    backup.finish_move()
                else:
                    _quarantine_report_content(report)
            _MODERATION.record_review(report_id, decision, reviewer_id)
            icon = ":white_check_mark:" if decision == "approved" else ":x:"
            result_text = (
                f"{icon} UGC report {report_id} *{decision}* by {reviewer_name}. "
                "Details remain in this thread."
            )
    except Exception as error:
        logger.exception(f"Could not {action} report {report_id}")
        respond(
            replace_original=False,
            response_type="ephemeral",
            text=f":warning: Could not {action} report: {error}",
        )
        return
    respond(replace_original=True, text=result_text, blocks=[])


@SLACK_APP.action("approve_report")
def handle_approve_report(ack: Any, body: Dict[str, Any], respond: Any) -> None:
    """Move reported content aside and record approval from Slack.

    Args:
        ack: Slack Bolt callback that acknowledges the button action.
        body: Slack action payload containing report and reviewer IDs.
        respond: Slack Bolt callback used to replace the action message.
    """
    ack()
    handle_report_review(body, respond, "approved")


@SLACK_APP.action("reject_report")
def handle_reject_report(ack: Any, body: Dict[str, Any], respond: Any) -> None:
    """Leave reported content in place and record rejection from Slack.

    Args:
        ack: Slack Bolt callback that acknowledges the button action.
        body: Slack action payload containing report and reviewer IDs.
        respond: Slack Bolt callback used to replace the action message.
    """
    ack()
    handle_report_review(body, respond, "rejected")


@SLACK_APP.action("approve_change")
def handle_approve_change(ack: Any, body: Dict[str, Any], respond: Any) -> None:
    """Approve a pending change when its Slack button is clicked.

    Args:
        ack: Slack Bolt callback that acknowledges the button action.
        body: Slack action payload containing change and reviewer IDs.
        respond: Slack Bolt callback used to replace the action message.
    """
    ack()
    change_id = int(body["actions"][0]["value"])
    user_name = body.get("user", {}).get("name", "unknown")
    try:
        result = approve_pending_change(change_id)
        if (
            result.status == "approved"
            and result.change_type == "create"
            and result.machine_id is not None
        ):
            _MODERATION.reassign_machine_content(str(change_id), str(result.machine_id))
    except (KeyError, OSError, TypeError, ValueError) as e:
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
    delete_pending_image_messages(change_id)
    respond(replace_original=True, text=result_text)


@SLACK_APP.action("reject_change")
def handle_reject_change(ack: Any, body: Dict[str, Any], respond: Any) -> None:
    """Reject a pending change when its Slack button is clicked.

    Args:
        ack: Slack Bolt callback that acknowledges the button action.
        body: Slack action payload containing change and reviewer IDs.
        respond: Slack Bolt callback used to replace the action message.
    """
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
    delete_pending_image_messages(change_id)
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
    old_latitude: Optional[float] = None,
    old_longitude: Optional[float] = None,
    movement_distance_m: Optional[float] = None,
    nearby_radius_m: Optional[float] = None,
    nearby_machines: Optional[List[NearbyMachine]] = None,
) -> None:
    """Post a pending change notification to Slack with Approve/Reject buttons.

    Args:
        change_id: The ID of the pending_changes row.
        change_type: ``'create'`` or ``'update'``.
        title: Machine name.
        area: Machine area/country.
        change_summary: Human-readable description of what changed.
        machine_id: Existing machine ID for updates, None for new machines. Its
            current machine photo is included when nearby machines are checked.
        latitude: Machine latitude, to render a Google Maps link. Defaults to None.
        longitude: Machine longitude, to render a Google Maps link. Defaults to None.
        old_latitude: Previous latitude for a moved machine.
        old_longitude: Previous longitude for a moved machine.
        movement_distance_m: Geodesic distance from the old to new location.
        nearby_radius_m: Radius used to find neighbors for a moved machine.
        nearby_machines: Neighbor summaries ordered by geodesic distance. Their
            PennyCollector links and machine photos are included in Slack.

    Raises:
        SlackApiError: If the Slack API call fails.
    """
    if change_type == "create":
        header = f":new: *New machine proposed (pending #{change_id})*"
    else:
        header = (
            f":pencil2: *Machine {machine_id} change proposed (pending #{change_id})*"
        )

    summary_lines = [change_summary.strip() or "(no summary)"]
    if (
        latitude is not None
        and longitude is not None
        and old_latitude is not None
        and old_longitude is not None
    ):
        maps_url = (
            "https://www.google.com/maps/dir/?api=1"
            f"&origin={old_latitude},{old_longitude}"
            f"&destination={latitude},{longitude}"
        )
        summary_lines.append(f"<{maps_url}|View old → new location on Google Maps>")
    elif latitude is not None and longitude is not None:
        maps_url = f"https://www.google.com/maps?q={latitude},{longitude}"
        summary_lines.append(f"<{maps_url}|View on Google Maps>")

    nearby_lines = []
    for nearby_machine in nearby_machines or []:
        nearby_line = (
            f"• ID {nearby_machine['id']} — {nearby_machine['name']} — "
            f"{nearby_machine['distance_m']} m"
        )
        external_url = nearby_machine.get("external_url")
        if external_url and "pennycollector.com" in external_url.casefold():
            nearby_line += f" — <{external_url}|PennyCollector>"
        nearby_lines.append(nearby_line)

    if change_type == "create" and nearby_machines is not None:
        summary_lines.append("*Three nearest machines:*")
        summary_lines.extend(nearby_lines)
    elif nearby_radius_m is not None:
        moved = round(movement_distance_m or 0)
        radius = round(nearby_radius_m)
        summary_lines.append(f"Moved {moved} m; searched within {radius} m.")
        if nearby_machines:
            nearest = nearby_machines[0]
            if movement_distance_m is not None and (
                movement_distance_m > nearest["distance_m"]
            ):
                summary_lines.append(
                    ":warning: Moved farther than the nearest neighbor "
                    f"(ID {nearest['id']} at {nearest['distance_m']} m)."
                )
            summary_lines.append(f"*Nearby machines ({len(nearby_machines)}):*")
            summary_lines.extend(nearby_lines)
        else:
            summary_lines.append(f"No other machines within {radius} m.")

    message_text = f"{header}\n*{title}* ({area})\n" + "\n".join(summary_lines)

    blocks = slack_markdown_sections(message_text) + [
        _approval_actions(
            str(change_id),
            f"pending_{change_id}",
            "approve_change",
            "reject_change",
            f"pending change #{change_id}",
        )
    ]
    response = message_slack_raw(
        message_text, channel="#pennyme_approvals", blocks=blocks
    )

    image_machines = []
    if machine_id is not None and nearby_machines is not None:
        image_machines.append((str(machine_id), title, "Source machine"))
    image_machines.extend(
        (str(nearby_machine["id"]), nearby_machine["name"], "Nearby machine")
        for nearby_machine in nearby_machines or []
    )

    for image_machine_id, image_machine_name, image_label in image_machines:
        image_paths = [
            path
            for path in sorted(Path(PATH_IMAGES).glob(f"{image_machine_id}*"))
            if re.fullmatch(
                rf"{re.escape(image_machine_id)}\.(jpg|jpeg|png)", path.name
            )
        ]
        if not image_paths:
            continue
        image_title = f"{image_label} {image_machine_id} — {image_machine_name}"
        image_response = message_slack_raw(
            image_title,
            channel=str(response.get("channel", "#pennyme_approvals")),
            thread_ts=str(response["ts"]),
            blocks=[
                {
                    "type": "image",
                    "title": {"type": "plain_text", "text": image_title},
                    "image_url": f"{IMG_PORT}{path.name}",
                    "alt_text": f"{image_title}: {path.name}",
                }
                for path in image_paths
            ],
        )
        _PENDING_IMAGE_MESSAGES.setdefault(change_id, []).append(
            (str(image_response["channel"]), str(image_response["ts"]))
        )


def message_slack_location_differ_summary(
    created: List[Tuple[int, str, str, str]],
    updated: List[Tuple[int, str, str, str]],
    merged_into_pending: List[Tuple[int, str, str, str]],
) -> None:
    """Post a summary of a location_differ run to Slack, with details threaded.

    Unlike `message_slack_pending_change`, location_differ changes are
    already applied directly (no Approve/Reject buttons needed), so this
    posts one top-level message with the run stats, then every
    change_summary as a threaded reply instead of flooding the channel.

    Args:
        created: (machine_id, name, area, change_summary) for each newly
            inserted machine.
        updated: (machine_id, name, area, change_summary) for each machine
            updated directly.
        merged_into_pending: (machine_id, name, area, change_summary) for
            each machine whose sync was merged into an already-open pending
            change instead of being applied directly (see
            `upsert_machines_from_file`).

    Raises:
        SlackApiError: If the Slack API call fails.
    """
    if not (created or updated or merged_into_pending):
        message_slack_raw(":robot_face: location_differ run complete: no changes found")
        return

    stats = (
        f"{len(created)} new machine{'s' if len(created) != 1 else ''}, "
        f"{len(updated)} changed machine{'s' if len(updated) != 1 else ''}"
    )
    if merged_into_pending:
        stats += f", {len(merged_into_pending)} merged into an existing pending review"

    try:
        response = CLIENT.chat_postMessage(
            channel="#pennyme_approvals",
            text=f":robot_face: location_differ run complete: {stats}",
            username="PennyMe",
        )
    except SlackApiError as e:
        logger.error(f"Error sending location_differ summary to Slack: {e}")
        raise e

    lines = [
        f"machine {machine_id} ({name}, {area}): {summary}"
        for machine_id, name, area, summary in created
    ]
    lines += [
        f"machine {machine_id} ({name}, {area}): {summary}"
        for machine_id, name, area, summary in updated
    ]
    lines += [
        f"machine {machine_id} ({name}, {area}): awaiting review (merged into open pending change) - {summary}"
        for machine_id, name, area, summary in merged_into_pending
    ]

    try:
        CLIENT.chat_postMessage(
            channel="#pennyme_approvals",
            text="\n".join(lines),
            username="PennyMe",
            thread_ts=response["ts"],
        )
    except SlackApiError as e:
        logger.error(f"Error sending location_differ detail thread to Slack: {e}")
        raise e
