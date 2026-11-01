"""PennyCollector SQL differ with automatic Slack diff/problem reports.

Run from backend: python -m scripts.location_differ_api --output-dir REPORT_DIR
Dry run is the default. Use --apply to commit, --no-slack for local previews.
The historical location_differ.py and its endpoint are deliberately untouched.
"""

import argparse
import base64
import csv
import hashlib
import json
import os
import re
import time
import unicodedata
from collections import Counter, defaultdict
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import googlemaps
import psycopg2
from psycopg2.extras import RealDictCursor
import requests
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from haversine import haversine
from loguru import logger
from thefuzz import fuzz
from slack_sdk import WebClient

from pennyme.locations import area_from_google_result
from pennyme.pennycollector_api import get_locations
from pennyme.pennycollector_exceptions import (
    CONFIRMED_IDENTITIES,
    IGNORED_LISTINGS,
    regional_machines,
)

BACKEND = Path(__file__).resolve().parents[1]
NON_MACHINE_LABEL = re.compile(
    r"\b(ret(?:ired)?|gone|moved|removed|empty|pennybooks?|pocketbooks?|books?)\b", re.I
)
MACHINE_LABEL = re.compile(r"\b(?:machine|maquina)\s*(?:#|No\.?\s*)?(\d+)\b", re.I)


def read_database(login_path):
    """Take a consistent, server-enforced read-only snapshot of relevant tables."""
    credentials = json.loads(Path(login_path).read_text())
    with psycopg2.connect(**credentials, connect_timeout=15) as connection:
        connection.set_session(readonly=True, isolation_level="REPEATABLE READ")
        try:
            with connection.cursor(cursor_factory=RealDictCursor) as cursor:
                cursor.execute("SET LOCAL statement_timeout = '30s'")
                cursor.execute("SHOW transaction_read_only")
                if cursor.fetchone()["transaction_read_only"] != "on":
                    raise RuntimeError("Database transaction is not read-only")
                return database_snapshot(cursor)
        finally:
            connection.rollback()


def database_snapshot(cursor):
    """Shared read-only SELECTs, also used under the short apply transaction lock."""
    result = {}
    for table in ("machines", "deleted_machines"):
        cursor.execute(
            f"SELECT id, name, area, address, machine_status, external_url, "
            f"last_updated, num_coins, paywall, ST_X(geom) AS longitude, "
            f"ST_Y(geom) AS latitude FROM {table} ORDER BY id"
        )
        result[table] = [dict(row) for row in cursor.fetchall()]
    cursor.execute(
        "SELECT id, machine_id, change_type, name, area, address, "
        "machine_status, external_url, latitude, longitude FROM pending_changes "
        "WHERE status = 'open' ORDER BY id"
    )
    result["pending_changes"] = [dict(row) for row in cursor.fetchall()]
    return result


def read_github_lists(credentials_path):
    """Use the same branch preference as the historical helper, without Slack imports."""
    config = json.loads(Path(credentials_path).read_text())
    root = f"https://api.github.com/repos/{config['owner']}/{config['repo']}"
    with requests.Session() as session:
        session.headers.update(
            {
                "Authorization": f"Bearer {config['token']}",
                "Accept": "application/vnd.github+json",
            }
        )
        response = session.get(root + "/branches/machine_updates", timeout=(10, 30))
        if response.status_code == 404:
            response = session.get(root + "/branches/main", timeout=(10, 30))
            branch = "main"
        else:
            branch = "machine_updates"
        response.raise_for_status()
        commit = response.json()["commit"]["sha"]
        result = {"branch": branch, "commit": commit}
        for name in ("problems", "skip"):
            response = session.get(
                root + f"/contents/data/{name}.json",
                params={"ref": commit},
                timeout=(10, 30),
            )
            response.raise_for_status()
            payload = response.json()
            if payload.get("encoding") != "base64":
                raise ValueError(f"Unexpected GitHub encoding for {name}.json")
            data = json.loads(base64.b64decode(payload["content"]))
            if data.get("type") != "FeatureCollection" or not isinstance(
                data.get("features"), list
            ):
                raise ValueError(f"Invalid GitHub {name}.json")
            result[name] = data
            result[name + "_sha"] = payload["sha"]
        return result


def fetch_inputs(
    output_dir,
    db_login=BACKEND / "db_login.json",
    github_login=BACKEND / "github_token.json",
):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    inputs = {"started_at": datetime.now(timezone.utc).isoformat()}
    inputs["github"] = read_github_lists(github_login)
    inputs["source"] = [
        feature for group in get_locations().values() for feature in group
    ]
    inputs["database"] = read_database(db_login)
    inputs["snapshot_at"] = datetime.now(timezone.utc).isoformat()
    serialized = json.dumps(inputs, ensure_ascii=False, indent=2, default=str)
    (output_dir / "inputs.json").write_text(serialized)
    return json.loads(serialized)


def location_key(url):
    parsed = urlsplit(url or "")
    if (
        parsed.hostname == "locations.pennycollector.com"
        and parsed.path.lower() == "/details.aspx"
    ):
        ids = parse_qs(parsed.query).get("location", [])
        if len(ids) == 1 and ids[0].isascii() and ids[0].isdigit():
            return "legacy:" + str(int(ids[0]))
    return (url or "").rstrip("/")


def normalized(text):
    text = unicodedata.normalize("NFKD", text or "").casefold()
    return " ".join(
        re.findall(r"[^\W_]+", "".join(c for c in text if not unicodedata.combining(c)))
    )


def shared_name_phrase(left, right):
    """Require a meaningful shared pair of consecutive words, not 'gift shop'."""
    left, right = normalized(left).split(), normalized(right).split()
    pairs = set(zip(left, left[1:])) & set(zip(right, right[1:]))
    generic = {
        ("gift", "shop"),
        ("souvenir", "shop"),
        ("visitor", "center"),
        ("visitor", "centre"),
        ("tourist", "information"),
        ("de", "la"),
        ("de", "san"),
        ("of", "the"),
    }
    return any(pair not in generic and len("".join(pair)) >= 8 for pair in pairs)


