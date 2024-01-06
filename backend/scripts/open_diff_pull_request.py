import argparse
import json
import os

from loguru import logger
from pennyme.github_update import (
    DATA_BRANCH,
    HEADER_LOCATION_DIFF,
    TOKEN_TO_REVIEWER,
    commit_json_file,
    get_pr_id,
    load_latest_json,
    post_comment_to_pr,
)

parser = argparse.ArgumentParser()
parser.add_argument(
    "-f", "--file", type=str, default="/root/PennyMe/new_data/server_locations.json"
)
parser.add_argument(
    "-p",
    "--problems_file",
    type=str,
    default="/root/PennyMe/new_data/problems.json",
)


def open_differ_pr(locations_path: str, problems_path: str):
    # general commit message
    commit_message = "Updates from website "

    # 1) server_locations.json
    # load new server location
    with open(locations_path, "r") as infile:
        server_locations = json.load(infile)

    # get latest_commit_sha
    old_server_locations, latest_commit_sha = load_latest_json()
    if old_server_locations != server_locations:
        logger.info("Detected change in server_locations.json - push to github")
        joblog = open("/root/PennyMe/new_data/cron.log", "r").read()
        commit_json_file(
            server_locations,
            branch_name=DATA_BRANCH,
            commit_message=commit_message + "(server_locations)",
            latest_commit_sha=latest_commit_sha,
            headers=HEADER_LOCATION_DIFF,
            body=joblog,
            reviewer=TOKEN_TO_REVIEWER[HEADER_LOCATION_DIFF["Authorization"]],
        )
    else:
        logger.info("No change between server locations")

    # 2) Problems.json
    # load new problems json
    with open(problems_path, "r") as infile:
        problems_json = json.load(infile)
    # get latest_commit_sha
    old_problems_json, latest_commit_sha = load_latest_json(file="/data/problems.json")

    if old_problems_json != problems_json:
        logger.info("Detected change in problems.json - push to github")

        # Load the last logfile from the cronjob
        joblog = open("/root/PennyMe/new_data/cron.log", "r").read()
        commit_json_file(
            problems_json,
            branch_name=DATA_BRANCH,
            commit_message=commit_message + "(problems json)",
            latest_commit_sha=latest_commit_sha,
            headers=HEADER_LOCATION_DIFF,
            file_path="/data/problems.json",
            reviewer=TOKEN_TO_REVIEWER[HEADER_LOCATION_DIFF["Authorization"]],
            body=joblog
            if old_server_locations == server_locations
            else "New problems require attention.",
        )
    else:
        logger.info("No change between problem jsons")

    if old_server_locations == server_locations and old_problems_json == problems_json:
        pr_id = get_pr_id(branch_name=DATA_BRANCH)
        if pr_id:
            post_comment_to_pr(
                pr_id=pr_id,
                comment="No website updates today!",
                headers=HEADER_LOCATION_DIFF,
            )

    # Remove the running file to indicate that the job is done
    os.remove(os.path.join(os.path.dirname(locations_path), "running.tmp"))
    logger.info("Done")


if __name__ == "__main__":
    args = parser.parse_args()
    open_differ_pr(locations_path=args.file, problems_path=args.problems_file)
