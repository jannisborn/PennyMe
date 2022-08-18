import argparse
import json


parser = argparse.ArgumentParser()
parser.add_argument(
    "-i", "--input_filepath", type=str, help="Input geojson-file for sorting"
)
parser.add_argument(
    "-o", "--output_filepath", type=str, help="Output file for sorting"
)


def main(input_filepath: str, output_filepath: str):

    with open(input_filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    sorted_by_lat = sorted(
        data["features"], key=lambda x: x["geometry"]["coordinates"][1]
    )
    data["features"] = sorted_by_lat

    with open(output_filepath, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)


if __name__ == "__main__":
    args = parser.parse_args()
    main(args.input_filepath, args.output_filepath)
