import json

with open("../data/all_locations_json.json", "r", encoding="utf-8") as f:
    data = json.load(f)


geojson = {
    "type": "FeatureCollection",
    "features": [
        {
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [
                    float(val["longitude"]),
                    float(val["latitude"]),
                ],
            },
            "properties": val,
        }
        for key, val in data.items()
    ],
}

for item in geojson["features"]:
    d = item["properties"]
    d.update({"last_updated": "2021-04-05"})
    item["properties"] = d


with open("../data/all_locations_new.json", "w", encoding="utf-8") as f:
    json.dump(geojson, f, indent=4, ensure_ascii=False)
