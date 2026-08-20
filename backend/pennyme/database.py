"""Database access layer for the PennyMe backend.

All functions raise on failure — there are no silent returns on error.
Callers must handle exceptions explicitly.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional
from datetime import datetime

import pandas as pd
import geopandas as gpd
import psycopg2
from loguru import logger
from sqlalchemy import (
    create_engine,
    Column,
    Integer,
    String,
    Boolean,
    Date,
    DateTime,
    cast,
)
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from geoalchemy2 import Geography, Geometry
from geoalchemy2.functions import (
    ST_Distance,
    ST_DWithin,
    ST_MakePoint,
    ST_SetSRID,
    ST_X,
    ST_Y,
)
from geoalchemy2.shape import from_shape, to_shape
from shapely.geometry import Point

# login.json lives in the backend/ directory (one level up from this package)
_LOGIN_PATH = Path(__file__).resolve().parent.parent / "db_login.json"
if not _LOGIN_PATH.exists():
    logger.warning(f"Missing database login file: {_LOGIN_PATH}")

# Whitelist of column names that callers may update via update_machine_fields.
# Never derive this set from user input.
_ALLOWED_MACHINE_FIELDS = frozenset(
    {
        "name",
        "area",
        "address",
        "latitude",
        "longitude",
        "machine_status",
        "num_coins",
        "paywall",
        "external_url",
        "internal_url",
        "last_updated",
    }
)
_PLAIN_PENDING_CHANGE_FIELDS = (
    "name",
    "area",
    "address",
    "machine_status",
    "num_coins",
    "paywall",
    "last_updated",
)
# Machine columns copied verbatim from a PendingChange row when it is approved.
_MACHINE_SYNC_FIELDS = (
    "name",
    "area",
    "address",
    "geom",
    "machine_status",
    "num_coins",
    "paywall",
    "external_url",
    "internal_url",
    "last_updated",
)


# ---------------------------------------------------------------------------
# Database setup and ORM models
# ---------------------------------------------------------------------------

Base = declarative_base()


class Machine(Base):
    """ORM model for a coin machine location."""

    __tablename__ = "machines"

    id = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)
    area = Column(String, nullable=False)
    address = Column(String, nullable=False)
    geom = Column(Geometry(geometry_type="Point", srid=4326), nullable=False)
    machine_status = Column(String, nullable=False, default="available")
    status = Column(String, nullable=False, default="unvisited")
    num_coins = Column(Integer, nullable=False, default=4)
    paywall = Column(Boolean, nullable=False, default=False)
    external_url = Column(String, nullable=True)
    internal_url = Column(String, nullable=True)
    last_updated = Column(Date, nullable=False)

    @classmethod
    def from_dict(cls, machine_id: int, fields: dict) -> "Machine":
        """Construct a Machine from a normalised machine-fields dict (see `_geojson_feature_to_machine_fields`)."""
        return cls(
            id=machine_id,
            name=fields["name"],
            area=fields["area"],
            address=fields["address"],
            geom=from_shape(Point(fields["longitude"], fields["latitude"]), srid=4326),
            machine_status=fields["machine_status"],
            num_coins=fields["num_coins"],
            paywall=fields["paywall"],
            external_url=fields["external_url"],
            internal_url=fields["internal_url"],
            last_updated=fields["last_updated"],
        )


class PendingChange(Base):
    """ORM model for a proposed machine change awaiting approval."""

    __tablename__ = "pending_changes"

    id = Column(Integer, primary_key=True)
    machine_id = Column(
        Integer, nullable=True
    )  # no FK — may reference all_locations IDs not in machines table
    change_type = Column(String, nullable=False, default="update")
    name = Column(String, nullable=False)
    area = Column(String, nullable=False)
    address = Column(String, nullable=False)
    geom = Column(Geometry(geometry_type="Point", srid=4326), nullable=False)
    machine_status = Column(String, nullable=False, default="available")
    num_coins = Column(Integer, nullable=False, default=4)
    paywall = Column(Boolean, nullable=False, default=False)
    external_url = Column(String, nullable=True)
    internal_url = Column(String, nullable=True)
    last_updated = Column(Date, nullable=False)
    submitted_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    reviewed_at = Column(DateTime, nullable=True)
    submitted_by = Column(String, nullable=True)
    change_summary = Column(String, nullable=False)
    status = Column(String, nullable=False, default="open")
    image_path = Column(String, nullable=True)

    @property
    def lat_lon(self) -> tuple[float, float]:
        """Return (latitude, longitude) for the stored PostGIS geometry."""
        point = to_shape(self.geom)
        return point.y, point.x

    @classmethod
    def from_dict(
        cls,
        machine_id: Optional[int],
        change_type: str,
        machine_fields: dict,
        submitted_by: Optional[str],
        change_summary: str,
        status: str = "open",
    ) -> "PendingChange":
        """Construct a PendingChange from the normalized machine-field dict."""
        point = Point(
            float(machine_fields["longitude"]), float(machine_fields["latitude"])
        )
        change = cls(
            machine_id=machine_id,
            change_type=change_type,
            name=machine_fields["name"],
            area=machine_fields["area"],
            address=machine_fields["address"],
            geom=from_shape(point, srid=4326),
            submitted_by=submitted_by or None,
            change_summary=change_summary,
            status=status,
        )
        for field in _PLAIN_PENDING_CHANGE_FIELDS:
            setattr(change, field, machine_fields.get(field))
        change.external_url = _normalise_url(machine_fields.get("external_url"))
        change.internal_url = _normalise_url(machine_fields.get("internal_url"))
        if status != "open":
            change.reviewed_at = datetime.utcnow()
        return change


def create_tables() -> None:
    """Create the machines and pending_changes tables if they do not exist.

    Uses SQLAlchemy metadata to create all tables defined in the ORM classes.

    Raises:
        psycopg2.Error: On any database error.
    """
    engine = get_engine()
    Base.metadata.create_all(engine)
    logger.info("Tables created (or already exist).")


# ---------------------------------------------------------------------------
# Connection and session management
# ---------------------------------------------------------------------------


def get_connection() -> psycopg2.extensions.connection:
    """Return a new psycopg2 connection using credentials from login.json.

    Raises:
        FileNotFoundError: If login.json does not exist.
        psycopg2.OperationalError: If the database connection fails.
    """
    with open(_LOGIN_PATH, "r") as f:
        login = json.load(f)
    return psycopg2.connect(**login)


_engine = None
_session_factory = None


def get_engine():
    """Return a cached SQLAlchemy engine used by ORM and geopandas operations."""
    global _engine
    if _engine is None:
        with open(_LOGIN_PATH) as f:
            login = json.load(f)
        url = "postgresql+psycopg2://{user}:{password}@{host}:{port}/{database}".format(
            **login
        )
        _engine = create_engine(url)
    return _engine


def get_session() -> Session:
    """Return a new SQLAlchemy session."""
    global _session_factory
    if _session_factory is None:
        _session_factory = sessionmaker(bind=get_engine())
    return _session_factory()


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _row_to_geojson_feature(row: dict) -> dict:
    """Convert a machines-table row dict to a GeoJSON Feature dict."""
    props: Dict[str, Any] = {
        "name": row["name"],
        "area": row["area"],
        "address": row["address"],
        "external_url": row.get("external_url") or "null",
        "internal_url": row.get("internal_url") or "null",
        "machine_status": row["machine_status"],
        "id": row["id"],
        "last_updated": str(row["last_updated"]),
    }
    if row.get("num_coins", 4) != 4:
        props["num_coins"] = row["num_coins"]
    if row.get("paywall", False):
        props["paywall"] = row["paywall"]
    return {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": [row["longitude"], row["latitude"]],
        },
        "properties": props,
    }


def _normalise_url(value: Optional[str]) -> str:
    """Return a string value for URL fields, using "null" when unset."""
    if value is None:
        return "null"
    return "null" if value == "null" else value


def _geojson_feature_to_machine_fields(feature: dict) -> Dict[str, Any]:
    """Normalise a GeoJSON Feature's properties into a machine-fields dict."""
    props = feature["properties"]
    lng, lat = feature["geometry"]["coordinates"]
    return {
        "name": props["name"],
        "area": props["area"],
        "address": props["address"],
        "latitude": lat,
        "longitude": lng,
        "machine_status": props.get("machine_status", "available"),
        "num_coins": props.get("num_coins", 4),
        "paywall": props.get("paywall", False),
        "external_url": _normalise_url(props.get("external_url")),
        "internal_url": _normalise_url(props.get("internal_url")),
        "last_updated": props.get("last_updated"),
    }


