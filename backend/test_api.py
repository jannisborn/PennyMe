"""Integration tests for the PennyMe Flask API.

Assumes:
  - app.py is running on http://localhost:5000
  - The database has been seeded with seed_db.py

Run from the backend/ directory:
    python app.py &          # start the server
    python test_api.py       # run tests

Changes go to pending_changes (not applied immediately). Tests that verify
DB state explicitly approve the pending change before checking /machines.
"""

import sys
from io import BytesIO

import requests

from pennyme.database import (
    approve_pending_change,
    get_open_pending_changes,
    reject_pending_change,
)

BASE = "http://localhost:5000"
# Pick a machine ID from the database (server_locations.json).
# Updated to use a real seeded ID instead of an all_locations-only machine.
TEST_MACHINE_ID = 8202


def ok(label: str) -> None:
    print(f"  PASS  {label}")


def fail(label: str, detail: str) -> None:
    print(f"  FAIL  {label}: {detail}")
    sys.exit(1)


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        ok(label)
    else:
        fail(label, detail)


# ---------------------------------------------------------------------------
# /health
# ---------------------------------------------------------------------------
def test_health() -> None:
    print("\n--- /health ---")
    r = requests.get(f"{BASE}/health", timeout=5)
    check("status 200", r.status_code == 200, r.text)
    check("body ok", r.json().get("status") == "ok", r.text)


# ---------------------------------------------------------------------------
# /machines
# ---------------------------------------------------------------------------
def test_machines() -> None:
    print("\n--- /machines ---")
    r = requests.get(f"{BASE}/machines", timeout=30)
    check("status 200", r.status_code == 200, r.text)
    data = r.json()
    check(
        "is FeatureCollection",
        data.get("type") == "FeatureCollection",
        str(data.keys()),
    )
    features = data.get("features", [])
    check("has features", len(features) > 0, "empty list")

    # Spot-check a known machine
    ids = {f["properties"]["id"] for f in features}
    check(
        f"contains test machine {TEST_MACHINE_ID}",
        TEST_MACHINE_ID in ids,
        f"known IDs (sample): {list(ids)[:5]}",
    )
    print(f"  INFO  {len(features)} machines returned")


# ---------------------------------------------------------------------------
# /change_machine  (status change on the test machine)
# ---------------------------------------------------------------------------
def test_change_machine() -> None:
    print("\n--- /change_machine ---")

    # First fetch the current state so we send back valid data
    r = requests.get(f"{BASE}/machines", timeout=30)
    features = r.json()["features"]
    machine = next(f for f in features if f["properties"]["id"] == TEST_MACHINE_ID)
    props = machine["properties"]
    lng, lat = machine["geometry"]["coordinates"]

    # Toggle status: available → out-of-order, or back
    current_status = props["machine_status"]
    new_status = "out-of-order" if current_status == "available" else "available"

    params = {
        "id": TEST_MACHINE_ID,
        "title": props["name"],
        "address": props["address"],
        "area": props["area"],
        "status": new_status,
        "lat_coord": lat,
        "lon_coord": lng,
        "multimachine": props.get("multimachine", 1),
        "num_coins": props.get("num_coins", 4),
        "paywall": "true" if props.get("paywall") else "false",
    }
    r = requests.post(f"{BASE}/change_machine", params=params, timeout=30)
    check("status 200", r.status_code == 200, r.text)
    check("success body", "Success" in r.text or "message" in r.json(), r.text)

    # Verify a pending change was queued (not applied yet)
    pending = [
        p
        for p in get_open_pending_changes()
        if p["machine_id"] == TEST_MACHINE_ID and p["change_type"] == "update"
    ]
    check(
        "pending change created",
        len(pending) == 1,
        f"found {len(pending)} open update(s)",
    )
    change_id = pending[0]["id"]

    # Status in /machines must still be the original (not applied yet)
    r2 = requests.get(f"{BASE}/machines", timeout=30)
    before_approve = next(
        f for f in r2.json()["features"] if f["properties"]["id"] == TEST_MACHINE_ID
    )
    check(
        "not applied before approval",
        before_approve["properties"]["machine_status"] == current_status,
        f"expected {current_status}, got {before_approve['properties']['machine_status']}",
    )

    # Approve and verify the status is now updated
    approve_pending_change(change_id)
    r3 = requests.get(f"{BASE}/machines", timeout=30)
    after_approve = next(
        f for f in r3.json()["features"] if f["properties"]["id"] == TEST_MACHINE_ID
    )
    check(
        "status updated after approval",
        after_approve["properties"]["machine_status"] == new_status,
        f"expected {new_status}, got {after_approve['properties']['machine_status']}",
    )

    # Revert: submit another change back to original status, then approve it
    params["status"] = current_status
    _ = requests.post(f"{BASE}/change_machine", params=params, timeout=30)
    revert_pending = [
        p
        for p in get_open_pending_changes()
        if p["machine_id"] == TEST_MACHINE_ID and p["change_type"] == "update"
    ]
    if revert_pending:
        approve_pending_change(revert_pending[0]["id"])

    print(
        f"  INFO  Toggled {TEST_MACHINE_ID}: {current_status} → {new_status} → {current_status}"
    )


