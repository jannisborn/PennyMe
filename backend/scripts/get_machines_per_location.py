"""
Country based download of HTML from PennyCollector.com
This script does:
1. Scraping the HTML of a location and extracting machine name/subtitle and link.
2. Searches the location name on a map and saves the geographic coordinates
3. Saves data to .json
"""
import argparse
import json
import os
from datetime import datetime

from googlemaps import Client as GoogleMaps

from pennyme.locations import (
    parse_location_name,
    remove_html_and,
    COUNTRY_TO_CODE,
)
from pennyme.webconfig import LOCATION_PREFIX, get_website


parser = argparse.ArgumentParser()
parser.add_argument(
    "-l", "--location", type=str, help="location name to be parsed "
)
parser.add_argument("-a", "--api_key", type=str, help="Google Maps API key")
parser.add_argument(
    "-o", "--output_folder", type=str, help="Output folder path"
)
parser.add_argument(
    "-i",
    "--start_id",
    type=int,
    help="Machine ID from which enumeration is started",
)


def get_json_from_location(
    country: str, api_key: str, output_folder: str, start_id: int
):

    try:
        country_id = COUNTRY_TO_CODE[country]
    except KeyError:
        raise KeyError(
            f"Please provide a valid country, not {country}, pick from "
            f"{COUNTRY_TO_CODE.keys()}."
        )
    current_id = start_id - 1

    url = LOCATION_PREFIX + str(country_id)
    gmaps = GoogleMaps(api_key)
    print("Set up Google Maps API")
    website = get_website(url)
    print("Loaded website")

    directory = os.path.join(output_folder, parse_location_name(country))
    os.makedirs(directory, exist_ok=True)

    with open(os.path.join(directory, "raw_website.mhtml"), "w") as f:
        f.write(str(website))

    location_raw_table = website.find("table", attrs={"border": "1"})
    location_raw_list = list(location_raw_table.find_all("td"))

    # Skip the first 5 rows (they contain design issues)
    location_raw_list = location_raw_list[5:]

    ind = -1
    locations = []
    date = datetime.today()
    year, month, day = date.year, date.month, date.day
    while ind < len(location_raw_list) - 1:

        ind += 1

        content = str(location_raw_list[ind])

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
            if state != "Gone" and "<s>" not in title:

                # Make GM request, default title and subtitle. Optionally with city?
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
                        print(f"MANUAL handling needed: {title}\t{subtitle}")

                lat = str(lat)
                lng = str(lng)
                current_id += 1

                locations.append(
                    {
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
                            "last_updated": f"{year}-{month}-{day}",
                        },
                    }
                )

    data = {"type": "FeatureCollection", "features": locations}
    with open(os.path.join(directory, "data.json"), "w", encoding="utf8") as f:

        json.dump(data, f, ensure_ascii=False, indent=4)
    print(f"DONE! Last ID was {current_id}")


if __name__ == "__main__":
    args = parser.parse_args()
    get_json_from_location(
        args.location, args.api_key, args.output_folder, args.start_id
    )
