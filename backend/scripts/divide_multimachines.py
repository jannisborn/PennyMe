import json
import numpy as np

# open files
with open("data/all_locations.json", "r") as f:
    all_locs = json.load(f)

server_file = "data/server_locations.json"

with open(server_file, "r") as f:
    ser_locs = json.load(f)

ls, la = len(ser_locs["features"]), len(all_locs["features"])
print(f"All locations has {la} entries, server locations {ls}")


def get_highest_id():
    ids = [s["properties"]["id"] for s in ser_locs["features"]] + [
        s["properties"]["id"] for s in all_locs["features"]
    ]
    return max(ids)


EARTH_R = 6_371_000.0  # meters


def wrap_lon(lon_deg: float) -> float:
    # wrap to [-180, 180)
    return ((lon_deg + 180.0) % 360.0) - 180.0


def clamp_lat(lat_deg: float) -> float:
    return float(np.clip(lat_deg, -90.0, 90.0))


def jitter_lonlat(lon, lat, radius_m=20.0, rng=None):
    rng = np.random.default_rng(rng)

    theta = rng.uniform(0.0, 2 * np.pi)
    r = radius_m * np.sqrt(rng.uniform(0.0, 1.0))

    dx = r * np.cos(theta)  # meters east
    dy = r * np.sin(theta)  # meters north

    lat_rad = np.deg2rad(lat)
    dlat = (dy / EARTH_R) * (180.0 / np.pi)

    # Guard against cos(lat)=0 near poles
    coslat = np.cos(lat_rad)
    if abs(coslat) < 1e-12:
        dlon = 0.0
    else:
        dlon = (dx / (EARTH_R * coslat)) * (180.0 / np.pi)

    lon2 = wrap_lon(lon + dlon)
    lat2 = clamp_lat(lat + dlat)
    return lon2, lat2


def fix_strings(text):
    if text == "several - unknown ":
        return 1
    if text == ".":
        return 1
    try:
        num = int(text)
        return num
    except ValueError:
        return int(text[0])


new_multimachines = []

next_id = get_highest_id() + 1

MAX_MACHINES = 5

# TODO: change for all locations -> just process all_locs and ser-locs seperately? in all locs, skip the ones
new_ser_locs = []
#  TODO: for all locations, comment out so that it excludes the machines that were already done in the server locations
modified_server_location_ids = []

for machine in ser_locs["features"]:  # TODO: change for all locations
    # TODO: this is already fine for all locations -> does not diversify (1 -> 3) the machines that were already done in server locations
    if (
        machine["properties"].get("multimachine")
        and machine["properties"]["id"] not in modified_server_location_ids
    ):
        machine_num_as_int = fix_strings(machine["properties"].get("multimachine"))

        # track IDs appearing in server locations file, so they don't appear again in all locations
        modified_server_location_ids.append(machine["properties"]["id"])

        if machine_num_as_int > 1:
            machine["properties"]["multimachine"] = 1

        for counter in range(machine_num_as_int - 1):
            # copy properties dict
            new_properties = machine["properties"].copy()
            new_properties["id"] = next_id
            # new_properties['multimachine'] = 1
            new_properties["name"] = machine["properties"]["name"] + f" ({counter+2})"
            next_id += 1

            # jitter coordinates
            old_coords = np.array(machine["geometry"]["coordinates"])
            new_coords = jitter_lonlat(*old_coords)
            new_dict = {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": list(new_coords)},
                "properties": new_properties,
            }
            # append to new machines
            new_multimachines.append(new_dict)

            if counter > MAX_MACHINES:
                break
        new_ser_locs.append(machine)

        # # Debugging: only process one machine
        # if machine_num_as_int > 1:
        #     break
