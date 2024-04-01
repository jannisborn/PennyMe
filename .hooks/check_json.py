import json
import os
import sys

root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
try:
    with open(os.path.join(root_dir, "data", "server_locations.json"), "r") as f:
        data = json.load(f)

    ids = [e["properties"]["id"] for e in data["features"]]
    if not len(ids) == len(set(ids)):
        raise ValueError(
            f"Duplicate entries in server_locations {len(ids)} and {len(set(ids))}"
        )
except Exception as e:
    print("FAILURE!", e)
    sys.exit(1)

try:
    with open(os.path.join(root_dir, "data", "all_locations.json"), "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"Failure with {e}")
    sys.exit(1)
print("SUCCESS!")
sys.exit(0)
