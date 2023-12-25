import base64
import json
import logging
import os
from typing import Any, Dict, List, Optional, Tuple

import requests

from pennyme.utils import get_next_free_machine_id

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

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


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
        if response.status_code != 201:
            print("Failed to create a new branch.")
            return False
        return True
    return False


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


def commit_json_file(
    server_locations: Dict,
    branch_name: str,
    commit_message: str,
    latest_commit_sha: str,
    headers: Dict[str, Any] = HEADERS,
    file_path: str = FILE_PATH,
    body: str = "Machine updates submitted for review",
    reviewer: Optional[str] = None,
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
        print("Failed to update the file.")
        print(response)
        return

    pr_id = get_pr_id(branch_name=branch_name)
    if pr_id and did_create_new_branch:
        logger.error(
            "Seems like a PR already exists even though branch was created just now."
        )
        post_comment_to_pr(pr_id=pr_id, comment=body, headers=headers)
    elif pr_id:
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
    if response.status_code == 200:
        print(f"Reviewer {reviewer} added.")
    else:
        print(f"Failed to add reviewer {reviewer}.")


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
        print("Labels added successfully.")
    else:
        print("Failed to add labels.")


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
