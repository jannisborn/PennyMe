"""User-confirmed catalogue exceptions, isolated from general identity matching.

GitHub problems/skip remain the permanent exclusion lists. These local rules
express positive matches or special catalogue semantics, not inferred matches.
"""

from haversine import haversine


# Never rewrite these machines' app data or resurrect them after deletion.
CONFIRMED_IDENTITIES = {
    "legacy:481162": 7294,  # Basilica St. Michael / Sound Of Music Church
    "legacy:484552": 5607,  # Hochseilpark Hinterglemm
}

# User confirmed two physical machines here. Different catalogue IDs alone are
# not proof of different machines: the site also contains duplicate/old listings.
DISTINCT_LISTING_GROUPS = (frozenset({"legacy:430923", "legacy:436375"}),)

IGNORED_LISTINGS = {
    "legacy:460896": (
        "User-confirmed duplicate of Buc-ee's Rockingham County, VA (466359), "
        "already linked in PennyMe; no action. App duplicates 9549 and 8003 "
        "were removed by the user and must not be recreated."
    ),
}

# Universal's listing covers many physical machines. Fill blank links on existing
# machines within 1 km of the catalogue entrance (parks and CityWalk); never
# create devices from this listing. A fixed region avoids future geocoder drift.
REGIONAL_LINKS = {
    "legacy:424410": {
        "area": "Florida",
        "center": (28.4749822, -81.4665043),
        "radius_m": 1000,
    },
}


def regional_machines(source_key, machines):
    rule = REGIONAL_LINKS.get(source_key)
    if rule is None:
        return None
    return [
        machine
        for machine in machines
        if machine["area"] == rule["area"]
        and machine.get("latitude") is not None
        and machine.get("longitude") is not None
        and haversine(
            rule["center"], (machine["latitude"], machine["longitude"]), unit="m"
        )
        <= rule["radius_m"]
    ]
