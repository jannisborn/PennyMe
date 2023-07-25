"""
Country based download of HTML from PennyCollector.com
This script does:
1. Parsing the HTML and extracting machine name/subtitle and link.
2. Searches the location name on a map and saves the geographic coordinates
3. Saves data to .json
"""
#%%
import json
import os
import sys

import requests
from bs4 import BeautifulSoup
import os
from googlemaps import Client as GoogleMaps

sys.path.append(".")
from country_mapper import COUNTRY_TO_CODE


WEB_PREFIX = "http://209.221.138.252/"
API_KEY = open("../../gpc_api_key.keypair", "r").read()
GMAPS = GoogleMaps(API_KEY)


root = "dump"
os.makedirs(root, exist_ok=True)


for COUNTRY, CODE in COUNTRY_TO_CODE.items():

    area = COUNTRY.lower().replace(" ", "_")
    url = "http://209.221.138.252/Locations.aspx?area=" + str(CODE)
    mhtml = requests.get(url).content
    unicode_str = mhtml.decode("utf8")
    encoded_str = unicode_str.encode("ascii", "ignore")
    website = BeautifulSoup(encoded_str, "html.parser")

    with open(os.path.join(root, f"{area}.mhtml"), "w") as f:
        f.write(str(website))

    text = website.prettify()
    on = text.find("tbllist_header")
    off = text.find("GetXmlHttp")
    location_text = text[on:off].split("\n")

    write = False
    with open(os.path.join(root, f"{area}.txt"), "w") as f:
        for idx, line in enumerate(location_text):
            if "</tr>" in line:
                # TODO: Extract properties and build dict/json
                write = True
                continue
            f.write(line + "\n")
