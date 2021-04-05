"""
Country based download of HTML from PennyCollector.com
This script does:
1. Parsing the HTML and extracting machine name/subtitle and link.
2. Searches the location name on a map and saves the geographic coordinates
3. Saves data to .csv and .json
"""

import json
import os

import requests
from bs4 import BeautifulSoup

from googlemaps import Client as GoogleMaps

WEB_PREFIX = "http://209.221.138.252/"
API_KEY = open("../../gpc_api_key.keypair", "r").read()
GMAPS = GoogleMaps(API_KEY)

AREA = 90
COUNTRY = "Wyoming"

url = "http://209.221.138.252/Locations.aspx?area=" + str(AREA)
mhtml = requests.get(url).content
unicode_str = mhtml.decode("utf8")
encoded_str = unicode_str.encode("ascii", "ignore")
website = BeautifulSoup(encoded_str, "html.parser")


def check_str(x):
    return x.replace("&amp;", "&")


directory = "data/countries/" + COUNTRY.lower()
if not os.path.exists(directory):
    os.makedirs(directory)

with open(directory + "/raw_website.mhtml", "w") as f:
    f.write(str(website))

with open(directory + "/data.json", "w", encoding="utf8") as f:

    location_raw_table = website.find("table", attrs={"border": "1"})
    location_raw_list = list(location_raw_table.find_all("td"))

    # Skip the first 5 rows (they contain design issues)
    location_raw_list = location_raw_list[5:]

    ind = -1
    locations = []
    while ind < len(location_raw_list) - 1:

        ind += 1
        content = str(location_raw_list[ind])

        if ind % 50 == 0 and ind > 0:
            print("Now processing location no. {}".format(ind / 5))

        # Each location item consists of 5 tds. Create a list of content attributes per location item
        if ind % 5 == 0:
            # Title and subtitle cell
            location = [COUNTRY]
            title = check_str(content.split("<td>")[1].split("<br/>")[0])
            subtitle = check_str(content.split('">')[1].split("</span>")[0])
            location.append(title)
        elif ind % 5 == 1:
            city = check_str(content.split("<td>")[1].split("</td>")[0])
            location.append(subtitle + ", " + city)
        elif ind % 5 == 2:
            state = check_str(content.split('Center">')[1].split("</td>")[0])
        elif ind % 5 == 3:
            link = WEB_PREFIX + content.split('href="')[1].split('"><')[0]
            location.append(link)
        elif ind % 5 == 4:
            if state != "Gone" and "<s>" not in title:

                # Make GM request, default title and subtitle. Optionally with city?

                query_coord = location[1] + ", " + location[2]

                # print(query_coord)
                coordinates = GMAPS.geocode(query_coord)

                try:
                    lat = coordinates[0]["geometry"]["location"]["lat"]
                    lng = coordinates[0]["geometry"]["location"]["lng"]
                except IndexError:
                    # In case no location was found, try only the subtitle
                    print("SECOND attempt needed.")
                    print(location)
                    coordinates = GMAPS.geocode(location[2])
                    try:
                        lat = coordinates[0]["geometry"]["location"]["lat"]
                        lng = coordinates[0]["geometry"]["location"]["lng"]
                    except IndexError:
                        print("MANUAL handling needed.")
                        print(location)

                location.append(str(lat))
                location.append(str(lng))

                locations.append(location)

    data = {"data": locations}
    json.dump(data, f, ensure_ascii=False, indent=2)
print("DONE!")
