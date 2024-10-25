import json
import os
import sys
from typing import Any, Dict, List


def check_data(data: List[Dict[str, Any]], name: str):
    for x in data["features"]:
        assert isinstance(
            x["properties"]["latitude"], str
        ), f"In {name} file did not find str for coordinates for ID = {x['properties']['id']}"
        assert isinstance(
            x["properties"]["longitude"], str
        ), f"In {name} file did not find str for coordinates for ID = {x['properties']['id']}"
        assert isinstance(
            x["geometry"]["coordinates"][0], float
        ), f"In {name} file did not find float for coordinates for ID = {x['properties']['id']}"
        assert isinstance(
            x["geometry"]["coordinates"][1], float
        ), f"In {name} file did not find float for coordinates for ID = {x['properties']['id']}"


root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
try:
    with open(os.path.join(root_dir, "data", "server_locations.json"), "r") as f:
        data = json.load(f)

    check_data(data, name="server locations")
    ids = [e["properties"]["id"] for e in data["features"]]
    if not len(ids) == len(set(ids)):
        raise ValueError(
            f"Duplicate entries in server_locations {len(ids)} and {len(set(ids))}"
        )
except Exception as e:
    print(f"Data is corrupted: {e}")
    sys.exit(1)

try:
    with open(os.path.join(root_dir, "data", "all_locations.json"), "r") as f:
        data = json.load(f)
        check_data(data, name="all locations")
except Exception as e:
    print(f"Data is corrupted: {e}")
    sys.exit(1)
print("SUCCESS!")
sys.exit(0)