# ---------------------------------------------------------------------------
# Read operations
# ---------------------------------------------------------------------------


def get_machine_as_geojson(machine_id: int) -> dict:
    """Return a single machine as a GeoJSON Feature.

    Raises:
        KeyError: If no machine with that ID exists.
        psycopg2.Error: On any database error.
    """
    session = get_session()
    try:
        machine = session.query(Machine).filter(Machine.id == machine_id).first()
        if machine is None:
            raise KeyError(f"Machine {machine_id} not found in database")

        result = (
            session.query(
                Machine,
                ST_X(Machine.geom).label("longitude"),
                ST_Y(Machine.geom).label("latitude"),
            )
            .filter(Machine.id == machine_id)
            .first()
        )

        row = {
            "id": machine.id,
            "name": machine.name,
            "area": machine.area,
            "address": machine.address,
            "external_url": machine.external_url,
            "internal_url": machine.internal_url,
            "machine_status": machine.machine_status,
            "num_coins": machine.num_coins,
            "paywall": machine.paywall,
            "last_updated": machine.last_updated,
            "longitude": result.longitude,
            "latitude": result.latitude,
        }
        return _row_to_geojson_feature(row)
    finally:
        session.close()


def get_all_machines_geojson() -> dict:
    """Return all machines as a GeoJSON FeatureCollection.

    Raises:
        psycopg2.Error: On any database error.
    """
    gdf = gpd.read_postgis(
        "SELECT * FROM machines ORDER BY id",
        get_engine(),
        geom_col="geom",
    )
    gdf["last_updated"] = gdf["last_updated"].map(
        lambda value: value.isoformat() if pd.notna(value) else None
    )
    # The iOS app expects URL fields to be strings, never JSON null/None.
    for col in ("external_url", "internal_url"):
        gdf[col] = gdf[col].fillna("null").replace({"None": "null"})
    return json.loads(gdf.to_json())


