"""Auxiliary, DB-free helpers for converting between GeoJSON and machine-fields dicts.

These are pure functions with no database or ORM dependency, split out of
database.py to keep that module focused on connections, sessions, and queries.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

from loguru import logger

from pennyme.utils import PATH_IMAGES


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
