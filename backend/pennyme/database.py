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
    Float,
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

from pennyme.utils import ALL_LOCATIONS, PATH_IMAGES
from pennyme.database_utils import (
    _geojson_feature_to_machine_fields,
    _normalise_url,
    _rename_pending_change_image,
    _row_to_geojson_feature,
)

# login.json lives in the backend/ directory (one level up from this package)
_LOGIN_PATH = Path(__file__).resolve().parent.parent / "db_login.json"
if not _LOGIN_PATH.exists():
    logger.warning(f"Missing database login file: {_LOGIN_PATH}")

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
# (location is handled separately via `latitude`/`longitude`, see
# `_copy_pending_change_to_machine`.)
_MACHINE_SYNC_FIELDS = (
    "name",
    "area",
    "address",
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
    """ORM model for a proposed machine change awaiting approval.

    Each row is an independent patch: for 'update' changes, only the columns
    that were actually submitted are set — every other machine-mirror column
    is NULL, meaning "unchanged". 'create' changes always carry every field,
    since there is no baseline machine row to patch.
    """

    __tablename__ = "pending_changes"

    id = Column(Integer, primary_key=True)
    machine_id = Column(
        Integer, nullable=True
    )  # no FK — may reference all_locations IDs not in machines table
    change_type = Column(String, nullable=False, default="update")
    name = Column(String, nullable=True)
    area = Column(String, nullable=True)
    address = Column(String, nullable=True)
    # Plain floats rather than a PostGIS Geometry: unlike `Machine.geom`, this
    # is never queried spatially, only stored and copied onto `Machine.geom`
    # on approval.
    latitude = Column(Float, nullable=True)
    longitude = Column(Float, nullable=True)
    machine_status = Column(String, nullable=True)
    num_coins = Column(Integer, nullable=True)
    paywall = Column(Boolean, nullable=True)
    external_url = Column(String, nullable=True)
    internal_url = Column(String, nullable=True)
    last_updated = Column(Date, nullable=True)
    submitted_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    reviewed_at = Column(DateTime, nullable=True)
    submitted_by = Column(String, nullable=True)
    change_summary = Column(String, nullable=False)
    status = Column(String, nullable=False, default="open")
    image_path = Column(String, nullable=True)

    @property
    def lat_lon(self) -> tuple[Optional[float], Optional[float]]:
        """Return (latitude, longitude), or (None, None) if this change didn't touch location."""
        return self.latitude, self.longitude

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
        """Construct a PendingChange from a machine-fields dict.

        Only keys present in `machine_fields` are stored; omitted keys stay
        NULL, so callers submitting an 'update' should include only the
        fields that actually changed (see `change_machine` in app.py).
        """
        change = cls(
            machine_id=machine_id,
            change_type=change_type,
            submitted_by=submitted_by or None,
            change_summary=change_summary,
            status=status,
        )
        for field in _PLAIN_PENDING_CHANGE_FIELDS:
            if field in machine_fields:
                setattr(change, field, machine_fields[field])
        if "latitude" in machine_fields and "longitude" in machine_fields:
            change.latitude = float(machine_fields["latitude"])
            change.longitude = float(machine_fields["longitude"])
        for field in ("external_url", "internal_url"):
            if field in machine_fields:
                setattr(change, field, _normalise_url(machine_fields.get(field)))
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


def find_machine_in_database(machine_id: int) -> Optional[Dict[str, Any]]:
    """
    Returns the machine feature for the given ID, checking the database first
    and falling back to all_locations.json.

    Args:
        machine_id: ID of machine to search for

    Returns:
        GeoJSON feature dict, or None if not found anywhere.
    """
    try:
        return get_machine_as_geojson(machine_id)
    except KeyError:
        pass
    for machine_entry in ALL_LOCATIONS["features"]:
        if machine_entry["properties"]["id"] == machine_id:
            return machine_entry
    return None


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
# Write operations – pending_changes
# ---------------------------------------------------------------------------


def insert_pending_change_full(
    machine_id: Optional[int],
    change_type: str,
    machine_fields: dict,
    submitted_by: Optional[str],
    change_summary: str,
    status: str = "open",
) -> int:
    """Write a proposed change (create or update) to pending_changes.

    Every submission becomes its own row. For 'update' changes, only include
    the fields that actually changed in `machine_fields` — omitted fields are
    stored as NULL and left untouched on approval (see
    `_copy_pending_change_to_machine`), so multiple open changes for the same
    machine can be reviewed independently and in any order. 'create' changes
    must include every field, since there is no baseline machine row.

    Args:
        machine_id: Existing machine ID for updates, None for new machines.
        change_type: ``'create'`` or ``'update'``.
        machine_fields: Changed machine columns keyed by column name.
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
    """Copy every set `_MACHINE_SYNC_FIELDS` column from *change* onto *machine*.

    NULL columns on *change* mean "unchanged" and are skipped, so a partial
    'update' row only patches the fields it actually touched.
    """
    for field in _MACHINE_SYNC_FIELDS:
        value = getattr(change, field)
        if value is not None:
            setattr(machine, field, value)
    if change.latitude is not None and change.longitude is not None:
        machine.geom = from_shape(Point(change.longitude, change.latitude), srid=4326)


def _delete_pending_change_images(change: "PendingChange") -> None:
    """Delete the uploaded image(s) for a rejected 'create' pending change.

    New-machine images are saved as ``pending_{change.id}[...].<ext>`` (see
    ``process_pending_image`` / ``create_machine`` in app.py) before a machine
    row exists to attach them to, so they must be cleaned up manually here
    instead of via a foreign-key cascade.
    """
    if change.change_type != "create":
        return
    for image_path in Path(PATH_IMAGES).glob(f"pending_{change.id}*"):
        try:
            image_path.unlink()
            logger.info(f"Deleted rejected pending image {image_path}")
        except OSError as exc:
            logger.warning(
                f"Could not delete rejected pending image {image_path}: {exc}"
            )


def approve_pending_change(change_id: int) -> ReviewResult:
    """Apply a pending change to the machines table and mark it approved.

    For ``create`` changes a new machine row is inserted; for ``update``
    changes the existing row is overwritten, or seeded from all_locations.json
    and inserted with that ID if the machine only existed there. If the
    change was already reviewed, nothing is modified and
    ``ReviewResult.applied`` is False.

    For ``create`` changes, also renames the pending machine image on disk
    from ``pending_{change_id}.<ext>`` to ``{machine_id}.<ext>``.

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
        _rename_pending_change_image(change.change_type, change.id, machine_id)
        return ReviewResult(applied=True, status="approved", machine_id=machine_id)
    finally:
        session.close()


def reject_pending_change(change_id: int) -> ReviewResult:
    """Mark a pending change as rejected without touching the machines table.

    For 'create' changes, also deletes the pending machine image(s) from disk
    since they would otherwise never be referenced or cleaned up.

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
        _delete_pending_change_images(change)
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

    New rows are inserted directly. For an existing row, if it has no open
    pending change, it is overwritten directly and (when
    ``track_in_pending_changes`` is true) logged as an already approved audit
    entry. If it *does* have an open pending change, the sync is merged into
    that pending change instead of touching the live row, so a concurrent
    user edit and this sync are both preserved once the change is reviewed.
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
                if has_changed and has_open_pending_change(machine_id):
                    # A user edit is already awaiting review for this machine;
                    # merge the sync into it instead of overwriting the live
                    # row, so neither change is lost once it's approved.
                    insert_pending_change_full(
                        machine_id=machine_id,
                        change_type="update",
                        machine_fields=machine_fields,
                        submitted_by=track_submitted_by,
                        change_summary="location_differ sync",
                        status="open",
                    )
                    if track_in_pending_changes:
                        tracked_count += 1
                else:
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
