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
    if text in [".", "?", "1x3 prints (I only got 2/3)"]:
        return 1
    try:
        num = int(text)
        return num
    except ValueError:
        breakpoint()
        return int(text[0])


def set_coords_in_properties(props, lon, lat):
    # Update only fields that already exist (keeps schema stable)
    if (
        "coordinates" in props
        and isinstance(props["coordinates"], (list, tuple))
        and len(props["coordinates"]) == 2
    ):
        props["coordinates"] = [float(lon), float(lat)]

    if "lon" in props:
        props["lon"] = float(lon)
    if "lng" in props:
        props["lng"] = float(lon)
    if "longitude" in props:
        props["longitude"] = float(lon)

    if "lat" in props:
        props["lat"] = float(lat)
    if "latitude" in props:
        props["latitude"] = float(lat)


def assert_unique_ids(features, label):
    ids = [f["properties"]["id"] for f in features]
    if len(ids) != len(set(ids)):
        from collections import Counter

        dupes = [k for k, v in Counter(ids).items() if v > 1]
        raise ValueError(
            f"{label}: duplicate IDs found (showing up to 20): {dupes[:20]}"
        )


def split_multimachines(
    features, *, next_id, ids_to_skip, already_split_ids, jitter_radius_m, max_machines
):
    """
    - Removes 'multimachine' from the source machine if present.
    - If multimachine > 1 and ID not skipped and not already split in this pass:
        creates (n-1) new machines with new IDs and jittered coords.
    Returns: (new_features, new_machines, next_id, split_ids)
    """
    new_features = []
    new_machines = []
    split_ids = []

    for machine in features:
        # Fail fast if schema is off
        props = machine["properties"]
        mid = props["id"]
        name = props["name"]

        # Always remove the multimachine field if present (dissolve the concept)
        if "multimachine" in props:
            mm = props["multimachine"]
            del props["multimachine"]
        else:
            mm = None

        if mm is not None and mid not in ids_to_skip and mid not in already_split_ids:
            machine_num_as_int = fix_strings(mm)

            if machine_num_as_int > 1:
                already_split_ids.add(mid)
                split_ids.append(mid)

                old_coords = machine["geometry"]["coordinates"]  # [lon, lat]
                # (optional) keep properties coords consistent for the original if it has such fields
                set_coords_in_properties(props, old_coords[0], old_coords[1])

                total = min(machine_num_as_int, max_machines)
                for k in range(2, total + 1):
                    # copy properties dict
                    new_properties = props.copy()
                    new_properties["id"] = next_id
                    new_properties["name"] = name + f" * Machine {k}"
                    next_id += 1

                    # jitter coordinates (deterministic per (orig_id, machine_index))
                    new_coords = jitter_lonlat(
                        old_coords[0],
                        old_coords[1],
                        radius_m=jitter_radius_m,
                        rng=(mid * 1000 + k),
                    )
                    set_coords_in_properties(
                        new_properties, new_coords[0], new_coords[1]
                    )

                    new_dict = {
                        "type": "Feature",
                        "geometry": {"type": "Point", "coordinates": list(new_coords)},
                        "properties": new_properties,
                    }
                    new_machines.append(new_dict)

        new_features.append(machine)

    return new_features, new_machines, next_id, split_ids


new_multimachines = []

next_id = get_highest_id() + 1

MAX_MACHINES = 5

# ---------------------- PASS 1: server locations ----------------------
# Split multimachines here, but do NOT add new machines to server file (keep server minimal).
server_before = len(ser_locs["features"])
server_already_split = set()
server_ids_to_skip = set()

new_ser_locs, server_new_machines_for_all, next_id, server_split_ids = (
    split_multimachines(
        ser_locs["features"],
        next_id=next_id,
        ids_to_skip=server_ids_to_skip,
        already_split_ids=server_already_split,
        jitter_radius_m=15.0,
        max_machines=MAX_MACHINES,
    )
)

ser_locs["features"] = new_ser_locs
server_after = len(ser_locs["features"])

# Any ID split in server should not be split again in all_locations.
modified_server_location_ids = set(server_split_ids)

# ---------------------- PASS 2: all locations ----------------------
all_before = len(all_locs["features"])
all_already_split = set()

new_all_locs, all_new_machines, next_id, all_split_ids = split_multimachines(
    all_locs["features"],
    next_id=next_id,
    ids_to_skip=modified_server_location_ids,
    already_split_ids=all_already_split,
    jitter_radius_m=15.0,
    max_machines=MAX_MACHINES,
)

# Add ALL new machines to all_locations (including those originating from server_locations splitting)
all_locs["features"] = new_all_locs + server_new_machines_for_all + all_new_machines
all_after = len(all_locs["features"])

# ---------------------- VALIDATION + STATS ----------------------
assert_unique_ids(ser_locs["features"], "server_locations")
assert_unique_ids(all_locs["features"], "all_locations")

n_split_ids_total = len(set(server_split_ids) | set(all_split_ids))
n_new_machines_total = len(server_new_machines_for_all) + len(all_new_machines)

print(
    f"Split {n_split_ids_total} IDs total ({len(server_split_ids)} from server, {len(all_split_ids)} from all)"
)
print(f"Added {n_new_machines_total} new machines total")
print(f"Server locations: {server_before} -> {server_after} features (kept minimal)")
print(f"All locations:    {all_before} -> {all_after} features")

# ---------------------- WRITE BACK ----------------------
with open("data/all_locations_new.json", "w") as f:
    json.dump(all_locs, f, ensure_ascii=False, indent=4)

with open(server_file.replace(".json", "_new.json"), "w") as f:
    json.dump(ser_locs, f, ensure_ascii=False, indent=4)

print("Wrote updated files: data/all_locations.json and data/server_locations.json")
