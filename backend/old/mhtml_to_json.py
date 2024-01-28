"""
Country based download of HTML from PennyCollector.com
This script does:
1. Parsing the HTML and extracting machine name/subtitle and link.
2. Searches the location name on a map and saves the geographic coordinates
3. Saves data to .json
"""

import glob
import os
import sys

sys.path.append(".")

root = "latest_dump"
for file in glob.glob(os.path.join(root, "*.mhtml")):
    area = file.split("/")[-1].split(".")[0]
    with open(file, "r") as f:
        data = f.read()

    on = data.find("tbllist_header")
    off = data.find("GetXmlHttp")
    location_data = data[on:off].split("\n")

    write = False
    with open(os.path.join(root, f"{area}.txt"), "w") as f:
        for idx, line in enumerate(location_data):
            if "</tr>" in line:
                write = True
                continue
            f.write(line + "\n")
