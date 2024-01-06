import json
import os

SERVER_PATH = os.path.join("data", "server_locations.json")
ALL_PATH = os.path.join("data", "all_locations.json")

if __name__ == "__main__":
    # load both files
    with open(SERVER_PATH, "r", encoding="latin-1") as infile:
        server_locs = json.load(infile)
    with open(ALL_PATH, "r", encoding="latin-1") as infile:
        all_locs = json.load(infile)

    # get all IDs that exist in the all_locations already
    all_ids = [a["properties"]["id"] for a in all_locs["features"]]
    # make a mapping from ID to list index
    all_id_mapping = {
        a["properties"]["id"]: i for i, a in enumerate(all_locs["features"])
    }

    # iterate over machines in server locations
    for machine_entry in server_locs["features"]:
        machine_id = machine_entry["properties"]["id"]
        # if the ID already exists in the all_locations, update the entry
        if machine_id in all_ids:
            all_locs["features"][all_id_mapping[machine_id]]["properties"].update(
                machine_entry["properties"]
            )
            all_locs["features"][all_id_mapping[machine_id]]["geometry"].update(
                machine_entry["geometry"]
            )
        # if the ID does not exist in all_locations, append
        else:
            all_locs["features"].append(machine_entry)

    with open(ALL_PATH, "w", encoding="latin-1") as outfile:
        json.dump(all_locs, outfile, indent=4, ensure_ascii=False)
