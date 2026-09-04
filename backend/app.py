import autoroot  # noqa: F401  # initializes repo root
import json
import os
import queue
import traceback
from datetime import datetime
from pathlib import Path
from threading import Thread
from time import sleep
from typing import Any, Dict, Optional, Tuple

from flask import Flask, Response, jsonify, request
from googlemaps import Client as GoogleMaps
from haversine import haversine, Unit
from loguru import logger
from thefuzz import process as fuzzysearch

from scripts.location_differ import location_differ

from pennyme.database import (
    dump_machines_to_file,
    find_machine_in_database,
    get_all_machines_geojson,
    get_nearby_machines_db,
    has_open_pending_change,
    insert_pending_change_full,
    upsert_machines_from_file,
)
from pennyme.github_update import wait
from pennyme.locations import COUNTRIES
from pennyme.moderation import (
    ModerationReport,
    ModerationStore,
    parse_report_request,
    text_block_reason,
    validate_report,
)
from pennyme.slack import (
    format_machine_fields,
    image_slack,
    message_slack,
    message_slack_pending_change,
    message_slack_raw,
    process_uploaded_image,
    start_socket_mode_handler,
)
from pennyme.utils import (
    find_machine_name_conflict,
    get_nearby_machines,
    setup_locdiffer_logger,
)

app = Flask(__name__)
request_queue = queue.Queue()


PATH_COMMENTS = os.path.join("..", "..", "images", "comments")
PATH_IMAGES = os.path.join("..", "..", "images")
PATH_MACHINES = os.path.join("..", "data", "all_locations.json")
# Below this, treat coordinates as unchanged — avoids false positives from
# float round-tripping through the DB rather than an actual edit.
LOCATION_CHANGE_THRESHOLD_M = 1
MODERATION = ModerationStore(
    Path(os.path.join("..", "content_attribution.json")),
    Path(os.path.join("..", "moderation_reports.jsonl")),
)
GM_CLIENT = GoogleMaps(open("../../gpc_api_key.keypair", "r").read())

with open("blocked_contributors.json", "r") as infile:
    # Digests copied from confirmed moderation reports; reload requires restart.
    blocked_contributors = json.load(infile)


def anonymous_user_id() -> str:
    """Read the account-free installation identifier from the request.

    Returns:
        The trimmed installation identifier, or an empty string when the client
        did not send the ``X-PennyMe-Anonymous-ID`` header.
    """
    return request.headers.get("X-PennyMe-Anonymous-ID", "").strip()


def blocked_contributor_response() -> Optional[Tuple[Response, int]]:
    """Check whether the current request is denied from contributing.

    Returns:
        A JSON response and HTTP 403 status when the installation is blocked,
        or ``None`` when posting may continue.
    """
    contributor_id = MODERATION.contributor_id(anonymous_user_id())
    if contributor_id is not None and contributor_id in blocked_contributors:
        return jsonify({"error": "Posting access from this device is blocked"}), 403
    return None


def _diff_field(
    changed_fields: Dict[str, Any], msg: str, label: str, field: str, old: Any, new: Any
) -> str:
    """Record `field` in `changed_fields` and append a summary line if it changed.

    Template for adding a new simple (non-validated) machine attribute to
    `change_machine` — see Cases 5/6 below.
    """
    if new != old:
        changed_fields[field] = new
        msg += f"\t{label} from: {old} to: {new}\n"
    return msg


@app.route("/machines", methods=["GET"])
def machines() -> Tuple[Response, int]:
    """Return all approved server machines as a GeoJSON FeatureCollection.

    Returns:
        A GeoJSON FeatureCollection with HTTP 200.
    """
    return jsonify(get_all_machines_geojson()), 200


@app.route("/health", methods=["GET"])
def health() -> Tuple[Response, int]:
    """Return a lightweight service health response.

    Returns:
        A JSON response and HTTP 200 status.
    """
    return jsonify({"status": "ok"}), 200


