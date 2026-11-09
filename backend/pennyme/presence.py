"""Live, foreground sightings. Presence never changes last_updated or status."""

from contextlib import closing
from datetime import datetime, timezone
from math import isfinite

from flask import Blueprint, jsonify, request
from psycopg2.extras import RealDictCursor

from pennyme.database import get_connection
from pennyme.database_utils import _row_to_geojson_feature

presence_api = Blueprint("presence", __name__)


def parse_location(payload, now=None):
    """Accept only a fresh, precise fix; timestamps are Unix seconds in UTC."""
    if not isinstance(payload, dict):
        raise ValueError("A live location is required")
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
    if not 0 <= accuracy <= 10:
        raise ValueError("Location accuracy must be 10 metres or better")
    now = now or datetime.now(timezone.utc)
    if not -5 <= now.timestamp() - measured_at <= 15:
        raise ValueError("Location must have been measured within the last 15 seconds")
    return latitude, longitude, datetime.fromtimestamp(measured_at, timezone.utc)


@presence_api.before_request
def require_presence_contributor():
    if not request.headers.get("X-PennyMe-Anonymous-ID", "").strip():
        return jsonify(error="Missing anonymous contributor identifier"), 400


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
                # A target can be 20 m away; include its entire 100 m neighborhood.
                "WHERE ST_DWithin(geom::geography, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 120) "
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
    try:
        latitude, longitude, measured_at = parse_location(request.get_json(silent=True))
    except ValueError as error:
        return jsonify(error=str(error)), 400
    with closing(get_connection()) as connection, connection:
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            # One conditional update also handles concurrent confirmations and moves.
            cursor.execute(
                "UPDATE machines SET last_seen = CURRENT_TIMESTAMP "
                "WHERE id = %s "
                "AND (last_seen IS NULL OR last_seen < CURRENT_TIMESTAMP - INTERVAL '7 days') "
                "AND ST_DWithin(geom::geography, "
                "ST_SetSRID(ST_MakePoint(%s, %s), 4326)::geography, 20) "
                "AND CURRENT_TIMESTAMP - %s::timestamptz "
                "BETWEEN INTERVAL '-5 seconds' AND INTERVAL '15 seconds' "
                "RETURNING last_seen, id, name, area, address, machine_status, "
                "num_coins, paywall, external_url, internal_url, last_updated, "
                "ST_X(geom) AS longitude, ST_Y(geom) AS latitude",
                (machine_id, longitude, latitude, measured_at),
            )
            row = cursor.fetchone()
    if row is None:
        return jsonify(
            error="The machine was recently confirmed or your location is no longer valid"
        ), 409
    return jsonify(
        last_seen=row["last_seen"].isoformat(),
        machine=_row_to_geojson_feature(dict(row)),
    )
