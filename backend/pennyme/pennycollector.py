"""Utils to parse pennycollector.com"""
import datetime
from typing import Dict, List, Optional

from googlemaps import Client as GoogleMaps

from .locations import remove_html_and

LOCATION_PREFIX = "http://209.221.138.252/Locations.aspx?area="
DATE = datetime.today()
YEAR, MONTH, DAY = DATE.year, DATE.month, DATE.day


def get_location_list_from_website(website) -> List:
    location_raw_table = website.find("table", attrs={"border": "1"})
    location_raw_list = list(location_raw_table.find_all("td"))

    # Skip the first 5 rows (they contain design issues)
    return location_raw_list[5:]


def get_machine_list_from_locations(
    raw_locations: List,
    current_id: int,
    country: str,
    api_key: Optional[str] = None,
    add_date: bool = False,
) -> List[Dict]:
    """
    Parse a raw list of locations (from the HTML website) into a list of Penny
    machines, one GEOJSON per machine.


    Args:
        raw_locations (List): A list of raw webcontent from pennylocator.com
        current_id (int): The ID to be used for first machine. IDs are UNIQUE
            and are assigned in ascending order.
        country (str): Name of the country for which data is being parsed.
        api_key (str): Key to access GoogleMaps API used to retrieve the exact
            coordinates of a machine. If not provided, no exact locations
            will be added.
        add_date: Whether or not the current date is added to the GEOJSON.
            Defaults to False since this is used for regular comparison.

    Returns:
        List[Dict]: A list of Penny machines, one GEOJSON per machine.
    """

    ind = -1
    locations = []
    if api_key:
        gmaps = GoogleMaps(api_key)
    get_coords = api_key is None

    while ind < len(raw_locations) - 1:

        ind += 1

        content = str(raw_locations[ind])

        if ind % 50 == 0 and ind > 0:
            print("Now processing location no. {}".format(ind / 5))

        # Each location item consists of 5 tds. Create a list of content attributes per location item
        if ind % 5 == 0:
            # Title and subtitle cell
            title = remove_html_and(content.split("<td>")[1].split("<br/>")[0])
            subtitle = remove_html_and(
                content.split('">')[1].split("</span>")[0]
            )
        elif ind % 5 == 1:
            city = remove_html_and(content.split("<td>")[1].split("</td>")[0])
            subtitle = subtitle + ", " + city
        elif ind % 5 == 2:
            state = remove_html_and(
                content.split('Center">')[1].split("</td>")[0]
            )
        elif ind % 5 == 3:
            link = LOCATION_PREFIX + content.split('href="')[1].split('"><')[0]

        elif ind % 5 == 4:
            # TODO: ALSO PARSE GONE ARTICLES --> MAYBE 2 FUNCTIONS??
            if state != "Gone" and "<s>" not in title:

                if get_coords:
                    # Make GM request, default title and subtitle.
                    query_coord = title + ", " + subtitle
                    coordinates = gmaps.geocode(query_coord)

                    try:
                        lat = coordinates[0]["geometry"]["location"]["lat"]
                        lng = coordinates[0]["geometry"]["location"]["lng"]
                    except IndexError:
                        # In case no location was found, try only the subtitle
                        print(f"SECOND attempt needed for {title}\t{subtitle}.")
                        coordinates = gmaps.geocode(subtitle)
                        try:
                            lat = coordinates[0]["geometry"]["location"]["lat"]
                            lng = coordinates[0]["geometry"]["location"]["lng"]
                        except IndexError:
                            print(
                                f"MANUAL handling needed: {title}\t{subtitle}"
                            )

                    lat = str(lat)
                    lng = str(lng)
                else:
                    lat = "N.A."
                    lng = "N.A."

                current_id += 1
                loc = {
                    "type": "Feature",
                    "geometry": {
                        "type": "Point",
                        "coordinates": [lng, lat],
                    },
                    "properties": {
                        "name": title,
                        "active": True,
                        "area": country,
                        "address": subtitle,
                        "status": "unvisited",
                        "external_url": link,
                        "internal_url": "null",
                        "latitude": lat,
                        "longitude": lng,
                        "id": current_id,
                    },
                }
                if add_date:
                    loc.update({"last_updated": f"{YEAR}-{MONTH}-{DAY}"})
                locations.append(loc)

    return locations
