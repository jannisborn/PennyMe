import base64
import json
import os
import time
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd
import requests
from loguru import logger

from pennyme.slack import message_slack_raw
from pennyme.utils import find_machine_in_database, get_next_free_machine_id

with open("github_token.json", "r") as infile:
    github_infos = json.load(infile)
# Define GitHub repository information
REPO_OWNER = github_infos["owner"]
REPO_NAME = github_infos["repo"]
BASE_BRANCH = "main"  # Replace with the appropriate base branch name
DATA_BRANCH = "machine_updates"
HEADERS = {
    "Authorization": f"token {github_infos['token']}",
    "accept": "application/vnd.github+json",
}
HEADER_LOCATION_DIFF = {
    "Authorization": f"token {github_infos['token_jab']}",
    "accept": "application/vnd.github+json",
}
TOKEN_TO_REVIEWER = {
    f"token {github_infos['token_jab']}": "NinaWie",
    f"token {github_infos['token']}": "jannisborn",
}
FILE_PATH = "/data/server_locations.json"


def check_branch_exists(branch_name: str) -> bool:
    """
    Check whether a branch exists in the repository.

    Args:
        branch_name: Name of the branch to check.

    Returns:
        True if the branch exists, False otherwise.
    """
    # Check if the desired branch exists
    branch_check_url = (
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/branches/{branch_name}"
    )
    branch_check_response = requests.get(branch_check_url, headers=HEADERS)
    return branch_check_response.status_code == 200


def get_latest_branch_url(file: str = FILE_PATH, branch: str = DATA_BRANCH) -> str:
    """
    Check whether the latest change for a file is on `main` or on the given branch.
    Returns the respective URL as a string.

    NOTE: We would need to change this function if we want to search for the
        branch with the latest commit. It just compares `main` and the given
        branch.

    Args:
        file: Path to file to compare to. Defaults to `/data/server_locations.json`.
        branch: Branch to check. Defaults to `machine_updates`.

    Returns:
        The URL to the latest version of the file.
    """

    branch_exists = check_branch_exists(branch)
    # if data branch exists, the url points to the branch
    repo_url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}"
    if branch_exists:
        file_url = f"{repo_url}/contents/{file}?ref={branch}"
    else:
        file_url = f"{repo_url}/contents/{file}"
    return file_url


def create_new_branch(branch_name: str, headers: Dict[str, Any] = HEADERS) -> bool:
    """
    Create a new branch with the given name.

    Args:
        branch_name: Name of the branch to create.
        headers: Headers for the request.

    Returns:
        True if the branch was created, False otherwise.
    """
    # create a new branch if it does not exist yet
    if not check_branch_exists(branch_name):
        payload = {
            "ref": f"refs/heads/{branch_name}",
            "sha": get_latest_commit_sha(BASE_BRANCH),
        }
        response = requests.post(
            f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/git/refs",
            headers=headers,
            json=payload,
        )
        if response.status_code not in [200, 201, 202, 204]:
            logger.error(
                f"Failed to create a new branch, code {response.status_code} with message {response.json()}"
            )
            return False
        return True
    return False


def get_latest_commit_time(
    infer_branch: bool = True, branch: Optional[str] = None
) -> pd.Timestamp:
    """
    Get the time point of the latest commit to either DATA_BRANCH or main

    Args:
        infer_branch: If True, returns latest commit time of DATA_BRANCH if it exists,
            otherwise of main. If False, an arbitrary branch has to be given.
        branch: Name of the branch to check. Defaults to None

    Returns:
        pd.Timestamp: Datetime of last commit
    """
    if not infer_branch and not branch:
        raise ValueError(
            "Either infer_branch has to be True or branch has to be given."
        )

    url_base = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/commits/"
    if infer_branch:
        url = url_base + (DATA_BRANCH if check_branch_exists(DATA_BRANCH) else "main")
    else:
        url = url_base + branch

    response = requests.get(url, headers=HEADERS)
    date_last_updated = response.json()["commit"]["author"]["date"]
    return pd.to_datetime(date_last_updated)