def strong_identity(candidate):
    close = candidate["distance_m"] is not None and candidate["distance_m"] <= 250
    return (
        candidate["exact_text"]
        or (candidate["distance_m"] is not None and candidate["distance_m"] <= 10)
        or (
            close and (candidate["name_score"] >= 85 or candidate["shared_name_phrase"])
        )
        or (candidate["name_score"] >= 95 and candidate["address_score"] >= 80)
    )


def individual_devices(rows):
    """Keep numbered devices distinct; collapse product/design rows for one device."""
    active = [
        r
        for r in rows
        if not r["retired_or_book"] and not NON_MACHINE_LABEL.search(r["label"])
    ]
    if not active:
        return []
    groups = defaultdict(list)
    numbers = [MACHINE_LABEL.search(normalized(r["label"])) for r in active]
    for row, number in zip(active, numbers):
        groups[int(number[1]) if all(numbers) else 1].append(row)
    devices = []
    for number, products in sorted(groups.items()):
        # Penny/Euro products describe the app's primary machine. Unknown design
        # counts use the same default (4) as the SQL model; no manual task needed.
        primary = next((r for r in products if r["coin_type"] != "Token"), products[0])
        devices.append(
            {
                **primary,
                "label": f"Machine {number}",
                "num_coins": primary["num_coins"] or 4,
            }
        )
    return devices


def parse_machine_table(html):
    table = BeautifulSoup(html, "html.parser").select_one("table.pc-machines")
    if table is None:
        raise ValueError("No individual-machine table in detail page")
    rows = []
    for row in table.select("tbody tr"):
        cells = row.find_all(["th", "td"], recursive=False)
        if len(cells) != 3:
            raise ValueError("Unexpected machine table columns")
        label, designs, coin_type = [c.get_text(" ", strip=True) for c in cells]
        rows.append(
            {
                "label": label,
                "num_coins": int(designs)
                if designs.isascii() and designs.isdigit()
                else None,
                "coin_type": coin_type,
                "retired_or_book": bool(NON_MACHINE_LABEL.search(label)),
            }
        )
    caption = table.find("caption")
    expected = (
        re.match(r"(\d+) machines?", caption.get_text(strip=True)) if caption else None
    )
    if not rows or expected is None or int(expected[1]) != len(rows):
        raise ValueError("Incomplete individual-machine table")
    return rows


class SourceEvidence:
    """Cache public detail tables and automatic geocodes for repeatable review."""

    def __init__(self, output_dir, geocode=True):
        self.path = Path(output_dir) / "evidence.json"
        self.cache = json.loads(self.path.read_text()) if self.path.exists() else {}
        self.session = requests.Session()
        self.session.headers["User-Agent"] = (
            "PennyMe/1.0 (+https://github.com/jannisborn/PennyMe)"
        )
        self.maps = (
            googlemaps.Client(
                key=os.environ["GCLOUD_KEY"],
                timeout=10,
                retry_timeout=30,
                retry_over_query_limit=False,
            )
            if geocode
            else None
        )

    def get(self, source):
        logger.info(
            "Inspecting {} ({})",
            source["properties"]["name"],
            source["properties"]["area"],
        )
        url = source["temporary"].get("canonical_url")
        key = location_key(source["properties"]["external_url"])
        evidence = self.cache.setdefault(key, {})
        if "machines" not in evidence:
            if not url or urlsplit(url).hostname != "pennycollector.com":
                return {"error": "Missing canonical source URL; refresh API snapshot"}
            try:
                response = self.session.get(url, timeout=(10, 30))
                response.raise_for_status()
                if response.headers.get("cf-mitigated") == "challenge":
                    raise ValueError("Cloudflare challenge")
                evidence["machines"] = parse_machine_table(response.text)
                evidence["detail_url"] = url
                evidence["fetched_at"] = datetime.now(timezone.utc).isoformat()
                time.sleep(0.2)
            except (requests.RequestException, ValueError) as error:
                return {"error": f"Detail lookup failed: {type(error).__name__}"}
        if self.maps and "latitude" not in evidence.get("geocode", {}):
            p = source["properties"]
            query = f"{p['name']}, {p['address']}, {p['area']}"
            try:
                results = self.maps.geocode(query)
                if not results:
                    for fallback in (
                        f"{p['address']}, {p['area']}",
                        f"{p['name']}, {p['area']}",
                    ):
                        if results:
                            break
                        results = self.maps.geocode(fallback)
                        query = fallback
                elif results[0].get("partial_match") and p["address"]:
                    # A partial venue-name match can point to a different entrance.
                    # Prefer a complete match for the supplied street address.
                    address_query = f"{p['address']}, {p['area']}"
                    address_results = self.maps.geocode(address_query)
                    if (
                        len(address_results) == 1
                        and not address_results[0].get("partial_match")
                        and area_from_google_result(address_results[0]) == p["area"]
                        and address_results[0]["geometry"]["location_type"]
                        in {"ROOFTOP", "RANGE_INTERPOLATED"}
                    ):
                        results, query = address_results, address_query
                if not results:
                    evidence["geocode"] = {
                        "query": query,
                        "safe": False,
                        "reason": "No results",
                    }
                else:
                    result = results[0]
                    area = area_from_google_result(result)
                    geometry = result["geometry"]
                    precise = geometry["location_type"] in {
                        "ROOFTOP",
                        "RANGE_INTERPOLATED",
                    } or bool(
                        set(result["types"])
                        & {"establishment", "point_of_interest", "premise"}
                    )
                    evidence["geocode"] = {
                        "query": query,
                        "latitude": geometry["location"]["lat"],
                        "longitude": geometry["location"]["lng"],
                        "area": area,
                        "formatted_address": result.get("formatted_address"),
                        "accuracy": geometry["location_type"],
                        "types": result["types"],
                        "partial_match": bool(result.get("partial_match")),
                        "result_count": len(results),
                        "safe": bool(
                            precise
                            and not result.get("partial_match")
                            and area == p["area"]
                            and len(results) == 1
                        ),
                    }
            except Exception as error:
                # Do not persist transient errors or exception URLs containing API keys.
                return {
                    **evidence,
                    "error": f"Geocoding failed: {type(error).__name__}",
                }
        geo = evidence.get("geocode", {})
        if (
            self.maps
            and "latitude" in geo
            and not geo.get("safe")
            and "reverse_address" not in geo
        ):
            # A broad/partial result is still usable. Reverse geocoding supplies
            # its address; a transient reverse lookup must not block the machine.
            try:
                results = self.maps.reverse_geocode((geo["latitude"], geo["longitude"]))
                geo["reverse_address"] = (
                    results[0].get("formatted_address") if results else None
                )
            except Exception:
                pass
        self.path.write_text(json.dumps(self.cache, ensure_ascii=False, indent=2))
        return deepcopy(evidence)


