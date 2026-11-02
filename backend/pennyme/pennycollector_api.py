"""Read PennyCollector's public catalogue, keeping its legacy location URLs.

Run ``python -m pennyme.pennycollector_api`` to check the source without Google
Maps, GitHub, Slack, or SQL access. No credentials or browser cookies are needed.
"""

import json
import time
from collections import Counter, defaultdict
from datetime import date
from html import unescape
from urllib.parse import urlsplit

import requests
from loguru import logger
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from pennyme.locations import COUNTRY_TO_CODE
from pennyme.pennycollector import UNAVAILABLE_STATES, WEBSITE_ROOT

API_ROOT = "https://pennycollector.com/wp-json/wp/v2/"
LOCATION_FIELDS = (
    "id,title,link,pc_area,acf.legacy_id,acf.source_url,acf.status,"
    "acf.last_updated,acf.address,acf.city,acf.designs_summary"
)
AREA_ALIASES = {
    "Private Rollers": " Private Rollers",
    "Collector Books": "_Collector Books_",
}
EXCLUDED_AREAS = {" Private Rollers", "_Collector Books_"}


def _get_collection(session, resource, fields):
    """Require complete, consistently paginated JSON before returning any rows."""
    records = []
    expected = None
    page = 1
    while True:
        response = session.get(
            API_ROOT + resource,
            params={
                "per_page": 100,
                "page": page,
                "orderby": "id",
                "order": "asc",
                "_fields": fields,
            },
            timeout=(10, 40),
        )
        if response.headers.get("cf-mitigated") == "challenge":
            raise ValueError(
                f"PennyCollector challenged {response.url}; catalogue not updated"
            )
        response.raise_for_status()
        if "application/json" not in response.headers.get("Content-Type", ""):
            raise ValueError(f"PennyCollector returned non-JSON for {response.url}")
        batch = response.json()
        counts = (
            int(response.headers["X-WP-Total"]),
            int(response.headers["X-WP-TotalPages"]),
        )
        if expected is None:
            expected = counts
        if counts != expected or counts[0] <= 0 or counts[1] != (counts[0] + 99) // 100:
            raise ValueError(
                f"PennyCollector {resource} count changed or is empty; retry the crawl"
            )
        expected_length = min(100, counts[0] - (page - 1) * 100)
        if not isinstance(batch, list) or len(batch) != expected_length:
            raise ValueError(f"Incomplete PennyCollector {resource} page {page}")
        records.extend(batch)
        logger.info(f"PennyCollector {resource}: page {page}/{counts[1]}")
        if page == counts[1]:
            break
        page += 1
        time.sleep(0.5)
    if len({row["id"] for row in records}) != counts[0]:
        raise ValueError(
            f"Duplicate or missing IDs in PennyCollector {resource}; retry the crawl"
        )
    return records


def _to_geojson(record, area):
    fields = record["acf"]
    legacy_id = fields.get("legacy_id")
    if type(legacy_id) is int and legacy_id > 0:
        url = f"{WEBSITE_ROOT}Details.aspx?location={legacy_id}"
        if fields.get("source_url") != url:
            raise ValueError(
                f"PennyCollector post {record['id']} has a conflicting source URL"
            )
    else:
        # Native listings on the new site have no legacy ID or source URL.
        # Their WordPress ID must never be substituted into Details.aspx.
        url = record.get("link") or ""
        parsed = urlsplit(url)
        if (
            isinstance(legacy_id, bool)
            or legacy_id not in (None, "", 0)
            or fields.get("source_url") not in (None, "")
            or parsed.scheme != "https"
            or parsed.netloc != "pennycollector.com"
            or not parsed.path.startswith("/locations/")
            or len(parsed.path.strip("/").split("/")) < 3
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                f"PennyCollector post {record['id']} has neither a valid legacy identity "
                "nor a valid canonical location URL"
            )
    state = fields["status"]
    if state not in ["Active", *UNAVAILABLE_STATES]:
        raise ValueError(f"Unknown PennyCollector status {state!r} for {url}")
    updated = date.fromisoformat(fields["last_updated"]).isoformat()
    title = unescape(record["title"]["rendered"]).strip()
    if not title:
        raise ValueError(f"Missing PennyCollector title for {url}")
    address = ", ".join(
        unescape(fields[key]).strip()
        for key in ("address", "city")
        if fields[key].strip()
    )
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": ["N.A.", "N.A."]},
        "properties": {
            "name": title,
            "area": area,
            "address": address,
            "status": "unvisited",
            "external_url": url,
            "internal_url": "null",
            "machine_status": "available" if state == "Active" else state,
            "id": -1,
            "last_updated": date.today().isoformat(),
        },
        "temporary": {
            "website_updated": updated,
            "wordpress_id": record["id"],
            "canonical_url": record.get("link"),
            "designs_summary": fields.get("designs_summary"),
        },
    }


def get_locations():
    """Return preliminary GeoJSON grouped by PennyMe area; fail on unsafe data.

    Missing records do not prove a machine is retired. Only explicit statuses
    from the source are passed to the differ. WordPress post IDs are never used
    as legacy location IDs or PennyMe machine IDs.
    """
    with requests.Session() as session:
        session.headers["User-Agent"] = (
            "PennyMe/1.0 (+https://github.com/jannisborn/PennyMe)"
        )
        session.mount(
            "https://",
            HTTPAdapter(
                max_retries=Retry(
                    total=3,
                    backoff_factor=1,
                    status_forcelist=[429, 500, 502, 503, 504],
                    allowed_methods=["GET"],
                )
            ),
        )
        terms = _get_collection(session, "pc_area", "id,name")
        areas = {
            term["id"]: AREA_ALIASES.get(unescape(term["name"]), unescape(term["name"]))
            for term in terms
        }
        unknown = set(areas.values()) - COUNTRY_TO_CODE.keys()
        if unknown:
            raise ValueError(f"Unknown PennyCollector areas: {sorted(unknown)}")
        records = _get_collection(session, "pc_location", LOCATION_FIELDS)

    locations = defaultdict(list)
    seen = set()
    for record in records:
        if len(record["pc_area"]) != 1 or record["pc_area"][0] not in areas:
            raise ValueError(
                f"Ambiguous or missing area for PennyCollector post {record['id']}"
            )
        area = areas[record["pc_area"][0]]
        if area in EXCLUDED_AREAS:
            continue
        feature = _to_geojson(record, area)
        url = feature["properties"]["external_url"]
        if url in seen:
            raise ValueError(f"Duplicate PennyCollector legacy URL: {url}")
        seen.add(url)
        locations[area].append(feature)
    if not locations:
        raise ValueError("PennyCollector returned no machine locations")
    return dict(locations)


if __name__ == "__main__":
    locations = get_locations()
    states = Counter(
        feature["properties"]["machine_status"]
        for features in locations.values()
        for feature in features
    )
    print(
        json.dumps(
            {
                "areas": len(locations),
                "locations": sum(states.values()),
                "states": states,
            },
            indent=2,
        )
    )