def load_latest_json(
    headers: Dict[str, Any] = HEADERS, file: str = FILE_PATH
) -> Tuple[Dict[str, Any], str]:
    """
    Load a json file from the github repository. Automatically
    detects whether the most up to date file is on the `main` or
    on the `DATA_BRANCH` branch.

    Args:
        headers: Headers for the request.
        file: Path to the file to load, e.g.,  `/data/server_locations.json`.

    Returns:
        The json file as a dictionary and the sha of the latest commit.
    """

    # Load latest version of the file
    file_url = get_latest_branch_url(file=file)
    response = requests.get(file_url, headers=headers)
    data = response.json()

    if data["encoding"] == "base64":
        current_content_decoded = base64.b64decode(data["content"]).decode("utf-8")
        content = json.loads(current_content_decoded)
    else:
        response = requests.get(data["download_url"])
        content = response.json()

    # the sha of the last commit is needed later for pushing
    latest_commit_sha = data["sha"]
    return content, latest_commit_sha


def push_newmachine_to_github(
    machine_update_entry: Dict[str, Any], branch_name: str = DATA_BRANCH
) -> int:
    """
    Push a new machine to the github repository.

    Args:
        machine_update_entry: A geojson entry for the new machine.
        branch_name: Name of the branch to push to. Defaults to `machine_updates`.

    Returns:
        The id of the new machine.
    """
    server_locations, latest_commit_sha = load_latest_json()

    machine_id = get_next_free_machine_id(
        "../data/all_locations.json", server_locations["features"]
    )
    machine_update_entry["properties"]["id"] = machine_id

    # Update the server_locations
    server_locations["features"].append(machine_update_entry)

    # make commit message
    machine_name = machine_update_entry["properties"]["name"]
    commit_message = f"add new machine {machine_id} named {machine_name}"

    commit_json_file(
        server_locations,
        branch_name,
        commit_message,
        latest_commit_sha,
        body=f"New machine {machine_id} named {machine_name} submitted.",
        reviewer=TOKEN_TO_REVIEWER[HEADERS["Authorization"]],
    )

    return machine_id


def wait(time_to_wait: int = 5, check_cronjob: bool = True):
    """
    Wait until time_to_wait minutes have passed after last commit and cron job is not running.

    Args:
        time_to_wait: Waiting time in minutes. Defaults to 5.
        check_cronjob: If True, also checks whether the cron job is running.
    """

    cronruns = check_cronjob
    t = time_to_wait

    while cronruns or time_to_wait > 0:
        if check_cronjob:
            # Optional waiting if cron job is running
            cronruns = isbusy()
            if cronruns:
                message_slack_raw(
                    text="Found conflicting cron job, waiting for it to finish...",
                )
                counter = 0
                while isbusy() and counter < 60:
                    time.sleep(300)  # Retry every 5min
                    counter += 1
                if counter == 60:
                    message_slack_raw(
                        text="Timeout of 5h reached, cron job still runs, aborting...",
                    )
                    return
                # Should be done by now
                cronruns = isbusy()

        # wait for 5 minutes per default after last commit
        time_of_last_commit = get_latest_commit_time()
        time_to_wait = time_of_last_commit.timestamp() + t * 60 - time.time()
        while time_to_wait > 0:
            time.sleep(time_to_wait)
            time_of_last_commit = get_latest_commit_time()
            time_to_wait = time_of_last_commit.timestamp() + t * 60 - time.time()


