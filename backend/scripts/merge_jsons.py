import json
from copy import deepcopy
from datetime import datetime
from pathlib import Path

import typer

app = typer.Typer()


@app.command()
def merge_locations(all_file: Path):
    with open(all_file, "r") as f:
        alll = json.load(f)
    server_file = all_file.parent / all_file.name.replace("all", "server")
    with open(server_file, "r") as f:
        ser = json.load(f)

    # Remove status field if still present (this was deprecated)
    for entry in ser["features"]:
        if "status" in entry["properties"].keys():
            del entry["properties"]["status"]

    for entry in ser["features"]:
        if "status" in entry["properties"].keys():
            del entry["properties"]["status"]

    ls, la = len(ser["features"]), len(alll["features"])
    print(f"All locations has {la} entries, server locations {ls}")

    youngest_all = sorted(
        [
            datetime.strptime(e["properties"]["last_updated"], "%Y-%m-%d")
            for e in alll["features"]
        ]
    )[-1]
    print(f"Youngest entry in all locations is of {youngest_all}")

    # Merge entries. Start from server locations, otherwise we have to overwrite
    new_all = deepcopy(ser)
    new_all_ids = [e["properties"]["id"] for e in ser["features"]]

    for allentry in alll["features"][::-1]:
        if allentry["properties"]["id"] not in new_all_ids:
            new_all["features"].insert(0, allentry)

    print(f"New all locations has {len(new_all['features'])} entries")

    # Delete entries from server locations that are older than youngest in all locations
    # NOTE: This gives a grace period to users to update the app. If we skip this
    #   step it means that users dont see server-location machines anymore unless they
    #   update the app

    new_server = deepcopy(ser)
    new_server["features"] = []

    for e in ser["features"]:
        if (
            datetime.strptime(e["properties"]["last_updated"], "%Y-%m-%d")
            < youngest_all
        ):
            continue
        new_server["features"].append(e)

    print(f"New server location has length {len(new_server['features'])}")

    with open(all_file.parent / all_file.name.replace(".json", "_new.json"), "w") as f:
        json.dump(new_all, f, indent=4, ensure_ascii=False)

    with open(
        server_file.parent / server_file.name.replace(".json", "_new.json"), "w"
    ) as f:
        json.dump(new_server, f, indent=4, ensure_ascii=False)

    print("Saved data!")


if __name__ == "__main__":
    app()
