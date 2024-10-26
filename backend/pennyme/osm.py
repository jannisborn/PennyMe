from typing import Any, Dict, List

import googlemaps
import overpy
from thefuzz import process as fuzzysearch
from tqdm import tqdm

from pennyme.locations import CODE_TO_USSTATE, COUNTRY_TO_CODE
from pennyme.pennycollector import DAY, MONTH, YEAR
from pennyme.utils import get_next_free_machine_id
from pennyme.webconfig import get_elongated_coin_title

AREAS = list(COUNTRY_TO_CODE.keys()) + ["Slovakia", "Algeria", "Armenia", "Madagascar"]
TODAY = f"{YEAR}-{MONTH}-{DAY}"


def get_osm_machines() -> overpy.Result:
    """
    Retrieve all Penny machines available in Open street map.

    Returns:
        overpy.Result object with nodes containing the machines.
    """

    # Create an Overpass API instance
    api = overpy.Overpass()

    # Define the Overpass QL query
    query = """
    node
    ["vending"="elongated_coin"]
    (-90, -180, 90, 180);
    out;
    """
    # Send the query to the Overpass API and get the response
    result = api.query(query)
    return result


def get_address(machine: overpy.Node, gmaps: googlemaps.client.Client) -> str:
    """
    Get the address of a machine from coordinates via the Google Maps API.

    Args:
        machine: Overpy node object containing the machine.
        gmaps: Google Maps API client.

    Raises:
        ValueError: If the address could not be found.

    Returns:
        Address of the machine.
    """
    street_out = gmaps.reverse_geocode(
        (machine.lat, machine.lon), result_type="street_address"
    )
    if street_out != []:
        address = street_out[0]["formatted_address"]
    else:
        post_out = gmaps.reverse_geocode(
            (machine.lat, machine.lon), result_type="postal_code"
        )
        if post_out != []:
            address = post_out[0]["formatted_address"]
        else:
            out = gmaps.reverse_geocode((machine.lat, machine.lon))
            if out != []:
                address = out[0]["formatted_address"]
            else:
                raise ValueError(f"Could not find address: {vars(machine)}")

    return address


def osm_to_geojson(result: overpy.Result) -> Dict[str, Any]:
    """
    Convert the Overpy result to a (preliminary) GeoJSON object.

    Args:
        result: An Overpy result object.

    Raises:
        ValueError: If the country could not be extracted from the address.

    Returns:
        A GeoJSON object.
    """
    data = []
    for i, machine in enumerate(tqdm(result.nodes, total=len(result.nodes))):
        # This involves GM API
        address = get_address(machine)
        if "USA" in address:
            us_state_code = address.split(",")[-2].strip().split(" ")[0]
            country = CODE_TO_USSTATE[us_state_code]
        elif "Russia" in address:
            country = "Russia"
        else:
            country = address.split(",")[-1].strip()

        match, score = fuzzysearch.extract(country, AREAS, limit=1)[0]
        if score < 75:
            raise ValueError(f"Could not extract country ({country}) from {address}.")

        if (
            "website" in machine.tags.keys()
            and "elongated-coin" in machine.tags["website"]
        ):
            url = machine.tags["website"]
            title = get_elongated_coin_title(machine.tags["website"])
        else:
            title = address.split(",")[0]
            url = "null"

        geojson = {
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [float(machine.lon), float(machine.lat)],
            },
            "properties": {
                "name": title,
                "area": match,
                "address": address,
                "status": "unvisited",
                "external_url": url,
                "internal_url": "null",
                "machine_status": "available",
                "id": -1,
                "last_updated": -1,
            },
        }
        data.append(geojson)
    return data


def prelim_to_final_entry(
    entry: Dict[str, Any], server_data: List[Any], all_locations_path: str
) -> Dict[str, Any]:
    """
    Convert a preliminary geojson entry to a final one, adding date and
        machine id.

    Args:
        entry: A preliminary geojson entry.
        server_data: The latest version of the `server_locations.json`.
        all_locations_path: A path to the `all_locations.json` file.

    Returns:
        A final geojson entry.
    """
    # Add date
    entry["properties"]["last_updated"] = TODAY
    machine_id = get_next_free_machine_id(all_locations_path, server_data["features"])
    entry["properties"]["id"] = machine_id
    return entry