def process_machine_change(
    updated_machine_entry: dict,
    ip_address: str,
    change_message: str,
    wait_buffer_min: int = 5,
):
    """
    Process a machine change request by modifying the server locations file

    Args:
        updated_machine_entry: Dictionary with user provided machine information
        ip_address: IP address of user
        change_message: commit message describing which fields were changed
        wait_buffer_min: Time to wait between edits. Defaults to 5.
    """
    wait(wait_buffer_min)

    try:
        machine_id = updated_machine_entry["properties"]["id"]
        title = updated_machine_entry["properties"]["name"]

        # Reload the server locations to make sure that we have the correct file
        server_locations, latest_commit_sha = load_latest_json()
        (
            existing_machine_infos,
            index_in_server_locations,
        ) = find_machine_in_database(machine_id, server_locations["features"])

        # replace or append to server_locations
        if index_in_server_locations > 0:
            server_locations["features"][
                index_in_server_locations
            ] = updated_machine_entry
        else:
            server_locations["features"].append(updated_machine_entry)

        # push to github
        commit_message = f'Change {machine_id} "{title}"' + change_message[:-1]
        commit_json_file(
            server_locations,
            DATA_BRANCH,
            commit_message.replace("\n", "\t"),
            latest_commit_sha,
            body=commit_message,
            post_comment=False,
        )

    except Exception as e:
        message_slack_raw(
            text=f"Error when processing machine change request: {machine_id} ({e})"
        )


def commit_json_file(
    server_locations: Dict,
    branch_name: str,
    commit_message: str,
    latest_commit_sha: str,
    headers: Dict[str, Any] = HEADERS,
    file_path: str = FILE_PATH,
    body: str = "Machine updates submitted for review",
    reviewer: Optional[str] = None,
    post_comment: bool = True,
):
    """
    Commit the server locations dictionary to a branch with the desired
        commit message.

    Args:
        server_locations: The server locations dictionary.
        branch_name: Name of the branch to commit to.
        commit_message: The commit message.
        latest_commit_sha: The sha of the latest commit.
        headers: Headers for the request.
        file_path: Path to the file to commit to, defaults to `/data/server_locations.json`.
        body: Content for commit message. Defaults to "Machine updates submitted for review".
        reviewer: GitHub username of the reviewer. Defaults to None.
        post_comment: Whether to post a comment to the existing PR. Defaults to True.
    """

    # create a new branch if necessary
    did_create_new_branch = create_new_branch(branch_name, headers=headers)

    # Update the file on the newly created branch
    file_content_encoded = base64.b64encode(
        json.dumps(server_locations, indent=4, ensure_ascii=False).encode("utf-8")
    ).decode("utf-8")

    payload = {
        "message": commit_message,
        "content": file_content_encoded,
        "branch": branch_name,
        "sha": latest_commit_sha,
    }
    response = requests.put(
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/contents{file_path}",
        headers=headers,
        json=payload,
    )

    if response.status_code != 200:
        logger.error(
            f"Failed to update file with code {response.status_code}: {response.json()}"
        )
        return

    pr_id = get_pr_id(branch_name=branch_name)
    if pr_id and did_create_new_branch:
        logger.error(
            "Seems like a PR already exists even though branch was created just now."
        )
        if post_comment:
            post_comment_to_pr(pr_id=pr_id, comment=body, headers=headers)
    elif pr_id and post_comment:
        # Seems like the PR already existed
        post_comment_to_pr(pr_id=pr_id, comment=body, headers=headers)
    elif did_create_new_branch:
        # open a new pull request if the branch did not exist
        open_pull_request(
            commit_message, branch_name, body=body, reviewer=reviewer, headers=headers
        )

    elif not did_create_new_branch:
        # Branch already existed but no PR was open
        open_pull_request(
            commit_message, branch_name, body=body, reviewer=reviewer, headers=headers
        )


def request_review(
    pr_id: int, reviewer: str, headers: Dict[str, Any] = HEADERS
) -> None:
    """
    Request a review for a pull request.

    Args:
        pr_id: The pull request id.
        reviewer: GitHub username of the reviewer.
        headers: Headers for the request.
    """
    response = requests.post(
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/pulls/{pr_id}/requested_reviewers",
        headers=headers,
        json={"reviewers": [reviewer]},
    )
    if response.status_code in [200, 201, 202, 204]:
        logger.info(f"Reviewer {reviewer} added.")
    else:
        logger.warning(
            f"Failed to add reviewer {reviewer}, code {response.status_code}."
        )


