import argparse
import json

from pennyme.github_update import (
    REPO_OWNER, REPO_NAME, DATA_BRANCH, HEADER_LOCATION_DIFF, commit_json_file,
    load_latest_server_locations
)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-f",
        "--file",
        type=str,
        default="/root/PennyMe/new_data/server_locations.json"
    )
    args = parser.parse_args()

    # load new server location
    with open(args.file, "r") as infile:
        server_locations = json.load(infile)

    # get latest_commit_sha
    _, latest_commit_sha = load_latest_server_locations(
        branch_name=DATA_BRANCH
    )

    commit_message = "Updates from website"

    commit_json_file(
        server_locations,
        branch_name=DATA_BRANCH,
        commit_message=commit_message,
        latest_commit_sha=latest_commit_sha,
        headers=HEADER_LOCATION_DIFF
    )