def candidates_for(source, machines, geocode=None):
    p = source["properties"]
    name, address = normalized(p["name"]), normalized(p["address"])
    candidates = []
    for machine in machines:
        same_area = normalized(machine["area"]) == normalized(p["area"])
        distance = None
        if (
            geocode
            and "latitude" in geocode
            and machine.get("latitude") is not None
            and machine.get("longitude") is not None
        ):
            if (
                abs(geocode["latitude"] - machine["latitude"]) < 0.02
                and abs(geocode["longitude"] - machine["longitude"]) < 0.04
            ):
                distance = round(
                    haversine(
                        (geocode["latitude"], geocode["longitude"]),
                        (machine["latitude"], machine["longitude"]),
                        unit="m",
                    ),
                    1,
                )
        if not same_area and (distance is None or distance > 250):
            continue
        name_score = fuzz.ratio(name, normalized(machine["name"]))
        address_score = (
            fuzz.ratio(address, normalized(machine["address"])) if address else 0
        )
        exact = (
            name == normalized(machine["name"])
            and bool(address)
            and address == normalized(machine["address"])
        )
        similar = (name_score >= 90 and address_score >= 60) or (
            name_score >= 72 and address_score >= 88
        )
        if exact or similar or (distance is not None and distance <= 250):
            candidates.append(
                {
                    **machine,
                    "name_score": name_score,
                    "address_score": address_score,
                    "distance_m": distance,
                    "exact_text": exact,
                    "shared_name_phrase": shared_name_phrase(
                        p["name"], machine["name"]
                    ),
                }
            )
    return sorted(
        candidates,
        key=lambda c: (c["exact_text"], c["name_score"] + c["address_score"]),
        reverse=True,
    )