def get_machine_display_names() -> Dict[int, str]:
    """Return a Slack-friendly display string per machine ID.

    Only queries the columns needed to build the string, avoiding the cost of
    reading geometry and other unused columns for every machine.

    Raises:
        psycopg2.Error: On any database error.
    """
    session = get_session()
    try:
        rows = session.query(
            Machine.id,
            Machine.name,
            Machine.area,
            Machine.machine_status,
            Machine.external_url,
        ).all()
        return {
            row.id: f"{row.name} ({row.area}) Status={row.machine_status} at: {row.external_url or 'null'}"
            for row in rows
        }
    finally:
        session.close()


def has_open_pending_change(machine_id: int) -> bool:
    """Return True if there is an open (unreviewed) pending change for this machine.

    Raises:
        psycopg2.Error: On any database error.
    """
    session = get_session()
    try:
        return (
            session.query(PendingChange)
            .filter(
                (PendingChange.machine_id == machine_id)
                & (PendingChange.status == "open")
            )
            .first()
            is not None
        )
    finally:
        session.close()


def get_nearby_machines_db(
    lat: float, lon: float, area: str, radius_m: int = 150
) -> List[Dict]:
    """Return approved machines within *radius_m* metres of the given point.

    Uses a PostGIS ``ST_DWithin`` query on a GIST-indexed geography column for
    efficient indexed radius lookup, with exact geodesic distances via
    ``ST_Distance``.

    Raises:
        psycopg2.Error: On any database error.
    """
    session = get_session()
    try:
        # ST_MakePoint creates a point without an SRID, so assign WGS84.
        search_point = ST_SetSRID(ST_MakePoint(lon, lat), 4326)

        # Geography calculations return distances in metres.
        machine_geog = cast(Machine.geom, Geography)
        search_geog = cast(search_point, Geography)

        distance = ST_Distance(
            machine_geog,
            search_geog,
        ).label("distance_m")

        results = (
            session.query(
                Machine.id,
                Machine.name,
                Machine.address,
                Machine.area,
                Machine.machine_status,
                distance,
            )
            .filter(
                Machine.area == area,
                ST_DWithin(machine_geog, search_geog, radius_m),
            )
            .order_by(distance)
            .all()
        )

        return [
            {
                "id": row.id,
                "name": row.name,
                "address": row.address,
                "area": row.area,
                "machine_status": row.machine_status,
                "distance_m": round(row.distance_m),
            }
            for row in results
        ]
    finally:
        session.close()


# ---------------------------------------------------------------------------
# Write operations – machines
# ---------------------------------------------------------------------------