@app.route("/add_comment", methods=["GET"])
def add_comment() -> Tuple[Response, int]:
    """Validate and publish a comment for one machine.

    The request supplies ``id`` and ``comment`` query parameters and may supply
    the account-free installation ID header used for private attribution.

    Returns:
        A JSON response paired with HTTP 200 on success, HTTP 403 for a blocked
        contributor, or HTTP 422 when the text filter rejects the comment.
    """

    comment = str(request.args.get("comment"))
    machine_id = str(request.args.get("id"))

    if blocked := blocked_contributor_response():
        return blocked

    reason = text_block_reason(comment)
    if reason:
        return jsonify({"error": reason}), 422

    path_machine_comments = os.path.join(PATH_COMMENTS, f"{machine_id}.json")
    if os.path.exists(path_machine_comments):
        with open(path_machine_comments, "r") as infile:
            # take previous comments and add paragaph
            all_comments = json.load(infile)
    else:
        all_comments = {}

    comment_timestamp = str(datetime.now())
    all_comments[comment_timestamp] = comment

    with open(path_machine_comments, "w") as outfile:
        json.dump(all_comments, outfile, indent=4)

    MODERATION.record_content(
        machine_id,
        MODERATION.content_key("comment", comment_timestamp),
        anonymous_user_id(),
    )

    # send message to slack
    message_slack(machine_id, comment)

    return jsonify({"message": "Success!"}), 200


@app.route("/upload_image", methods=["POST"])
def upload_image() -> Tuple[Response, int]:
    """Validate, process, and publish an uploaded machine or coin image.

    The multipart request supplies an ``image`` file, an ``id`` query parameter,
    and optionally ``coin_idx``. A ``coin_idx`` of ``-1`` identifies the machine
    image; non-negative values identify coin image slots.

    Returns:
        A JSON response paired with HTTP 200 on success, or an appropriate 4xx
        status when posting is blocked or the image cannot be accepted.
    """
    machine_id = str(request.args.get("id"))
    coin_idx_str = request.args.get("coin_idx", "-1")
    if blocked := blocked_contributor_response():
        return blocked
    if "image" not in request.files:
        return jsonify({"error": "No image file found"}), 400

    try:
        coin_idx = int(coin_idx_str)
    except Exception:
        return jsonify({"error": f"Unknown coin index {coin_idx_str}"}), 400

    if coin_idx == -1:
        fname_suffix = ""
        msg = "Machine image"
    else:
        # Fill frontend slots left to right
        for idx in range(100):
            if not os.path.exists(
                os.path.join(PATH_IMAGES, f"{machine_id}_coin_{idx}.png")
            ):
                if coin_idx > idx:
                    coin_idx = idx
                break
        fname_suffix = f"_coin_{coin_idx}"
        msg = f"Coin {coin_idx}, machine"

    img_path = os.path.join(PATH_IMAGES, f"{machine_id}{fname_suffix}.jpg")
    request.files["image"].save(img_path)
    code, msg_prefix, saved_path = process_uploaded_image(img_path)
    msg = f"{msg_prefix} - {msg}"

    if code != 200:
        image_slack(
            machine_id,
            fname_suffix=fname_suffix,
            img_slack_text=msg,
            filetype="jpg",
        )
        # Delete image since there was an error
        sleep(1)
        Path(saved_path).unlink()
        return jsonify({"error": msg}), code

    target_id = "machine" if coin_idx == -1 else f"coin_{coin_idx}"
    MODERATION.record_content(
        machine_id,
        MODERATION.content_key("image", target_id),
        anonymous_user_id(),
    )

    # send message to slack
    image_slack(machine_id, fname_suffix=fname_suffix, img_slack_text=msg)

    return jsonify({"message": "Image uploaded successfully"}), 200


@app.route("/moderation/manifest/<machine_id>", methods=["GET"])
def moderation_manifest(machine_id: str) -> Tuple[Response, int]:
    """Return contributor pseudonyms used for device-local content blocking.

    Args:
        machine_id: Machine whose reportable content should be described.

    Returns:
        A JSON mapping from content keys to viewer-scoped contributor IDs with
        HTTP 200, or an error with HTTP 400 when the installation ID is missing.
    """
    viewer_id = MODERATION.contributor_id(anonymous_user_id())
    if viewer_id is None:
        return jsonify({"error": "Missing anonymous installation identifier"}), 400
    return jsonify({"owners": MODERATION.manifest(machine_id, viewer_id)}), 200