def compare(inputs, evidence_for):
    machines = inputs["database"]["machines"]
    if len({m["id"] for m in machines}) != len(machines):
        raise ValueError("Duplicate PennyMe machine IDs in SQL snapshot")
    by_url = defaultdict(list)
    for machine in machines:
        if machine.get("external_url") not in (None, "", "null", "None"):
            by_url[location_key(machine["external_url"])].append(machine)
    known = {
        location_key(f["properties"]["external_url"]): f
        for f in inputs["github"]["problems"]["features"]
    }
    skipped = {
        location_key(f["properties"]["external_url"]): f
        for f in inputs["github"]["skip"]["features"]
    }
    deleted = [
        {**m, "record_type": "deleted"} for m in inputs["database"]["deleted_machines"]
    ]
    pending = inputs["database"]["pending_changes"]
    pending_ids = {m["machine_id"] for m in pending if m["machine_id"] is not None}
    pending_creates = [
        {**m, "record_type": "pending"} for m in pending if m["change_type"] == "create"
    ]
    # Distinct website IDs with the same venue identity represent separate
    # machines. An already-linked sibling must not absorb the missing one.
    venue_keys = defaultdict(set)
    for source in inputs["source"]:
        p = source["properties"]
        venue_keys[tuple(normalized(p[k]) for k in ("area", "name", "address"))].add(
            location_key(p["external_url"])
        )
    claimed_siblings = defaultdict(set)
    records, disagreements = [], []
    mapping = {
        "available": "available",
        "Gone": "retired",
        "Moved": "retired",
        "Out of Order": "out-of-order",
    }
    for source in inputs["source"]:
        p = source["properties"]
        key = location_key(p["external_url"])
        item = {
            "source": deepcopy(source),
            "category": None,
            "reason": "",
            "candidates": [],
        }
        records.append(item)
        existing = by_url.get(key) or by_url.get(
            location_key(source["temporary"].get("canonical_url"))
        )
        if key in skipped or key in known:
            item["category"] = "known_exception"
            entry = skipped.get(key) or known[key]
            item["reason"] = entry.get("reason") or entry.get(
                "problem", "Known GitHub exception"
            )
            item["registry"] = "skip" if key in skipped else "problems"
            continue
        if key in IGNORED_LISTINGS:
            item.update(
                category="known_exception",
                reason=IGNORED_LISTINGS[key],
                registry="local",
            )
            continue
        region = regional_machines(key, machines)
        if region is not None and p["machine_status"] == "available":
            item.update(
                category="regional_links",
                reason="User-confirmed regional listing: fill missing links on existing machines only",
                machine_ids=[m["id"] for m in region],
                link_updates=[
                    {
                        "machine_id": m["id"],
                        "before_url": m["external_url"],
                        "after_url": p["external_url"],
                        "matched_candidate": m,
                    }
                    for m in region
                    if m["id"] not in pending_ids
                    and m.get("external_url") in (None, "", "null", "None")
                ],
                pending_machine_ids=[m["id"] for m in region if m["id"] in pending_ids],
            )
            continue
        if existing:
            item.update(category="represented", machine_ids=[m["id"] for m in existing])
            for machine in existing:
                if machine["machine_status"] != mapping[p["machine_status"]]:
                    disagreements.append(
                        {
                            "machine_id": machine["id"],
                            "name": machine["name"],
                            "area": machine["area"],
                            "pennyme_status": machine["machine_status"],
                            "website_status": p["machine_status"],
                            "external_url": p["external_url"],
                        }
                    )
            continue
        if any(location_key(m.get("external_url")) == key for m in deleted):
            item.update(
                category="protected_deleted",
                reason="Archived deletion already expresses PennyMe's decision; do not re-add",
            )
            item["candidates"] = [
                m for m in deleted if location_key(m.get("external_url")) == key
            ]
            continue
        if any(location_key(m.get("external_url")) == key for m in pending):
            item.update(
                category="deferred", reason="Already covered by an open change request"
            )
            continue
        if p["machine_status"] != "available":
            item.update(
                category="unavailable_unrepresented",
                reason="Not active on the website; no new machine proposed",
            )
            continue
        signature = (
            normalized(p["area"]),
            normalized(p["name"]),
            normalized(p["address"]),
        )
        evidence = evidence_for(source)
        item["evidence"] = evidence
        candidates = candidates_for(
            source, machines + deleted + pending_creates, evidence.get("geocode")
        )
        siblings = venue_keys[signature] - {key}
        candidates = [
            c
            for c in candidates
            if c.get("record_type") in {"deleted", "pending"}
            or (
                location_key(c.get("external_url")) not in siblings
                and c["id"] not in claimed_siblings[signature]
            )
        ]
        confirmed_id = CONFIRMED_IDENTITIES.get(key)
        if confirmed_id is not None:
            confirmed = [m for m in machines + deleted if m["id"] == confirmed_id]
            if not confirmed:
                item.update(
                    category="protected_deleted",
                    reason="Confirmed PennyMe identity no longer exists; do not recreate it",
                )
                continue
            strong = confirmed
        else:
            strong = sorted(
                [c for c in candidates if strong_identity(c)],
                key=lambda c: c["name_score"],
                reverse=True,
            )
        item["candidates"] = candidates
        # A distinct exact/high-similarity name can beat unrelated neighboring venues.
        if (
            len(strong) > 1
            and strong[0]["name_score"] >= 95
            and strong[0]["name_score"] - strong[1]["name_score"] >= 10
        ):
            strong = strong[:1]
        if len(strong) > 1:
            colocated = [
                c
                for c in strong
                if c.get("distance_m") is not None and c["distance_m"] <= 10
            ]
            if len(colocated) == 1:
                strong = colocated
        if len(strong) == 1:
            candidate = strong[0]
            if candidate.get("record_type") == "deleted":
                item.update(
                    category="protected_deleted",
                    reason="Confident match to an archived deletion; do not re-add",
                )
            elif (
                candidate.get("record_type") == "pending"
                or candidate["id"] in pending_ids
            ):
                item.update(
                    category="pending",
                    reason="Confident match already awaiting review in PennyMe",
                )
            elif candidate.get("external_url") not in (None, "", "null", "None"):
                item.update(
                    category="represented_by_identity",
                    reason="Confident match already has a link; preserve PennyMe's existing URL",
                    machine_ids=[candidate["id"]],
                )
            else:
                item.update(
                    category="link",
                    reason="Confident name/address or nearby name match; fill external_url only",
                    machine_id=candidate["id"],
                    before_url=candidate["external_url"],
                    after_url=p["external_url"],
                )
            item["matched_candidate"] = candidate
            if candidate.get("record_type") not in {"deleted", "pending"}:
                claimed_siblings[signature].add(candidate["id"])
            continue
        if len(strong) > 1 and all(
            c.get("record_type") not in {"deleted", "pending"}
            and c["id"] not in pending_ids
            and c.get("external_url") not in (None, "", "null", "None")
            for c in strong
        ):
            item.update(
                category="represented_by_identity",
                reason="Matching PennyMe machines already have links; preserve all app identities",
                machine_ids=[c["id"] for c in strong],
            )
            continue
        if evidence.get("error"):
            item.update(category="deferred", reason=evidence["error"])
            continue
        if len(strong) > 1:
            item.update(
                category="review",
                reason="Several PennyMe machines match; choose which identity/link to use",
                candidates=strong,
            )
            continue
        active_devices = individual_devices(evidence.get("machines", []))
        if not active_devices:
            item.update(
                category="unavailable_unrepresented",
                reason="Detail table contains no active machines",
            )
            continue
        if "latitude" not in evidence.get("geocode", {}):
            item.update(
                category="deferred",
                reason="Geocoding returned no coordinates; retry automatically",
            )
            continue
        item.update(
            category="addition",
            reason="Active source absent from SQL with no plausible existing match",
            devices=active_devices,
        )

    # Never choose one source arbitrarily when several would fill the same SQL row.
    targets = Counter(r["machine_id"] for r in records if r["category"] == "link")
    for item in records:
        if item["category"] == "link" and targets[item["machine_id"]] > 1:
            item.update(
                category="review",
                reason="Several source URLs compete for the same PennyMe machine; keep its current link unchanged",
            )
    # A specific listing takes precedence over a regional fallback. Reserve even
    # conflicted targets so the fallback cannot hide a genuine identity review.
    for item in records:
        if item["category"] == "regional_links":
            item["link_updates"] = [
                update
                for update in item["link_updates"]
                if update["machine_id"] not in targets
            ]
    return {"records": records, "status_disagreements": disagreements}