def update_machine_fields(machine_id: int, fields: dict) -> None:
    """Update a subset of columns on a machine row.

    Args:
        machine_id: ID of the machine to update.
        fields: Mapping of column name → new value. All keys must appear in
            the allowed-fields whitelist to prevent SQL injection.

    Raises:
        ValueError: If *fields* is empty or contains unknown column names.
        KeyError: If no machine with *machine_id* exists.
        psycopg2.Error: On any database error.
    """
    if not fields:
        raise ValueError("No fields to update")
    unknown = set(fields) - _ALLOWED_MACHINE_FIELDS
    if unknown:
        raise ValueError(f"Unknown machine column(s): {unknown}")

    has_lat = "latitude" in fields
    has_lon = "longitude" in fields
    if has_lat != has_lon:
        raise ValueError("latitude and longitude must be supplied together")

    session = get_session()
    try:
        machine = session.query(Machine).filter(Machine.id == machine_id).first()
        if machine is None:
            raise KeyError(f"Machine {machine_id} not found in database")

        # Update fields
        for key, value in fields.items():
            if key == "latitude" or key == "longitude":
                continue  # Handle geometry separately
            setattr(machine, key, value)

        # Update geometry if coordinates were provided
        if has_lat and has_lon:
            point = Point(fields["longitude"], fields["latitude"])
            machine.geom = from_shape(point, srid=4326)

        session.commit()
    finally:
        session.close()


def update_machine_from_geojson(feature: dict) -> None:
    """Apply all mutable fields from a GeoJSON Feature to the machines table.

    Raises:
        KeyError: If the machine is not found.
        psycopg2.Error: On any database error.
    """
    machine_id = feature["properties"]["id"]
    update_machine_fields(machine_id, _geojson_feature_to_machine_fields(feature))


# ---------------------------------------------------------------------------
# Write operations – pending_changes
# ---------------------------------------------------------------------------


def merge_pending_change_values(
    existing_change: Any,
    machine_fields: dict,
    new_change_summary: str,
    submitted_by: Optional[str],
) -> None:
    """Merge a newly submitted change into a pre-existing open pending row.

    The newest value for each field wins, but the review summary and submitter
    metadata are preserved in a cumulative form so multiple edits for the same
    machine are not lost.
    """
    for field in _PLAIN_PENDING_CHANGE_FIELDS:
        if field in machine_fields:
            setattr(existing_change, field, machine_fields[field])

    if (
        "latitude" in machine_fields or "longitude" in machine_fields
    ) and machine_fields.get("latitude") is not None:
        existing_change.geom = from_shape(
            Point(
                float(machine_fields["longitude"]), float(machine_fields["latitude"])
            ),
            srid=4326,
        )

    for field in ("external_url", "internal_url"):
        if field in machine_fields:
            setattr(existing_change, field, _normalise_url(machine_fields.get(field)))

    existing_change.change_summary = (
        f"{existing_change.change_summary}; {new_change_summary}"
    )
    existing_change.submitted_by = f"{existing_change.submitted_by}; {submitted_by}"
    existing_change.status = "open"
    existing_change.reviewed_at = None


def insert_pending_change_full(
    machine_id: Optional[int],
    change_type: str,
    machine_fields: dict,
    submitted_by: Optional[str],
    change_summary: str,
    status: str = "open",
) -> int:
    """Write a proposed change (create or update) to pending_changes.

    The row holds the full proposed machine state so the approver can apply
    it directly without re-reading the request.

    If a machine already has an open pending change, the new change is merged
    into that row instead of creating a second pending proposal. This preserves
    unrelated edits from multiple contributors while ensuring the reviewer sees
    the latest combined pending state.

    Args:
        machine_id: Existing machine ID for updates, None for new machines.
        change_type: ``'create'`` or ``'update'``.
        machine_fields: All mutable machine columns keyed by column name.
        submitted_by: Anonymous installation identifier of the submitter.
        change_summary: Human-readable description (``'new machine'`` or the
            ``msg`` string from ``change_machine``).
        status: Review state for the row. Defaults to ``'open'``.

    Returns:
        The auto-assigned ``id`` of the new pending_changes row.

    Raises:
        psycopg2.Error: On any database error.
    """

    session = get_session()
    try:
        if (
            machine_id is not None
            and status == "open"
            and has_open_pending_change(machine_id)
        ):
            existing_change = (
                session.query(PendingChange)
                .filter(
                    (PendingChange.machine_id == machine_id)
                    & (PendingChange.status == "open")
                )
                .order_by(PendingChange.submitted_at.desc())
                .first()
            )
            if existing_change is not None:
                merge_pending_change_values(
                    existing_change,
                    machine_fields,
                    change_summary,
                    submitted_by,
                )
                session.commit()
                return existing_change.id

        change = PendingChange.from_dict(
            machine_id=machine_id,
            change_type=change_type,
            machine_fields=machine_fields,
            submitted_by=submitted_by,
            change_summary=change_summary,
            status=status,
        )
        session.add(change)
        session.flush()
        change_id = change.id
        session.commit()
        return change_id
    finally:
        session.close()