@app.route("/moderation/listing_manifest", methods=["GET"])
def moderation_listing_manifest() -> Tuple[Response, int]:
    """Return contributor pseudonyms for attributed machine listings.

    Returns:
        A JSON mapping from machine IDs to viewer-scoped contributor IDs with
        HTTP 200, or an error with HTTP 400 when the installation ID is missing.
    """
    viewer_id = MODERATION.contributor_id(anonymous_user_id())
    if viewer_id is None:
        return jsonify({"error": "Missing anonymous installation identifier"}), 400
    return jsonify({"owners": MODERATION.listing_manifest(viewer_id)}), 200


@app.route("/report_content", methods=["POST"])
def report_content() -> Tuple[Response, int]:
    """Record a content report and notify maintainers in Slack.

    The JSON or form body must contain ``machine_id``, ``target_kind``,
    ``target_id``, and ``reason``. The optional ``block_contributor`` boolean
    records whether the reporter also hid that contributor on their device.

    Returns:
        A JSON response and HTTP 201 containing the viewer-scoped contributor
        ID and Slack delivery status. Invalid input returns HTTP 400. A Slack
        delivery failure does not discard the durable report or fail the call.
    """
    report_request = parse_report_request(
        request.get_json(silent=True) or request.form.to_dict()
    )
    machine_id = report_request["machine_id"]
    target_kind = report_request["target_kind"]
    target_id = report_request["target_id"]
    reason = report_request["reason"]
    block_contributor = report_request["block_contributor"]

    if not machine_id or not target_id:
        return jsonify({"error": "Missing report target"}), 400
    if error := validate_report(target_kind, reason):
        return jsonify({"error": error}), 400

    reporter_id = MODERATION.contributor_id(anonymous_user_id())
    if reporter_id is None:
        return jsonify({"error": "Missing anonymous installation identifier"}), 400

    content_key = MODERATION.content_key(target_kind, target_id)
    contributor = MODERATION.resolve_content(machine_id, content_key)
    report: ModerationReport = {
        "machine_id": machine_id,
        "content_key": content_key,
        "reason": reason,
        "block_contributor": bool(block_contributor),
        "contributor_id": contributor["contributor_id"],
        "reporter_id": reporter_id,
    }
    MODERATION.record_report(report)

    action = "REPORT + LOCAL BLOCK" if block_contributor else "REPORT"
    alert_text = (
        f"<!channel> UGC {action}: machine {machine_id}, {content_key}, "
        f"reason={reason}, "
        f"contributor={contributor['contributor_id']}, reporter={reporter_id}. "
        "Review and remove/eject within several working days."
    )
    slack_notified = False
    try:
        message_slack_raw(alert_text)
        slack_notified = True
    except Exception:
        # The durable report was already written; a temporary Slack outage must not
        # make the client believe that its local block failed.
        logger.exception("Could not send moderation report to Slack")

    return (
        jsonify(
            {
                "message": "Report received",
                "contributor_id": MODERATION.block_id(
                    contributor["contributor_id"], reporter_id
                ),
                "content_key": content_key,
                "slack_notified": slack_notified,
            }
        ),
        201,
    )


