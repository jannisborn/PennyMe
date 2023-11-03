import json
import os
import sys

root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
try:
    with open(os.path.join(root_dir, "data", "server_locations.json"), "r") as f:
        data = json.load(f)
except Exception as e:
    print('FAILURE!', e)
    sys.exit(1)

try:
    with open(os.path.join(root_dir, "data", "all_locations.json"), "r") as f:
        data = json.load(f)
except Exception as e:
    sys.exit(1)
print('SUCCESS!')
sys.exit(0)

