"""Auxiliary, DB-free helpers for converting between GeoJSON and machine-fields dicts.

These are pure functions with no database or ORM dependency, split out of
database.py to keep that module focused on connections, sessions, and queries.

`MACHINE_FIELDS` is the single source of truth for the plain (non-geometry,
non-URL) columns shared by `Machine` and `PendingChange` in database.py.
Adding a new simple machine attribute (e.g. another boolean flag) means
adding one entry here plus the matching `Column(...)` on both ORM classes —
every dict/diff/GeoJSON conversion below and in database.py is driven by
this table instead of hardcoding the field name in each place.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Tuple

from loguru import logger

from pennyme.utils import PATH_IMAGES


def _values_differ(old: Any, new: Any) -> bool:
    """Default "did this field change" check."""
    return old != new


def _dates_differ(old: Any, new: Any) -> bool:
    """last_updated may be a `date` object on one side and an ISO string on the other."""
    old_normed = str(old) if old is not None else None
    new_normed = str(new) if new is not None else None
    return old_normed != new_normed


@dataclass(frozen=True)
class MachineField:
    """One plain machine column mirrored by both `Machine` and `PendingChange`."""

    name: str
    default: Any
    omit_from_geojson_if_default: bool = False
    differs: Callable[[Any, Any], bool] = _values_differ


MACHINE_FIELDS: Tuple[MachineField, ...] = (
    MachineField("name", None),
    MachineField("area", None),
    MachineField("address", None),
    MachineField("machine_status", "available"),
    MachineField("num_coins", 4, omit_from_geojson_if_default=True),
    MachineField("paywall", False, omit_from_geojson_if_default=True),
    MachineField("last_updated", None, differs=_dates_differ),
)


def _row_to_geojson_feature(row: dict) -> dict:
    """Convert a machines-table row dict to a GeoJSON Feature dict."""
    props: Dict[str, Any] = {"id": row["id"]}
    for f in MACHINE_FIELDS:
        value = row.get(f.name, f.default)
        if f.omit_from_geojson_if_default and value == f.default:
            continue
        props[f.name] = str(value) if f.name == "last_updated" else value
    props["external_url"] = row.get("external_url") or "null"
    props["internal_url"] = row.get("internal_url") or "null"
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
    fields = {f.name: props.get(f.name, f.default) for f in MACHINE_FIELDS}
    fields["latitude"] = lat
    fields["longitude"] = lng
    fields["external_url"] = _normalise_url(props.get("external_url"))
    fields["internal_url"] = _normalise_url(props.get("internal_url"))
    return fields


def _rename_pending_change_image(
    change_type: str, change_id: int, machine_id: int
) -> None:
    """Rename an approved 'create' change's image from its pending name to its machine ID.

    New-machine images are uploaded as ``pending_{change_id}.<ext>`` before a
    machine row exists to attach them to (see ``process_pending_image`` in
    app.py); on approval they must be renamed to ``{machine_id}.<ext>`` so the
    app can find them.
    """
    if change_type != "create":
        return
    matches = list(Path(PATH_IMAGES).glob(f"pending_{change_id}.*"))
    if not matches:
        logger.warning(
            f"Expected pending image for change {change_id} not found; skipping rename"
        )
        return
    for src in matches:
        dst = src.with_name(f"{machine_id}{src.suffix}")
        try:
            src.rename(dst)
            logger.info(f"Renamed {src} -> {dst}")
        except OSError as exc:
            logger.warning(f"Could not rename approved pending image {src}: {exc}")