def process_pending_image(
    pending_id: int,
    tmp_img_path: str,
    installation_id: str,
) -> None:
    """Process the image upload for a new pending machine submission and record contributor.

    Runs in the background worker so slow image operations do not block
    the HTTP request.  The image is stored as ``pending_{pending_id}.jpg``
    so the approver can rename it to ``{machine_id}.jpg`` on approval.

    Args:
        pending_id: ID of the pending_changes row.
        tmp_img_path: Temporary path where the uploaded image was saved.
        installation_id: Random installation identifier supplied by the app.

    Returns:
        None. Processing errors are logged and sent to Slack.
    """
    try:
        img_path = os.path.join(PATH_IMAGES, f"pending_{pending_id}.jpg")
        os.rename(tmp_img_path, img_path)

        code, msg_prefix, saved_path = process_uploaded_image(img_path)
        msg = f"{msg_prefix} - New machine pending"

        if code != 200:
            image_slack(
                pending_id,
                img_slack_text=msg,
                filetype="jpg",
            )
            sleep(1)
            Path(saved_path).unlink(missing_ok=True)
            return

        MODERATION.record_content(
            str(pending_id),
            MODERATION.content_key("machine", "listing"),
            installation_id,
        )
        MODERATION.record_content(
            str(pending_id),
            MODERATION.content_key("image", "machine"),
            installation_id,
        )

        image_slack(
            pending_id,
            img_slack_text="New machine proposed (pending review):",
            pending=True,
        )
    except Exception as e:
        logger.exception(f"Error when processing pending image {pending_id}: {e}")
        message_slack_raw(
            text=f"Error when processing pending image {pending_id} ({type(e).__name__}: {e})",
        )


def address_to_coordinates(
    address: str, area: str, title: str
) -> Tuple[bool, Tuple[float, float]]:
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
def create_machine() -> Tuple[Response, int]:
    """Receive and queue a new machine submission.

    Returns:
        A JSON response and HTTP status describing success, a validation error,
        a duplicate, or a nearby-machine warning.
    """
    if blocked := blocked_contributor_response():
        return blocked

    title = str(request.args.get("title")).strip()
    address = str(request.args.get("address")).strip()
    area = str(request.args.get("area")).strip()

    if reason := text_block_reason(title):
        return jsonify({"error": reason}), 422

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
    name_match_machines = get_nearby_machines_db(
        location[1], location[0], area, radius_m=500
    )
    conflict_kind, conflict_machine, score = find_machine_name_conflict(
        title, name_match_machines
    )
    if conflict_kind == "exact":
        return (
            jsonify(
                {
                    "error": "A machine with this exact name already exists nearby",
                    "duplicate_machine": {
                        **conflict_machine,
                        "title_match_score": score,
                    },
                }
            ),
            409,
        )
    if conflict_kind == "similar":
        return (
            jsonify(
                {
                    "error": f"A similarly named machine '{conflict_machine['name']}' already exists. Pick a more distinct name.",
                    "similar_machine": {
                        **conflict_machine,
                        "title_match_score": score,
                    },
                }
            ),
            409,
        )

    # Preserve the generic proximity warning at its existing 150 metre radius.
    nearby_machines = get_nearby_machines(location[1], location[0], area)
    if request.args.get("ignore_nearby") != "true" and nearby_machines:
        nearby_lines = [
            f"{machine['distance_m']}m: {machine['name']} ({machine['machine_status']})"
            for machine in nearby_machines
        ]
        return (
            jsonify(
                {
                    "error": f"{len(nearby_machines)} nearby machines found:\n"
                    + "\n".join(nearby_lines)
                    + "\n\nDo you still want to submit this machine?",
                    "nearby_machines": nearby_machines,
                }
            ),
            409,
        )

    # Verify that address matches coordinates
    found_coords, (lat, lng) = address_to_coordinates(address, area, title)
    if not found_coords:
        return jsonify({"error": "Google Maps does not know this address"}), 400

    dist = haversine((lat, lng), (location[1], location[0]))
    address_okay = dist <= 1  # km

    # Get google maps address for the coordinates
    out = GM_CLIENT.reverse_geocode(
        [location[1], location[0]], result_type="street_address"
    )
    orig_address = address

    if out != []:  # if address is found
        ad = out[0]["formatted_address"]
        _, score = fuzzysearch.extract(ad, [address], limit=1)[0]
        if score > 85:
            # Prefer Google Maps address over user address
            address = ad
    else:
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

    num_coins = int(request.args.get("num_coins", 4))
    paywall = True if request.args.get("paywall") == "true" else False
    last_updated = str(datetime.today()).split(" ")[0]

    # Insert as pending change (create). The machine is not added to the
    # machines table until a maintainer approves the pending change.
    machine_fields = {
        "name": title,
        "area": area,
        "address": address,
        "latitude": location[1],
        "longitude": location[0],
        "machine_status": "available",
        "num_coins": num_coins,
        "paywall": paywall,
        "last_updated": last_updated,
    }
    pending_id = insert_pending_change_full(
        machine_id=None,
        change_type="create",
        machine_fields=machine_fields,
        submitted_by=anonymous_user_id(),
        change_summary="new machine",
    )

    tmp_path = os.path.join(PATH_IMAGES, f"pending_{pending_id}_tmp.jpg")
    request.files["image"].save(tmp_path)

    message_slack_pending_change(
        change_id=pending_id,
        change_type="create",
        title=title,
        area=area,
        change_summary=format_machine_fields(machine_fields),
        latitude=location[1],
        longitude=location[0],
    )
    request_queue.put(
        (
            process_pending_image,
            (pending_id, tmp_path, anonymous_user_id()),
        )
    )
    if not address_okay:
        if address != orig_address:
            address_print = f"{address} (original input: {orig_address})"
        else:
            address_print = address
        msg = f"Machine request submitted. Watch out, address {address_print} seems >1km away from coordinates ({location[1]}, {location[0]})"
        message_slack_raw(msg)
        return jsonify({"Success": msg}), 201

    return jsonify({"message": "Success!"}), 200


