import argparse
import json

from pennyme.github_update import (
    REPO_OWNER, REPO_NAME, DATA_BRANCH, HEADER_LOCATION_DIFF,
    get_latest_commit_sha, commit_json_file
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
        server_locations = json.loads(infile)

    # get latest_commit_sha
    latest_commit_sha = get_latest_commit_sha(
        REPO_OWNER, REPO_NAME, DATA_BRANCH
    )

    commit_message = "Updates from website"

    commit_json_file(
        server_locations,
        branch_name=DATA_BRANCH,
        commit_message=commit_message,
        latest_commit_sha=latest_commit_sha,
        headers=HEADER_LOCATION_DIFF
    )
