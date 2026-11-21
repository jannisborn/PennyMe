"""Live, foreground sightings. Presence never changes last_updated or status."""

from contextlib import closing
from datetime import datetime, timezone
from html import escape
import logging
from math import isfinite

from flask import Blueprint, current_app, jsonify, request
from psycopg2.extras import RealDictCursor

from pennyme.database import clear_machine_geojson_cache, get_connection
from pennyme.database_utils import _row_to_geojson_feature

presence_api = Blueprint("presence", __name__)


def parse_location(payload, now=None):
    """Validate proximity evidence; deliberate 200 m checks tolerate normal GPS caching."""
    if not isinstance(payload, dict):
        raise ValueError("Location is unavailable. Please try again.")
    source = payload.get("source", "automatic")
    if source not in ("automatic", "manual"):
        raise ValueError("Invalid confirmation source")
    max_age, max_accuracy = (120, 50) if source == "manual" else (15, 10)
    fields = ("latitude", "longitude", "accuracy", "measured_at")
    values = [payload.get(field) for field in fields]
    if any(
        isinstance(value, bool) or not isinstance(value, (int, float))
        for value in values
    ):
        raise ValueError("Location fields must be finite numbers")
    try:
        values = [float(value) for value in values]
    except OverflowError:
        raise ValueError("Location fields must be finite numbers") from None
    if not all(isfinite(value) for value in values):
        raise ValueError("Location fields must be finite numbers")
    latitude, longitude, accuracy, measured_at = values
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        raise ValueError("Invalid coordinates")
    if not 0 <= accuracy <= max_accuracy:
        raise ValueError("Your location is not accurate enough yet. Please try again.")
    now = now or datetime.now(timezone.utc)
    if not -5 <= now.timestamp() - measured_at <= max_age:
        raise ValueError("Location is unavailable. Please try again.")
    return latitude, longitude, datetime.fromtimestamp(measured_at, timezone.utc)


def send_machine_seen_notification(machine_id, name):
    # Slack is already initialized by app.py; standalone API tests need no Slack client.
    try:
        from pennyme.slack import message_slack_raw

        name = escape(" ".join(name.split()), quote=False)
        message_slack_raw(f"👀 Machine seen: {name} (#{machine_id})")
    except Exception:
        logging.getLogger(__name__).exception(
            "Sighting saved for machine %s; Slack notification failed", machine_id
        )


def notify_machine_seen(machine_id, name):
    work_queue = current_app.config.get("PRESENCE_NOTIFICATION_QUEUE")
    if work_queue is not None:
        work_queue.put((send_machine_seen_notification, (machine_id, name)))
    else:
        send_machine_seen_notification(machine_id, name)


@presence_api.before_request
def require_presence_contributor():
    if not request.headers.get("X-PennyMe-Anonymous-ID", "").strip():
        return jsonify(error="Missing anonymous contributor identifier"), 400


@presence_api.get("/machines/<int:machine_id>/activity")
def machine_activity(machine_id):
    """Read sightings directly: last_seen changes do not enter the edit delta feed."""
    with closing(get_connection()) as connection, connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT last_seen, last_updated FROM machines WHERE id = %s",
                (machine_id,),
            )
            row = cursor.fetchone()
    if row is None:
        return jsonify(error="Machine not found"), 404
    response = jsonify(
        last_seen=row["last_seen"].isoformat() if row["last_seen"] else None,
        last_updated=row["last_updated"].isoformat(),
    )
    response.headers["Cache-Control"] = "no-store"
    return response


@presence_api.post("/machines/nearby-confirmations")
def nearby_confirmations():
    try:
        latitude, longitude, _ = parse_location(request.get_json(silent=True))
    except ValueError as error:
        return jsonify(error=str(error)), 400
    with closing(get_connection()) as connection, connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT id, name, num_coins, ST_Y(geom) AS latitude, ST_X(geom) AS longitude, "
                "((last_seen IS NULL OR last_seen < CURRENT_TIMESTAMP - INTERVAL '7 days') "
                "AND ST_DWithin(geom::geography, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 20)) AS needs_confirmation "
                "FROM machines "
                # Include manual targets up to 200 m away; automatic prompts stay at 20 m.
                "WHERE ST_DWithin(geom::geography, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 200) "
                "ORDER BY ST_Distance(geom::geography, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography), id",
                (longitude, latitude, longitude, latitude, longitude, latitude),
            )
            machines, nearby_machines = [], []
            for row in cursor.fetchall():
                machine = dict(row)
                needs_confirmation = machine.pop("needs_confirmation")
                nearby_machines.append(machine)
                if needs_confirmation:
                    machines.append(machine)
            # Keep the original eligible-only list for older app versions.
            return jsonify(machines=machines, nearby_machines=nearby_machines)


@presence_api.post("/machines/<int:machine_id>/confirm-presence")
def confirm_presence(machine_id):
    payload = request.get_json(silent=True)
    try:
        latitude, longitude, measured_at = parse_location(payload)
    except ValueError as error:
        return jsonify(error=str(error)), 400
    source = payload.get("source", "automatic")
    if source not in ("automatic", "manual"):
        return jsonify(error="Invalid confirmation source"), 400
    radius = 200 if source == "manual" else 20
    max_age = 120 if source == "manual" else 15
    # A deliberate sighting may refresh last_seen at any time; only automatic
    # prompts need the seven-day cooldown.
    cooldown = (
        "AND (last_seen IS NULL OR last_seen < CURRENT_TIMESTAMP - INTERVAL '7 days') "
        if source == "automatic"
        else ""
    )
    with closing(get_connection()) as connection, connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            # One conditional update also handles concurrent confirmations and moves.
            cursor.execute(
                "UPDATE machines SET last_seen = CURRENT_TIMESTAMP "
                "WHERE id = %s "
                f"{cooldown}"
                "AND ST_DWithin(geom::geography, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, %s) "
                "AND CURRENT_TIMESTAMP - %s::timestamptz "
                "BETWEEN INTERVAL '-5 seconds' AND (%s * INTERVAL '1 second') "
                "RETURNING last_seen, id, name, area, address, machine_status, "
                "num_coins, paywall, external_url, internal_url, last_updated, "
                "ST_X(geom) AS longitude, ST_Y(geom) AS latitude",
                (machine_id, longitude, latitude, radius, measured_at, max_age),
            )
            row = cursor.fetchone()
    if row is None:
        return jsonify(
            error=(
                "Please move closer to the machine (within 200 metres) and try again."
                if source == "manual"
                else "The machine was recently confirmed or you are no longer nearby."
            )
        ), 409
    clear_machine_geojson_cache()
    # Notify only after the transaction committed; a Slack outage must not undo a sighting.
    try:
        notify_machine_seen(row["id"], row["name"])
    except Exception:
        current_app.logger.exception(
            "Sighting saved for machine %s; Slack notification failed", machine_id
        )
    return jsonify(
        last_seen=row["last_seen"].isoformat(),
        machine=_row_to_geojson_feature(dict(row)),
    )
