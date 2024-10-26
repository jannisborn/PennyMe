"""Utils to parse pennycollector.com"""

from datetime import datetime
from typing import Any, Dict, List, Tuple

import bs4
import googlemaps
from loguru import logger

from .locations import COUNTRY_TO_CODE, remove_html_and

WEBSITE_ROOT = "http://209.221.138.252/"
AREA_PREFIX = WEBSITE_ROOT + "Locations.aspx?area="
AREA_SITE = WEBSITE_ROOT + "AreaList.aspx"
DATE = datetime.today()
YEAR, MONTH, DAY = DATE.year, str(DATE.month).zfill(2), str(DATE.day).zfill(2)
REMOVED_STATES = ["Moved", "Gone"]
TEMPORARY_UNAVAIALBLE_STATES = ["Out of Order"]
UNAVAILABLE_STATES = REMOVED_STATES + TEMPORARY_UNAVAIALBLE_STATES
UNAVAILABLE_MAPPER = {
    "Out of Order": "out-of-order",
    "Moved": "retired",
    "Gone": "retired",
}


def get_area_list_from_area_website(website) -> List[str]:
    """
    Get a list with areas from the overall area website.

    Args:
        website: AREA_SITE website.

    Returns:
        List: A list of areas.
    """

    unparsed_locs = website.find("table", id="StatesList")
    us_locs = [loc.split("\t")[-1] for loc in str(unparsed_locs).split("</a>")][:-1]

    non_us_unparsed = website.findAll("option", attrs={"selected": ""})
    non_us_locations = []
    for can in non_us_unparsed[1:]:
        loc = str(can).split("</option>")[0].split(">")[-1]
        if loc == "Select One":
            break
        non_us_locations.append(loc)
    return us_locs + non_us_locations


def validate_location_list(locations: List[str]) -> Tuple[bool, List[str]]:
    """
    Receive a list of locations (str) and validate that all of them are
    known to the app.

    Args:
        List: List of locations

    Returns:
        Tuple of:
            bool: Whether or not all locations are known.
            diff: List of unknown locations (typically empty).
    """
    diff = [loc for loc in locations if loc not in COUNTRY_TO_CODE.keys()]
    return diff == [], diff


def get_raw_locations_from_location_website(website) -> List[bs4.element.Tag]:
    """
    Retrieves a list of locations from a website of any location, e.g.:
    http://209.221.138.252/Locations.aspx?area=42

    Args:
        website: The bs4 website content.

    Returns:
        List of bs4 tags
    """
    location_raw_table = website.find("table", attrs={"border": "1"})
    location_raw_list = list(location_raw_table.find_all("td"))

    # Skip the first 5 rows (they contain design issues)
    return location_raw_list[5:]


def get_location_list_from_location_website(
    website: bs4.BeautifulSoup,
) -> List[List[str]]:
    """
    Retrieves a list of locations from a website of any location, e.g.:
    http://209.221.138.252/Locations.aspx?area=42

    Args:
        website: The bs4 website content.

    Returns:
        List of locations, each represented as a list of strings,
            one per column.
    """
    raw_locations = get_raw_locations_from_location_website(website)

    # 5 Tags always make up one location
    location_list = []
    location = []  # Initialize the location list outside the loop
    for ind, content in enumerate(raw_locations):
        content = str(content)
        location.append(content)
        if (ind + 1) % 5 == 0:  # Check if 5 tags have been added
            location_list.append(location)
            location = []  # Reset location for the next set of tags
    return location_list


def get_prelim_geojson(
    raw_location: List[str], country: str, add_date: bool = False
) -> Dict[str, Any]:
    """
    Function to convert a raw location entry (HTML) into a preliminary geojson
    file.

    Args:
        raw_location: raw webcontent from pennylocator.com about a location.
        country: Name of the country/area
        add_date: Whether the date will be added as last_changed.
            Defaults to False.
    Returns:
        Dict: Containing the GeoJson.
    """

    # Each location item consists of 5 tds. Create a list of content attributes per location item

    # Title and subtitle cell
    title = remove_html_and(raw_location[0].split("<td>")[1].split("<br/>")[0])
    if "<s>" in title:
        title = title.split("<s>")[1].split("</s>")[0]
    subtitle = remove_html_and(raw_location[0].split('">')[1].split("</span>")[0])
    city = remove_html_and(raw_location[1].split("<td>")[1].split("</td>")[0])
    subtitle = subtitle + ", " + city

    state = remove_html_and(raw_location[2].split('Center">')[1].split("</td>")[0])
    if state not in UNAVAILABLE_STATES:
        # States like 1p, 4p and everything else
        state = "available"
    link = WEBSITE_ROOT + raw_location[3].split('href="')[1].split('"><')[0]

    # NOTE: This refers to the last update on the website. We dont exploit this
    # information atm, but it could be used to make inference faster.
    updated = raw_location[4].split('Center">')[1].split("</td>")[0]
    month, day, year = updated.split("/")
    geojson = {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": ["N.A.", "N.A."],
        },
        "properties": {
            "name": title,
            "area": country,
            "address": subtitle,
            "status": "unvisited",
            "external_url": link,
            "internal_url": "null",
            "machine_status": state,
            "id": -1,
        },
        "temporary": {"website_updated": "20" + year + "-" + month + "-" + day},
    }
    if add_date:
        geojson["properties"].update({"last_updated": f"{YEAR}-{MONTH}-{DAY}"})
    return geojson


def prelim_to_problem_json(geojson=Dict[str, Any], msg: str = "") -> Dict[str, Any]:
    """
    Receives a preliminary geo-json object and strips of all attributes to make
    it compatible with the format in `problems.json`.

    Args:
        Dict: Preliminary geojson object

    Returns:
        Stripped geojson object
    """
    geojson["properties"]["id"] = -1
    geojson["properties"]["last_updated"] = -1
    geojson["problem"] = msg
    if "temporary" in geojson.keys():
        del geojson["temporary"]
    return geojson


def get_coordinates(
    title: str, subtitle: str, api: googlemaps.client.Client
) -> Tuple[float, float]:
    """
    Perform geolocationing for a title and a subtitle.

    Args:
        title: Title of the penny machine.
        subtitle: Subtitle of the penny machine.
        api: google maps API object.

    Returns:
        Tuple[float, float]: Latitude and longitude
    """

    # Make GM request, default title and subtitle.
    queries = [title + ", " + subtitle, subtitle, title]

    for query in queries:
        coordinates = api.geocode(query)

        try:
            lat = coordinates[0]["geometry"]["location"]["lat"]
            lng = coordinates[0]["geometry"]["location"]["lng"]
            break
        except IndexError:
            continue
    try:
        lat
    except NameError:
        logger.error(f"Geolocation failed for: {title}\t sub: {subtitle}")
        lat, lng = 0, 0
    return lat, lng
