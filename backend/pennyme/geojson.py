import json
from datetime import datetime
from typing import Any, Dict

DATE = datetime.today()


def json_to_geojson(
    input_filepath: str, output_filepath: str
) -> Dict[str, Any]:

    with open(input_filepath, "r", encoding="utf-8") as f:
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
        d.update({"last_updated": f"{DATE.year}-{DATE.MONTH}-{DATE.DAY}"})
        item["properties"] = d

    with open(output_filepath, "w", encoding="utf-8") as f:
        json.dump(geojson, f, indent=4, ensure_ascii=False)