def get_open_pending_changes() -> List[Dict]:
    """Return all open (unreviewed) pending changes ordered by submission time.

    Raises:
        psycopg2.Error: On any database error.
    """

    session = get_session()
    try:
        changes = (
            session.query(PendingChange)
            .filter(PendingChange.status == "open")
            .order_by(PendingChange.submitted_at)
            .all()
        )
        return [
            {
                "id": c.id,
                "machine_id": c.machine_id,
                "change_type": c.change_type,
                "name": c.name,
                "area": c.area,
                "address": c.address,
                "latitude": c.lat_lon[0],
                "longitude": c.lat_lon[1],
                "machine_status": c.machine_status,
                "num_coins": c.num_coins,
                "paywall": c.paywall,
                "external_url": c.external_url,
                "internal_url": c.internal_url,
                "last_updated": c.last_updated,
                "submitted_at": c.submitted_at,
                "reviewed_at": c.reviewed_at,
                "submitted_by": c.submitted_by,
                "change_summary": c.change_summary,
                "status": c.status,
                "image_path": c.image_path,
            }
            for c in changes
        ]
    finally:
        session.close()


@dataclass
class ReviewResult:
    """Outcome of a call to `approve_pending_change` or `reject_pending_change`.

    ``applied`` is False when the change had already been reviewed earlier —
    this is an expected, normal outcome (e.g. a Slack button clicked twice),
    not an error, so callers can branch on it without a try/except.
    """

    applied: bool
    status: str
    machine_id: Optional[int] = None


def _copy_pending_change_to_machine(change: "PendingChange", machine: Machine) -> None:
    """Copy every `_MACHINE_SYNC_FIELDS` column from *change* onto *machine*."""
    for field in _MACHINE_SYNC_FIELDS:
        setattr(machine, field, getattr(change, field))


def approve_pending_change(change_id: int) -> ReviewResult:
    """Apply a pending change to the machines table and mark it approved.

    For ``create`` changes a new machine row is inserted; for ``update``
    changes the existing row is overwritten, or seeded from all_locations.json
    and inserted with that ID if the machine only existed there. If the
    change was already reviewed, nothing is modified and
    ``ReviewResult.applied`` is False.

    Raises:
        KeyError: If the pending change is not found, or an update change
            targets a machine not found in the database or all_locations.json.
        ValueError: If an update change has no machine_id.
        psycopg2.Error: On any database error.
    """
    session = get_session()
    try:
        change = (
            session.query(PendingChange).filter(PendingChange.id == change_id).first()
        )
        if change is None:
            raise KeyError(f"Pending change {change_id} not found")
        if change.status != "open":
            return ReviewResult(applied=False, status=change.status)

        if change.change_type == "create":
            machine = Machine()
            _copy_pending_change_to_machine(change, machine)
            session.add(machine)
            session.flush()
            machine_id = machine.id
        else:
            machine_id = change.machine_id
            if machine_id is None:
                raise ValueError(f"Update pending change {change_id} has no machine_id")

            machine = session.query(Machine).filter(Machine.id == machine_id).first()
            if machine is None:
                # Machine may only exist in the app-bundled all_locations.json
                # (never migrated into the machines table). Seed the row from
                # there so it starts from the real baseline, then the pending
                # change is applied on top below.
                from pennyme.utils import find_machine_in_database

                base_feature = find_machine_in_database(machine_id)
                if base_feature is None:
                    raise KeyError(f"Machine {machine_id} not found for update")
                fields = _geojson_feature_to_machine_fields(base_feature)
                machine = Machine.from_dict(machine_id, fields)
                session.add(machine)
            _copy_pending_change_to_machine(change, machine)

        change.status = "approved"
        change.reviewed_at = datetime.utcnow()
        session.commit()
        return ReviewResult(applied=True, status="approved", machine_id=machine_id)
    finally:
        session.close()


