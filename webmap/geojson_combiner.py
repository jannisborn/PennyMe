import json


def combine_geojson_files(file1_path, file2_path, output_path):
    # Load the first GeoJSON file
    with open(file1_path, "r") as file:
        geojson1 = json.load(file)

    # Load the second GeoJSON file
    with open(file2_path, "r") as file:
        geojson2 = json.load(file)

    # Combine the features, preferring features from the second file
    combined_features = {
        feature["properties"]["id"]: feature for feature in geojson1["features"]
    }
    combined_features.update(
        {feature["properties"]["id"]: feature for feature in geojson2["features"]}
    )

    # Create a new GeoJSON structure with combined features
    combined_geojson = {
        "type": "FeatureCollection",
        "features": list(combined_features.values()),
    }

    # Save the combined GeoJSON to the specified output path
    with open(output_path, "w") as file:
        json.dump(combined_geojson, file, indent=4)


combine_geojson_files(
    "../data/all_locations.json", "../data/server_locations.json", "all.json"
)
