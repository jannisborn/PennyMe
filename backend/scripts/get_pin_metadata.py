"""
PROBABLY THIS FILE IST MOSTLY DEPRECATED
To check whether the website has been updated
"""
import argparse
import json
import os

from pennyme.locations import COUNTRY_TO_CODE, parse_location_name
from pennyme.pennycollector import (
    LOCATION_PREFIX,
    AREA_SITE,
    get_area_list_from_area_website, validate_location_list
    get_machine_list_from_locations,
)
from pennyme.webconfig import get_website

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

    area_website = get_website(AREA_SITE)
    areas = get_area_list_from_area_website(area_website)
    valid, diff = validate_location_list(areas)
    if not valid:
        raise ValueError(f"It seems there were new locations: {diff}")


    
    

    # AT SOME POINT I WILL LOOP HERE
    try:
        country_id = COUNTRY_TO_CODE[country]
    except KeyError:
        raise KeyError(
            f"Please provide a valid country, not {country}, pick from "
            f"{COUNTRY_TO_CODE.keys()}."
        )
    current_id = start_id - 1

    url = LOCATION_PREFIX + str(country_id)

    print("Set up Google Maps API")
    website = get_website(url)

    directory = os.path.join(output_folder, parse_location_name(country))
    os.makedirs(directory, exist_ok=True)

    with open(os.path.join(directory, "raw_website.mhtml"), "w") as f:
        f.write(str(website))

    # REFACTOR THIS TO 2 METHODS/FUNCTIONS since I also have to get GONE machines
    location_raw_list = get_location_list_from_location_website(website)

    locations = get_machine_list_from_locations(
        location_raw_list,
        current_id=current_id,
        country=country,
        api_key=api_key,
        add_date=True,
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