def write_report(inputs, comparison, output_dir):
    output_dir = Path(output_dir)
    counts = Counter(item["category"] for item in comparison["records"])
    additions, links, reviews, deferred = [], [], [], []
    proposed_problems = deepcopy(inputs["github"]["problems"])
    known_urls = {
        location_key(f["properties"]["external_url"])
        for f in proposed_problems["features"]
    }
    for item in comparison["records"]:
        p = item["source"]["properties"]
        base = {
            "name": p["name"],
            "area": p["area"],
            "address": p["address"],
            "external_url": p["external_url"],
        }
        if item["category"] == "addition":
            geo = item["evidence"]["geocode"]
            for device in item["devices"]:
                name = (
                    p["name"]
                    if len(item["devices"]) == 1
                    else f"{p['name']} ({device['label']})"
                )
                additions.append(
                    {
                        **base,
                        "name": name,
                        "proposed_key": location_key(p["external_url"])
                        + ":"
                        + device["label"],
                        "machine_id": None,
                        "machine_status": "available",
                        "num_coins": device["num_coins"],
                        "coin_type": device["coin_type"],
                        "latitude": geo["latitude"],
                        "longitude": geo["longitude"],
                        "geocoded_address": geo.get("reverse_address")
                        or geo.get("formatted_address"),
                        "website_updated": item["source"]["temporary"][
                            "website_updated"
                        ],
                    }
                )
        elif item["category"] in {"link", "regional_links"}:
            for update in (
                [item] if item["category"] == "link" else item["link_updates"]
            ):
                links.append(
                    {
                        **base,
                        "machine_id": update["machine_id"],
                        "pennyme_name": update["matched_candidate"]["name"],
                        "pennyme_status": update["matched_candidate"]["machine_status"],
                        "before_url": update["before_url"],
                        "after_url": update["after_url"],
                        "reason": item["reason"],
                    }
                )
        elif item["category"] in {"review", "deferred"}:
            geo = item.get("evidence", {}).get("geocode", {})
            (reviews if item["category"] == "review" else deferred).append(
                {
                    **base,
                    "category": item["category"],
                    "reason": item["reason"],
                    "latitude": geo.get("latitude"),
                    "longitude": geo.get("longitude"),
                    "geocoded_address": geo.get("formatted_address"),
                    "geocode_safe": geo.get("safe"),
                    "machine_table": json.dumps(
                        item.get("evidence", {}).get("machines", []), ensure_ascii=False
                    ),
                    "candidates": json.dumps(item["candidates"], ensure_ascii=False),
                }
            )
            if (
                item["category"] == "review"
                and location_key(p["external_url"]) not in known_urls
            ):
                problem = deepcopy(item["source"])
                problem.pop("temporary", None)
                problem["properties"]["last_updated"] = -1
                problem["problem"] = item["reason"]
                problem["candidates"] = item["candidates"]
                proposed_problems["features"].append(problem)
                known_urls.add(location_key(p["external_url"]))
    # Stable spacing avoids new pins overlapping each other or existing app pins.
    # Only proposals move; a user's existing coordinates are never touched.
    occupied = [
        (m["latitude"], m["longitude"])
        for m in inputs["database"]["machines"]
        if m.get("latitude") is not None and m.get("longitude") is not None
    ]
    for row in sorted(additions, key=lambda r: r["proposed_key"]):
        latitude, longitude = row["latitude"], row["longitude"]
        while any(
            abs(latitude - lat) < 0.001
            and abs(longitude - lon) < 0.01
            and haversine((latitude, longitude), (lat, lon), unit="m") < 10
            for lat, lon in occupied
        ):
            latitude += 10.1 / 111195
        row["latitude"] = latitude
        occupied.append((latitude, longitude))
    summary = {
        "mode": "SQL/GitHub read-only; Slack reporting separate",
        "snapshot_at": inputs["snapshot_at"],
        "sql_machines": len(inputs["database"]["machines"]),
        "source_locations": len(inputs["source"]),
        "source_categories": dict(counts),
        "proposed_machine_additions": len(additions),
        "proposed_link_additions": len(links),
        "proposed_link_removals": 0,
        "preserved_status_disagreements": len(comparison["status_disagreements"]),
        "existing_github_problems": len(inputs["github"]["problems"]["features"]),
        "proposed_new_problems": len(proposed_problems["features"])
        - len(inputs["github"]["problems"]["features"]),
        "github_commit": inputs["github"]["commit"],
    }
    report = {"summary": summary, "additions": additions, "links": links, **comparison}
    for name, data in (
        ("report.json", report),
        ("problems.proposed.json", proposed_problems),
    ):
        (output_dir / name).write_text(json.dumps(data, ensure_ascii=False, indent=2))
    for name, rows in (
        ("additions", additions),
        ("links", links),
        ("review", reviews),
        ("deferred", deferred),
        ("status_disagreements", comparison["status_disagreements"]),
    ):
        with (output_dir / f"{name}.csv").open(
            "w", newline="", encoding="utf-8"
        ) as stream:
            writer = csv.DictWriter(
                stream, fieldnames=list(rows[0]) if rows else ["no_proposals"]
            )
            writer.writeheader()
            writer.writerows(rows)
    root_text = (
        f"PennyCollector API dry run: {summary['sql_machines']:,} SQL machines compared with {summary['source_locations']:,} website locations. "
        f"Proposed: {len(additions)} individual machine additions at {counts['addition']} locations; {len(links)} missing links. "
        f"Review: {counts['review']} locations; deferred: {counts['deferred']}; known exceptions: {counts['known_exception']}. "
        f"Kept PennyMe's values for {summary['preserved_status_disagreements']} status disagreements. No changes applied."
    )
    slack_text = slack_summary(summary)
    (output_dir / "slack_preview.json").write_text(
        json.dumps(
            {
                "channel": "#pennyme_approvals",
                "root_text": slack_text,
                "thread_messages": [],
                "sent": False,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    (output_dir / "slack_preview.txt").write_text(slack_text + "\n")
    (output_dir / "planned_changes.json").write_text(
        json.dumps(
            {
                "mode": "dry-run",
                "additions": additions,
                "link_updates": [
                    {
                        "machine_id": row["machine_id"],
                        "expected_external_url": row["before_url"],
                        "set": {"external_url": row["after_url"]},
                    }
                    for row in links
                ],
                "machine_deletions": [],
                "link_removals": [],
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    lines = [
        "# PennyCollector / SQL comparison",
        "",
        root_text,
        "",
        f"SQL snapshot: {inputs['snapshot_at']}. GitHub exception lists: `{inputs['github']['branch']}` at `{inputs['github']['commit']}`.",
        "",
        "## Proposed changes",
        "",
        f"- [Individual machine additions](additions.csv): **{len(additions)}** rows at **{counts['addition']}** locations. No SQL IDs have been allocated; each row needs its own ID.",
        f"- [Missing-link additions](links.csv): **{len(links)}** existing SQL IDs. Only `external_url` would change.",
        f"- [Manual review](manual_review.md) ([CSV](review.csv)): **{len(reviews)}** competing identities, with matching SQL candidates and reasons.",
        f"- [Automatic retries](deferred.csv): **{len(deferred)}** deferred lookups; no manual coordinate verification required.",
        f"- [Status disagreements](status_disagreements.csv): **{summary['preserved_status_disagreements']}** observations, with **no status changes proposed**.",
        f"- [Proposed accumulated problems](problems.proposed.json): the original **{summary['existing_github_problems']}** entries retained verbatim, plus **{summary['proposed_new_problems']}** review candidates. Nothing pushed to GitHub.",
        "- [Slack diff preview](slack_preview.txt) and [structured payload](slack_preview.json). Delivery, when requested, is recorded in `slack_delivery.json`.",
        "- [Planned SQL changes](planned_changes.json): all proposed additions and missing-link updates; no machine deletions or link removals.",
        "- [Full audit and evidence](report.json); [input snapshot](inputs.json).",
        "",
        "## Complete source accounting",
        "",
        "| Classification | Locations |",
        "| --- | ---: |",
    ]
    lines += [f"| {key} | {value} |" for key, value in sorted(counts.items())]
    lines += [
        "",
        "## Interpretation",
        "",
        "PennyMe names, addresses, coordinates, statuses, coin counts and existing links take precedence. Archived deletions and pending creates are checked before proposing additions. Known GitHub problems and skips are suppressed. Inactive source-only locations are not added, matching the historical differ's behavior.",
        "",
        "Distinct machine numbers and distinct website IDs at one venue become separate machines. Product/design rows sharing a number collapse to one machine; unclear labels fall back to one active machine. Unknown design counts use PennyMe's default of four. Retired/book rows are excluded. New pins are spaced at least 10 m apart without moving existing app pins.",
        "",
        "Already-linked source locations count as represented. Explicit exceptions live in pennycollector_exceptions.py: Buc-ee’s 460896 is a duplicate with no action; Universal Studios 424410 fills blank links on existing machines within its fixed 1 km region and never creates machines. Specific link proposals take precedence over that regional fallback. This run does not infer additional physical machines inside those venues from aggregate design counts. That would require a separate, reliable machine-level reconciliation; no source-wide changes are applied to their existing PennyMe IDs.",
        "",
        "Geocoding is automatic; approximate/partial results are accepted and missing results retry automatically. A unique machine within 10 m matches regardless of title. Otherwise, exact name/address, 85% name similarity or a meaningful shared phrase within 250 m, or 95% name plus 80% address similarity can match. Explicit user confirmations for Basilica St. Michael and Hinterglemm are retained. Competing strong matches require review; weak neighbors do not prevent additions. PennyMe fields, populated links, archived deletions and pending changes remain authoritative.",
        "",
        "Dry runs do not apply SQL changes; use --apply with a fresh crawl to commit the plan atomically. Apply runs also refresh last_updated for app delta sync. Separate Slack diff/problem reports are sent by default; use --no-slack for local previews. The historical differ and Flask endpoint remain untouched. Unchanged outstanding problems remain visible in the counts but are not repeatedly posted in detail; GitHub's known problems remain permanent suppressions.",
        "",
    ]

    def cell(value):
        return (
            str(value if value is not None else "")
            .replace("|", "\\|")
            .replace("\n", " ")
        )

    lines += [
        "## All proposed additions",
        "",
        "| Machine | Area | Designs / type | Coordinates | Source |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in additions:
        lines.append(
            f"| {cell(row['name'])} | {cell(row['area'])} | {row['num_coins']} {cell(row['coin_type'])} | {row['latitude']:.6f}, {row['longitude']:.6f} | [Location]({row['external_url']}) |"
        )
    lines += [
        "",
        "## All proposed missing links",
        "",
        "Only the link changes; the listed PennyMe status is retained.",
        "",
        "| SQL ID | PennyMe name | Area | Status retained | Proposed link |",
        "| ---: | --- | --- | --- | --- |",
    ]
    for row in links:
        lines.append(
            f"| {row['machine_id']} | {cell(row['pennyme_name'])} | {cell(row['area'])} | {cell(row['pennyme_status'])} | [Location]({row['after_url']}) |"
        )
    review_start = len(lines)
    lines += [
        "",
        "## Cases needing review",
        "",
        "Only competing identities need manual input. Geocoding/detail failures retry automatically and are listed separately in deferred.csv. Review cases enter the permanent problems registry only after a decision.",
        "",
        "| Source location | Area | Disposition | Evidence / reason |",
        "| --- | --- | --- | --- |",
    ]
    for row in reviews:
        candidates = json.loads(row["candidates"])
        names = "; ".join(
            f"{c.get('record_type', 'SQL')} #{c['id']}: {c['name']}" for c in candidates
        )
        reason = row["reason"] + (". Candidates: " + names if names else "")
        lines.append(
            f"| [{cell(row['name'])}]({row['external_url']}) | {cell(row['area'])} | {row['category']} | {cell(reason)} |"
        )
    (output_dir / "report.md").write_text("\n".join(lines))
    (output_dir / "manual_review.md").write_text(
        f"# Manual review: {len(reviews)} locations\n\n"
        + "Coordinate lookup is automatic. This list reflects the comparison before any optional apply step.\n"
        + "\n".join(lines[review_start:])
        + "\n"
    )
    return summary


def slack_summary(summary, application=None):
    """API records are venue listings: one can contain several physical machines."""
    sql_count = (
        application["sql_machines_after"] if application else summary["sql_machines"]
    )
    text = (
        f"Screened {summary['source_locations']:,} PennyCollector listings; "
        f"SQL: {sql_count:,} machines.\n"
    )
    if application:
        return text + (
            f"Applied: {len(application['machines_added'])} machines added; "
            f"{len(application['links_added'])} links added; links removed from 0 machines."
        )
    return text + (
        f"Dry run: {summary['proposed_machine_additions']} machines to add; "
        f"{summary['proposed_link_additions']} links to add; "
        f"links to remove from {summary['proposed_link_removals']} machines."
    )


def apply_report(inputs, report, db_login=BACKEND / "db_login.json"):
    """Commit the freshly calculated plan atomically, or change no machine rows.

    The short table locks protect even against writers that don't use this script.
    All network crawling/geocoding happens before the transaction starts.
    """
    credentials = json.loads(Path(db_login).read_text())
    connection = psycopg2.connect(**credentials, connect_timeout=15)
    receipt = {"status": "applied", "machines_added": [], "links_added": []}
    try:
        connection.set_session(readonly=False, isolation_level="READ COMMITTED")
        with connection.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute("SET LOCAL lock_timeout = '5s'")
            cursor.execute("SET LOCAL statement_timeout = '30s'")
            cursor.execute(
                "LOCK TABLE machines, deleted_machines, pending_changes "
                "IN SHARE ROW EXCLUSIVE MODE"
            )
            current = json.loads(json.dumps(database_snapshot(cursor), default=str))
            if current != inputs["database"]:
                raise RuntimeError(
                    "SQL changed during the crawl; nothing applied. Rerun with a fresh output directory."
                )
            used_ids = {
                m["id"]
                for table in ("machines", "deleted_machines")
                for m in current[table]
            }
            pending_ids = {p["machine_id"] for p in current["pending_changes"]}
            by_id = {m["id"]: m for m in current["machines"]}
            for link in report["links"]:
                mid = link["machine_id"]
                if mid in pending_ids or by_id[mid]["external_url"] not in (
                    None,
                    "",
                    "null",
                    "None",
                ):
                    raise ValueError(
                        f"Machine {mid} is no longer eligible for a missing link"
                    )
                cursor.execute(
                    "UPDATE machines SET external_url = %s, last_updated = CURRENT_DATE "
                    "WHERE id = %s AND external_url IS NOT DISTINCT FROM %s RETURNING id",
                    (link["after_url"], mid, link["before_url"]),
                )
                if not cursor.fetchone():
                    raise RuntimeError(
                        f"Machine {mid} changed; rolling back the full plan"
                    )
                receipt["links_added"].append(mid)
            for row in report["additions"]:
                cursor.execute(
                    "INSERT INTO machines (name, area, address, geom, machine_status, "
                    "status, num_coins, paywall, external_url, internal_url, last_updated) "
                    "VALUES (%s, %s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326), "
                    "'available', 'unvisited', %s, FALSE, %s, NULL, CURRENT_DATE) RETURNING id",
                    (
                        row["name"],
                        row["area"],
                        row["geocoded_address"] or row["address"],
                        row["longitude"],
                        row["latitude"],
                        row["num_coins"],
                        row["external_url"],
                    ),
                )
                mid = cursor.fetchone()["id"]
                if mid in used_ids:
                    raise RuntimeError(
                        "Database ID sequence would reuse an existing or archived ID; rolling back"
                    )
                used_ids.add(mid)
                receipt["machines_added"].append(
                    {"machine_id": mid, "proposed_key": row["proposed_key"]}
                )
            receipt["sql_machines_before"] = len(current["machines"])
            receipt["sql_machines_after"] = len(current["machines"]) + len(
                receipt["machines_added"]
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    receipt["committed_at"] = datetime.now(timezone.utc).isoformat()
    return receipt


def record_application(output_dir, receipt):
    """Persist the commit receipt before Slack, so delivery can be retried alone."""
    output_dir = Path(output_dir)
    (output_dir / "apply_result.json").write_text(json.dumps(receipt, indent=2))
    report = json.loads((output_dir / "report.json").read_text())
    preview = json.loads((output_dir / "slack_preview.json").read_text())
    preview.update(root_text=slack_summary(report["summary"], receipt), sent=False)
    (output_dir / "slack_preview.json").write_text(json.dumps(preview, indent=2))
    (output_dir / "slack_preview.txt").write_text(preview["root_text"] + "\n")
    path = output_dir / "report.md"
    path.write_text(
        "# Applied successfully\n\n"
        + preview["root_text"]
        + "\n\nSee [commit receipt](apply_result.json) for allocated SQL IDs. "
        "The comparison below records the plan before applying it.\n\n"
        + path.read_text()
    )


def problem_signature(item):
    """Ignore changing timestamps and tiny geocode drift when suppressing repeats."""
    p = item["source"]["properties"]
    identity = {
        "name": p["name"],
        "area": p["area"],
        "address": p["address"],
        "reason": item["reason"],
        "category": item["category"],
        "candidates": sorted(
            (
                str(c["id"]),
                c.get("record_type", "SQL"),
                c["name"],
                c.get("external_url") or "",
            )
            for c in item["candidates"]
        ),
        "machines": item.get("evidence", {}).get("machines", []),
    }
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def send_slack_reports(
    output_dir, state_path, channel="#pennyme_approvals", client=None
):
    """Send counts plus new/changed problems, remembering successful deliveries.

    Unresolved cases stay in the local report. A repeat notification is not a
    resolution, and this ledger never changes the GitHub exception registry.
    """
    output_dir, state_path = Path(output_dir), Path(state_path)
    report = json.loads((output_dir / "report.json").read_text())
    diff = json.loads((output_dir / "slack_preview.json").read_text())
    cases = {
        location_key(r["source"]["properties"]["external_url"]): r
        for r in report["records"]
        if r["category"] == "review"
    }
    signatures = {key: problem_signature(value) for key, value in cases.items()}
    fingerprint = hashlib.sha256(
        json.dumps(
            {
                "summary": report["summary"],
                "links": report["links"],
                "additions": report["additions"],
                "problems": signatures,
                "diff_text": diff["root_text"],
            },
            sort_keys=True,
        ).encode()
    ).hexdigest()
    ledger = json.loads(state_path.read_text()) if state_path.exists() else {}
    state = ledger.setdefault(channel, {"cases": {}, "runs": {}})
    run = state["runs"].setdefault(fingerprint, {})
    if run.get("complete"):
        diff.update(sent=True, channel=channel, ts=run["diff_ts"])
        (output_dir / "slack_preview.json").write_text(
            json.dumps(diff, ensure_ascii=False, indent=2)
        )
        (output_dir / "slack_delivery.json").write_text(json.dumps(run, indent=2))
        return {**run, "already_sent": True}
    changed = [key for key in cases if state["cases"].get(key) != signatures[key]]
    text = (
        f"PennyCollector problem report: {len(changed)} new or changed; "
        f"{len(cases)} unresolved identity cases. Unchanged cases are not repeated."
    )

    def escape(value):
        return (
            str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        )

    chunks, keys, lines = [], [], []
    for key in changed:
        item = cases[key]
        p = item["source"]["properties"]
        candidates = "; ".join(
            f"{c.get('record_type', 'SQL')} #{c['id']} {c['name']}"
            for c in item["candidates"]
        )
        line = f"<{p['external_url']}|{escape(p['name'])}> ({escape(p['area'])}): {escape(item['reason'])}"
        if candidates:
            line += " Candidates: " + escape(candidates)
        # Each location is at most one compact paragraph; all evidence stays local.
        line = line[:2700]
        if lines and len("\n\n".join(lines + [line])) > 3000:
            chunks.append((keys, "\n\n".join(lines)))
            keys, lines = [], []
        keys.append(key)
        lines.append(line)
    if lines:
        chunks.append((keys, "\n\n".join(lines)))
    (output_dir / "problem_slack_preview.json").write_text(
        json.dumps(
            {
                "channel": channel,
                "root_text": text,
                "thread_messages": [body for _, body in chunks],
                "new_or_changed": len(changed),
                "unresolved": len(cases),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    (output_dir / "problem_slack_preview.txt").write_text(
        text + "\n\n" + "\n\n".join(body for _, body in chunks)
    )
    if client is None:
        client = WebClient(token=os.environ["SLACK_TOKEN"])

    def save():
        state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(ledger, indent=2))
        temporary.replace(state_path)

    def post(body, **kwargs):
        response = client.chat_postMessage(
            channel=channel,
            text=body,
            username="PennyMe",
            unfurl_links=False,
            unfurl_media=False,
            **kwargs,
        )
        if not response.get("ok"):
            raise RuntimeError("Slack did not confirm delivery")
        time.sleep(1.1)
        return response["ts"]

    if "diff_ts" not in run:
        run["diff_ts"] = post(diff["root_text"])
        save()
    if "problem_ts" not in run:
        run["problem_ts"] = post(text)
        save()
    for keys, body in chunks:
        post(body, thread_ts=run["problem_ts"])
        for key in keys:
            state["cases"][key] = signatures[key]
        save()
    state["cases"] = signatures
    run.update(complete=True, new_or_changed=len(changed), unresolved=len(cases))
    save()
    diff.update(sent=True, channel=channel, ts=run["diff_ts"])
    (output_dir / "slack_preview.json").write_text(
        json.dumps(diff, ensure_ascii=False, indent=2)
    )
    (output_dir / "slack_delivery.json").write_text(json.dumps(run, indent=2))
    return run


def main():
    load_dotenv(BACKEND / ".env")
    load_dotenv(BACKEND.parent / ".env")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--apply",
        action="store_true",
        help="Commit new machines and missing links to SQL",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="Plan changes without SQL writes (default)",
    )
    mode.add_argument(
        "--send-report",
        action="store_true",
        help="Send/retry an existing report only; never touch SQL",
    )
    parser.add_argument(
        "--no-slack",
        action="store_true",
        help="Generate local reports without sending Slack notifications",
    )
    parser.add_argument(
        "--slack-state",
        type=Path,
        default=BACKEND.parent / "reports/location_differ/slack_state.json",
        help="Persistent notification ledger shared across daily report directories",
    )
    parser.add_argument(
        "--reuse-inputs",
        action="store_true",
        help="Re-evaluate the saved read-only SQL/API snapshot",
    )
    parser.add_argument(
        "--geocode",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Automatically geocode with GCLOUD_KEY (default); --no-geocode reuses cached coordinates",
    )
    args = parser.parse_args()
    if args.apply and args.reuse_inputs:
        parser.error("--apply requires a fresh crawl; --reuse-inputs is dry-run only")
    if (args.send_report or args.reuse_inputs) and args.output_dir is None:
        parser.error("--send-report / --reuse-inputs requires --output-dir")
    if args.output_dir is None:
        args.output_dir = (
            BACKEND.parent
            / "reports/location_differ"
            / datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S-%fZ")
        )
    if args.send_report:
        if args.no_slack:
            parser.error("--send-report cannot be combined with --no-slack")
        receipt_path = args.output_dir / "apply_result.json"
        if receipt_path.exists():
            # Recover even if the process stopped after saving the commit receipt.
            receipt = json.loads(receipt_path.read_text())
            report = json.loads((args.output_dir / "report.json").read_text())
            preview_path = args.output_dir / "slack_preview.json"
            preview = json.loads(preview_path.read_text())
            preview["root_text"] = slack_summary(report["summary"], receipt)
            preview_path.write_text(json.dumps(preview, indent=2))
        print(
            json.dumps(send_slack_reports(args.output_dir, args.slack_state), indent=2)
        )
        return
    if (args.output_dir / "apply_result.json").exists():
        parser.error(
            "This directory contains an applied run; use --send-report or a fresh directory"
        )
    if not args.reuse_inputs and (args.output_dir / "inputs.json").exists():
        parser.error(
            "Use a fresh --output-dir, or --reuse-inputs for a read-only replay"
        )
    if not args.no_slack and not os.environ.get("SLACK_TOKEN"):
        parser.error("Set SLACK_TOKEN or pass --no-slack")
    print(f"Report directory: {args.output_dir}")
    inputs = (
        json.loads((args.output_dir / "inputs.json").read_text())
        if args.reuse_inputs
        else fetch_inputs(args.output_dir)
    )
    evidence = SourceEvidence(args.output_dir, geocode=args.geocode)
    try:
        comparison = compare(inputs, evidence.get)
        summary = write_report(inputs, comparison, args.output_dir)
        print(json.dumps(summary, indent=2))
        if args.apply:
            report = json.loads((args.output_dir / "report.json").read_text())
            receipt = apply_report(inputs, report)
            record_application(args.output_dir, receipt)
            print(json.dumps(receipt, indent=2))
        if not args.no_slack:
            send_slack_reports(args.output_dir, args.slack_state)
    finally:
        evidence.session.close()


if __name__ == "__main__":
    main()