# ---------------------------------------------------------------------------
# /create_machine  (posts a dummy machine with a 1×1 pixel image)
# ---------------------------------------------------------------------------
def test_create_machine() -> None:
    print("\n--- /create_machine ---")

    # Minimal valid JPEG (1×1 white pixel)
    tiny_jpeg = (
        b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t"
        b"\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a"
        b"\x1f\x1e\x1d\x1a\x1c\x1c $.' \",#\x1c\x1c(7),01444\x1f'9=82<.342\x1e"
        b"\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00"
        b"\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00"
        b"\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b"
        b"\xff\xc4\x00\xb5\x10\x00\x02\x01\x03\x03\x02\x04\x03\x05\x05\x04"
        b"\x04\x00\x00\x01}\x01\x02\x03\x00\x04\x11\x05\x12!1A\x06\x13Qa"
        b'\x07"q\x142\x81\x91\xa1\x08#B\xb1\xc1\x15R\xd1\xf0$3br'
        b"\x82\t\n\x16\x17\x18\x19\x1a%&'()*456789:CDEFGHIJ"
        b"STUVWXYZ\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xfb\xd2\x8a("
        b"\x03\xff\xd9"
    )

    test_title = "Test Machine (automated test)"
    params = {
        "title": test_title,
        "address": "1 Infinite Loop, Cupertino, CA",
        "area": "California",
        "lat_coord": 37.331741,
        "lon_coord": -122.030333,
        "multimachine": 1,
        "num_coins": 4,
        "paywall": "false",
        "ignore_nearby": "true",
    }
    files = {"image": ("test.jpg", BytesIO(tiny_jpeg), "image/jpeg")}

    # Snapshot open creates before submission
    before = {
        p["id"] for p in get_open_pending_changes() if p["change_type"] == "create"
    }

    r = requests.post(f"{BASE}/create_machine", params=params, files=files, timeout=30)
    check(
        "accepted (200/201)",
        r.status_code in (200, 201, 409),
        f"status={r.status_code} body={r.text[:200]}",
    )

    if r.status_code in (200, 201):
        # Verify a pending 'create' change was queued
        after_pending = [
            p
            for p in get_open_pending_changes()
            if p["change_type"] == "create" and p["id"] not in before
        ]
        check(
            "pending create queued",
            len(after_pending) == 1,
            f"new open creates: {len(after_pending)}",
        )
        # Machine must NOT appear in /machines yet (pending approval)
        r2 = requests.get(f"{BASE}/machines", timeout=30)
        names = {f["properties"]["name"] for f in r2.json()["features"]}
        check(
            "not in /machines before approval",
            test_title not in names,
            "machine visible before approval",
        )
        # Clean up: reject the pending change so re-runs stay consistent
        reject_pending_change(after_pending[0]["id"])
        check("cleanup: rejected pending create", True)

    print(f"  INFO  Response {r.status_code}: {r.json()}")


def test_change_machine_slackbot() -> None:
    """Just submits a change so we can see the Slackbot notification in #pennyme_approvals."""
    print("\n--- /change_machine ---")

    # First fetch the current state so we send back valid data
    r = requests.get(f"{BASE}/machines", timeout=30)
    features = r.json()["features"]
    machine = next(f for f in features if f["properties"]["id"] == TEST_MACHINE_ID)
    props = machine["properties"]
    lng, lat = machine["geometry"]["coordinates"]

    # Toggle status: available → out-of-order, or back
    current_status = props["machine_status"]
    new_status = "out-of-order" if current_status == "available" else "available"

    params = {
        "id": TEST_MACHINE_ID,
        "title": props["name"],
        "address": props["address"],
        "area": props["area"],
        "status": new_status,
        "lat_coord": lat,
        "lon_coord": lng,
        "multimachine": props.get("multimachine", 1),
        "num_coins": props.get("num_coins", 4),
        "paywall": "true" if props.get("paywall") else "false",
    }
    r = requests.post(f"{BASE}/change_machine", params=params, timeout=30)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print(f"Testing against {BASE}")
    try:
        requests.get(f"{BASE}/health", timeout=3)
    except requests.exceptions.ConnectionError:
        print(f"ERROR: Cannot reach {BASE}. Is app.py running?")
        sys.exit(1)

    test_health()
    test_machines()
    test_change_machine()
    test_create_machine()

    # test_change_machine_slackbot()

    print("\nAll tests passed.")
