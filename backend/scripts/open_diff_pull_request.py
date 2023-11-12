import argparse
import json

from pennyme.github_update import (
    REPO_OWNER, REPO_NAME, DATA_BRANCH, HEADER_LOCATION_DIFF, commit_json_file,
    load_latest_json, get_pr_id, post_comment_to_pr
)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-f",
        "--file",
        type=str,
        default="/root/PennyMe/new_data/server_locations.json"
    )
    parser.add_argument(
        "-p",
        "--problems_file",
        type=str,
        default="/root/PennyMe/new_data/problems.json"
    )
    args = parser.parse_args()

    # general commit message
    commit_message = "Updates from website "

    # 1) server_locations.json
    # load new server location
    with open(args.file, "r") as infile:
        server_locations = json.load(infile)

    # get latest_commit_sha
    old_server_locations, latest_commit_sha = load_latest_json()
    if old_server_locations != server_locations:
        print("Detected change in server_locations.json - push to github")
        joblog = open('/root/PennyMe/new_data/cron.log', 'r').read()
        commit_json_file(
            server_locations,
            branch_name=DATA_BRANCH,
            commit_message=commit_message + "(server_locations)",
            latest_commit_sha=latest_commit_sha,
            headers=HEADER_LOCATION_DIFF,
            body=joblog
        )
    else:
        print("No change between server locations")

    # 2) Problems.json
    # load new problems json
    with open(args.problems_file, "r") as infile:
        problems_json = json.load(infile)
    # get latest_commit_sha
    old_problems_json, latest_commit_sha = load_latest_json(file="/data/problems.json")

    if old_problems_json != problems_json:
        print("Detected change in problems.json - push to github")

        # Load the last logfile from the cronjob
        joblog = open('/root/PennyMe/new_data/cron.log', 'r').read()
        commit_json_file(
            problems_json,
            branch_name=DATA_BRANCH,
            commit_message=commit_message + "(problems json)",
            latest_commit_sha=latest_commit_sha,
            headers=HEADER_LOCATION_DIFF,
            file_path="/data/problems.json",
            body=joblog if old_server_locations == server_locations else "New problems require attention."
        )
    else:
        print("No change between problem jsons")


    if old_server_locations==server_locations and old_problems_json==problems_json:
        pr_id = get_pr_id(branch_name=DATA_BRANCH)
        if pr_id:
            post_comment_to_pr(pr_id=pr_id, comment="No website updates today!", headers=HEADER_LOCATION_DIFF)