def reject_pending_change(change_id: int) -> ReviewResult:
    """Mark a pending change as rejected without touching the machines table.

    If the change was already reviewed, nothing is modified and
    ``ReviewResult.applied`` is False.

    Raises:
        KeyError: If the pending change is not found.
        psycopg2.Error: On any database error.
    """
    session = get_session()
    try:
        change = (
            session.query(PendingChange).filter(PendingChange.id == change_id).first()
        )
        if change is None:
            raise KeyError(f"Pending change {change_id} not found")
        if change.status != "open":
            return ReviewResult(applied=False, status=change.status)

        change.status = "rejected"
        change.reviewed_at = datetime.utcnow()
        session.commit()
        return ReviewResult(applied=True, status="rejected")
    finally:
        session.close()


# ---------------------------------------------------------------------------
# Bulk file operations (used by location_differ and run_location_differ)
# ---------------------------------------------------------------------------


def dump_machines_to_file(path: str) -> None:
    """Write all machines as a GeoJSON FeatureCollection to *path*.

    Raises:
        psycopg2.Error: On any database error.
        OSError: On any file I/O error.
    """
    data = get_all_machines_geojson()
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
    logger.info(f"Dumped {len(data['features'])} machines to {path}")


def upsert_machines_from_file(
    path: str,
    track_in_pending_changes: bool = False,
    track_submitted_by: Optional[str] = None,
) -> None:
    """Upsert every machine in a GeoJSON FeatureCollection file into the DB.

    Existing rows (matched by id) are fully overwritten; new rows are inserted.
    When ``track_in_pending_changes`` is true, every created or changed row is
    also written to ``pending_changes`` as an already approved audit entry.
    Only the location_differ output should call this.

    Raises:
        ValueError: If the file contains no features.
        psycopg2.Error: On any database error.
        OSError: On any file I/O error.
    """

    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    features = data.get("features", [])
    if not features:
        raise ValueError(f"No features found in {path}")

    session = get_session()
    try:
        tracked_count = 0
        for feature in features:
            lng, lat = feature["geometry"]["coordinates"]
            machine_id = feature["properties"]["id"]
            machine_fields = _geojson_feature_to_machine_fields(feature)

            # Try to find existing machine
            existing = session.query(Machine).filter(Machine.id == machine_id).first()

            if existing:
                existing_point = to_shape(existing.geom)
                old_last_updated = (
                    str(existing.last_updated)
                    if existing.last_updated is not None
                    else None
                )
                new_last_updated = (
                    str(machine_fields["last_updated"])
                    if machine_fields["last_updated"] is not None
                    else None
                )
                has_changed = (
                    existing.name != machine_fields["name"]
                    or existing.area != machine_fields["area"]
                    or existing.address != machine_fields["address"]
                    or existing_point.x != machine_fields["longitude"]
                    or existing_point.y != machine_fields["latitude"]
                    or existing.machine_status != machine_fields["machine_status"]
                    or existing.num_coins != machine_fields["num_coins"]
                    or existing.paywall != machine_fields["paywall"]
                    or existing.external_url != machine_fields["external_url"]
                    or existing.internal_url != machine_fields["internal_url"]
                    or old_last_updated != new_last_updated
                )

                # Update existing
                existing.name = machine_fields["name"]
                existing.area = machine_fields["area"]
                existing.address = machine_fields["address"]
                existing.geom = from_shape(Point(lng, lat), srid=4326)
                existing.machine_status = machine_fields["machine_status"]
                existing.num_coins = machine_fields["num_coins"]
                existing.paywall = machine_fields["paywall"]
                existing.external_url = machine_fields["external_url"]
                existing.internal_url = machine_fields["internal_url"]
                existing.last_updated = machine_fields["last_updated"]

                if track_in_pending_changes and has_changed:
                    insert_pending_change_full(
                        machine_id=machine_id,
                        change_type="update",
                        machine_fields=machine_fields,
                        submitted_by=track_submitted_by,
                        change_summary="location_differ sync",
                        status="approved",
                    )
                    tracked_count += 1
            else:
                # Insert new
                machine = Machine.from_dict(machine_id, machine_fields)
                session.add(machine)

                if track_in_pending_changes:
                    insert_pending_change_full(
                        machine_id=None,
                        change_type="create",
                        machine_fields=machine_fields,
                        submitted_by=track_submitted_by,
                        change_summary="location_differ sync",
                        status="approved",
                    )
                    tracked_count += 1

        session.commit()
        logger.info(f"Upserted {len(features)} machines from {path}")
        if track_in_pending_changes:
            logger.info(
                f"Tracked {tracked_count} location_differ changes in pending_changes"
            )
    finally:
        session.close()