@app.route("/change_machine", methods=["POST"])
def change_machine() -> Tuple[Response, int]:
    """Validate and queue a change to an existing machine.

    The request query parameters describe the machine ID, title, address, area,
    status, coordinates, and optional machine attributes.

    Returns:
        A JSON response and HTTP status describing acceptance, invalid input, or
        a warning that the submitted address and coordinates do not correspond.
    """
    if blocked := blocked_contributor_response():
        return blocked

    machine_id = int(request.args.get("id"))
    title = str(request.args.get("title")).strip()
    address = str(request.args.get("address")).strip()
    area = str(request.args.get("area")).strip()
    status = str(request.args.get("status")).strip()
    latitude = float(request.args.get("lat_coord"))
    longitude = float(request.args.get("lon_coord"))
    if reason := text_block_reason(title):
        return jsonify({"error": reason}), 422

    existing_machine_infos = find_machine_in_database(machine_id)
    if existing_machine_infos is None:
        return jsonify({"error": f"Machine {machine_id} not found"}), 404

    msg = ":\n"

    if has_open_pending_change(machine_id):
        msg += "Machine with pending changes is getting changed *AGAIN* @jannisborn @NinaWie:"

    # Only the fields actually changed are recorded (diff semantics), so this
    # change can be reviewed independently of any other open pending change
    # for the same machine.
    changed_fields: Dict[str, Any] = {}

    # Case 1: status was changed:
    old_status = existing_machine_infos["properties"]["machine_status"]
    msg = _diff_field(
        changed_fields, msg, "Status", "machine_status", old_status, status
    )

    # Case 2: if area was changed -> match to available areas. Kept custom
    # (not _diff_field) because the fuzzy-match validation only needs to run
    # when the raw input differs, and the *matched* value is what's recorded.
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
        changed_fields["area"] = area
        msg += (
            f"\tArea from: {existing_machine_infos['properties']['area']} to: {area} \n"
        )

    # Case 3: Title changed
    title_old = existing_machine_infos["properties"]["name"]
    msg = _diff_field(changed_fields, msg, "Title", "name", title_old, title)

    # Case 4: multimachine changed - deprecated

    # Case 5: paywall reported
    paywall_new = request.args.get("paywall") == "true"
    paywall_old = existing_machine_infos["properties"].get("paywall", False)
    msg = _diff_field(
        changed_fields, msg, "Paywall", "paywall", paywall_old, paywall_new
    )

    # Case 6: Number of coins changed
    num_coins_new = int(request.args.get("num_coins", 4))
    num_coins_old = existing_machine_infos["properties"].get("num_coins", 4)
    msg = _diff_field(
        changed_fields,
        msg,
        "Number of coins",
        "num_coins",
        num_coins_old,
        num_coins_new,
    )

    # Case 7: address and / or location changed --> check for their correspondence
    lng_old, lat_old = existing_machine_infos["geometry"]["coordinates"]
    old_address = existing_machine_infos["properties"]["address"]
    address_okay = True  # by default okay
    address_changed = address != old_address
    location_changed = (
        haversine((lat_old, lng_old), (latitude, longitude), unit=Unit.METERS)
        > LOCATION_CHANGE_THRESHOLD_M
    )
    # if address or coordinates were meaningfully changed, compare them and return warning if needed
    if location_changed or address_changed:
        # Verify that address matches coordinates
        found_coords, (lat, lng) = address_to_coordinates(address, area, title)
        # if address was changed but is not found (error only if address was changed)
        if (not found_coords) and address_changed:
            return jsonify({"error": "Google Maps does not know this address"}), 400

        dist = haversine((lat, lng), (latitude, longitude))
        address_okay = dist <= 1  # km

        if address_changed:
            changed_fields["address"] = address
            msg += f"\tAddress from: {old_address} to: {address}\n"
        if location_changed:
            changed_fields["latitude"] = latitude
            changed_fields["longitude"] = longitude
            msg += f"\t Location from: {lat_old:.4f}, {lng_old:.4f} to: {latitude:.4f}, {longitude:.4f}."

    if not changed_fields:
        msg = f"{machine_id} - Submitted change is identical to the state of the DB (either in pending PR or in main)"
        message_slack_raw(msg)

        return jsonify({"message": "Success!"}), 200

    # The record itself was touched, regardless of which fields changed.
    changed_fields["last_updated"] = str(datetime.today()).split(" ")[0]

    url = existing_machine_infos["properties"]["external_url"]
    change_summary = msg.lstrip(":\n").strip()
    pending_id = insert_pending_change_full(
        machine_id=machine_id,
        change_type="update",
        machine_fields=changed_fields,
        submitted_by=anonymous_user_id(),
        change_summary=change_summary,
    )
    message_slack_pending_change(
        change_id=pending_id,
        change_type="update",
        title=title,
        area=area,
        change_summary=f"at {url}\n{change_summary}",
        machine_id=machine_id,
        latitude=latitude,
        longitude=longitude,
    )

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
    """
    Run the location differ script to fetch latest updates from website.
    """
    with setup_locdiffer_logger():
        old_json_file = "/root/PennyMe/new_data/old_server_locations.json"
        new_json_file = "/root/PennyMe/new_data/server_locations.json"
        new_problems_json_file = "/root/PennyMe/new_data/problems.json"
        debug_path = "/root/PennyMe/debug_new_data"

        # Make sure all preceding jobs are finished
        wait()

        # Export the current DB state so location_differ can read it as a file
        dump_machines_to_file(old_json_file)

        location_differ(
            output_folder="/root/PennyMe/new_data",
            device_json="/root/PennyMe/data/all_locations.json",
            server_json=old_json_file,
            api_key=os.getenv("GCLOUD_KEY"),
            load_from_github=True,
        )

        # Reload the merged output back into the database
        upsert_machines_from_file(
            new_json_file,
            track_in_pending_changes=True,
            track_submitted_by="location_differ",
        )

        # Move debug files for inspection (keep them out of the working dir)
        os.rename(
            new_problems_json_file,
            os.path.join(debug_path, os.path.basename(new_problems_json_file)),
        )
        os.rename(
            new_json_file, os.path.join(debug_path, os.path.basename(new_json_file))
        )


def worker():
    """
    Worker thread that processes the machine change requests.
    """
    while True:
        function, args = request_queue.get()
        try:
            function(*args)
        except Exception as e:
            trace = traceback.format_exc()
            message_slack_raw(
                f"Exception in Queue function {function} with args {args}:\n {e}\n Full traceback: {trace}"
            )
        finally:
            request_queue.task_done()


# Start the worker thread
Thread(target=worker, daemon=True).start()

# Start the Slack Socket Mode handler (interactive buttons)
start_socket_mode_handler()


def create_app():
    logger.remove()
    return app


if __name__ == "__main__":
    app.run(host="0.0.0.0")