def add_pr_label(pr_id: int, labels: List[str], headers: Dict[str, Any] = HEADERS):
    """
    Add one or multiple labels to a pull request.

    Args:
        pr_id: The id of the pull request.
        labels: A list of labels to add.
        headers: Headers for the request.
    """
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/issues/{pr_id}/labels"
    response = requests.post(url, headers=headers, json={"labels": labels})
    if response.status_code == 200:
        logger.info("Labels added successfully.")
    else:
        logger.warning(
            f"Failed to add labels, code {response.status_code} with message {response.json()}"
        )


def open_pull_request(
    commit_message: str,
    branch_name: str,
    body: str,
    headers: Dict[str, Any] = HEADERS,
    reviewer: Optional[str] = None,
) -> bool:
    """
    Open a pull request with the given commit message and branch name.

    Args:
        commit_message: The commit message.
        branch_name: Name of the branch to commit to.
        body: Content for commit message. Can be arbitrary HTML.
        headers: Headers for the request.
        reviewer: GitHub username of the reviewer. Defaults to None.

    Returns:
        True if the pull request was created successfully, False otherwise.
    """
    # Open a pull request
    payload = {
        "title": commit_message,
        "body": body,
        "head": branch_name,
        "base": BASE_BRANCH,
    }
    response = requests.post(
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/pulls",
        headers=headers,
        json=payload,
    )
    # Add label to PR if it was created successfully
    if response.status_code == 201:
        pr_id = response.json()["number"]
        add_pr_label(pr_id, ["data", "bot"], headers=headers)
        if reviewer:
            request_review(pr_id, reviewer, headers=headers)
        return True
    return False


def get_latest_commit_sha(
    branch: str,
    owner: str = REPO_OWNER,
    repo: str = REPO_NAME,
) -> str:
    """
    Get the sha of the latest commit on a branch.

    Args:
        branch: Name of the branch to check.
        owner: Owner of the repository. Defaults to REPO_OWNER.
        repo: Name of the repository. Defaults to REPO_NAME.

    Returns:
        The sha of the latest commit.
    """

    response = requests.get(
        f"https://api.github.com/repos/{owner}/{repo}/git/refs/heads/{branch}"
    )
    return response.json()["object"]["sha"]


def post_comment_to_pr(
    pr_id: int,
    comment: str,
    owner: str = REPO_OWNER,
    repo: str = REPO_NAME,
    headers: Dict[str, Any] = HEADERS,
) -> bool:
    """
    Post a comment to a pull request.

    Args:
        pr_id: The id of the pull request.
        comment: The comment to post.
        owner: Owner of the repository. Defaults to REPO_OWNER.
        repo: Name of the repository. Defaults to REPO_NAME.
        headers: Headers for the request.

    Returns:
        True if the comment was posted successfully, False otherwise.
    """
    # Post a comment to a PR
    payload = {
        "body": comment,
    }
    response = requests.post(
        f"https://api.github.com/repos/{owner}/{repo}/issues/{pr_id}/comments",
        headers=headers,
        json=payload,
    )
    return response.status_code == 201


def get_pr_id(
    branch_name: str,
    owner: str = REPO_OWNER,
    repo: str = REPO_NAME,
    headers: Dict[str, Any] = HEADERS,
):
    """
    Get the id of the pull request that has `branch_name` as the head branch.

    Args:
        branch_name: Name of the branch to check.
        owner: Owner of the repository. Defaults to REPO_OWNER.
        repo: Name of the repository. Defaults to REPO_NAME.
        headers: Headers for the request.

    Returns:
        The id of the pull request if it exists, None otherwise.
    """
    # Get all open PRs
    response = requests.get(
        f"https://api.github.com/repos/{owner}/{repo}/pulls",
        headers=headers,
    )
    if response.status_code == 200:
        prs = response.json()
        # Find the PR that has `branch_name` as the head branch
        for pr in prs:
            if pr["head"]["ref"] == branch_name:
                return pr["number"]
    return None


def isbusy() -> bool:
    """
    Check whether the cronjob is running.

    Returns:
        True if the cronjob is running, False otherwise.
    """
    # pennyme package directory
    current_script_dir = os.path.dirname(os.path.abspath(__file__))
    running_tmp_path = os.path.join(current_script_dir, "../../new_data/running.tmp")
    return os.path.exists(running_tmp_path)
