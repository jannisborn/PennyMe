import requests
import base64
import json
from datetime import datetime
import time
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
FILE_PATH = "/data/server_locations.json"


def check_branch_exists(branch_name):
    # Check if the desired branch exists
    branch_check_url = (
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/branches/{branch_name}"
    )
    branch_check_response = requests.get(branch_check_url, headers=HEADERS)
    return branch_check_response.status_code == 200


def get_latest_branch_url(file=FILE_PATH):
    """
    Check whether the latest change is on the main or on the data branch
    Returns the respective URL as a string
    Note: We would need to change this function if we want to search for the branch with
    the latest commit.
    """
    # check if the branch already exists:
    branch_exists = check_branch_exists(DATA_BRANCH)
    # if data branch exists, the url points to the branch
    repo_url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}"
    if branch_exists:
        file_url = f"{repo_url}/contents/{file}?ref={DATA_BRANCH}"
    else:
        file_url = f"{repo_url}/contents/{file}"
    return file_url


def create_new_branch(branch_name, headers=HEADERS):
    # create a new branch if it does not exist yet
    if not check_branch_exists(branch_name):
        payload = {
            "ref": f"refs/heads/{branch_name}",
            "sha": get_latest_commit_sha(REPO_OWNER, REPO_NAME, BASE_BRANCH),
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


def load_latest_server_locations(
    branch_name=DATA_BRANCH, headers=HEADERS, file=FILE_PATH
):
    """
    Push the modified file to the github branch
    machine_update_entry: Dict, only the new machine entry that should
    be added to the server_locations json
    """

    # Load latest version of the server_locations
    file_url = get_latest_branch_url(file=file)
    response = requests.get(file_url, headers=headers)
    data = response.json()
    current_content = data["content"]
    current_content_decoded = base64.b64decode(current_content).decode("utf-8")
    server_locations = json.loads(current_content_decoded)

    # the sha of the last commit is needed later for pushing
    latest_commit_sha = data["sha"]
    return server_locations, latest_commit_sha


def push_newmachine_to_github(machine_update_entry, branch_name=DATA_BRANCH):

    server_locations, latest_commit_sha = load_latest_server_locations(
        branch_name=DATA_BRANCH
    )

    machine_id = get_next_free_machine_id(
        "../data/all_locations.json", server_locations['features']
    )
    machine_update_entry["properties"]["id"] = machine_id

    # Update the server_locations
    server_locations["features"].append(machine_update_entry)

    # make commit message
    machine_name = machine_update_entry['properties']['name']
    commit_message = f"add new machine {machine_id} named {machine_name}"

    commit_json_file(
        server_locations, branch_name, commit_message, latest_commit_sha
    )

    return machine_id


def commit_json_file(
    server_locations,
    branch_name,
    commit_message,
    latest_commit_sha,
    headers=HEADERS,
    file_path=FILE_PATH
):
    """
    Commit the server locations dictionary to branch named <branch_name>
    with the desired commit message
    """

    # create a new branch if necessary
    did_create_new_branch = create_new_branch(branch_name, headers=HEADERS)

    # Update the file on the newly created branch
    file_content_encoded = base64.b64encode(
        json.dumps(server_locations, indent=4,
                   ensure_ascii=False).encode("utf-8")
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

    # open a new pull request if the branch did not exist
    if did_create_new_branch:
        open_pull_request(commit_message, branch_name, headers=headers)


def add_pr_label(pr_id, labels, headers=HEADERS):
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/issues/{pr_id}/labels"
    response = requests.post(url, headers=headers, json={"labels": labels})
    if response.status_code == 200:
        print("Labels added successfully.")
    else:
        print("Failed to add labels.")


def open_pull_request(commit_message, branch_name, headers=HEADERS):
    # Open a pull request
    payload = {
        "title": commit_message,
        "body": "New machine submitted for review",
        "head": branch_name,
        "base": BASE_BRANCH
    }
    response = requests.post(
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/pulls",
        headers=headers,
        json=payload,
    )
    # Add label to PR if it was created successfully
    if response.status_code == 201:
        pr_id = response.json()["number"]
        add_pr_label(pr_id, ['data', 'bot'], headers=headers)
        return True
    return False


def get_latest_commit_sha(REPO_OWNER, REPO_NAME, branch):
    response = requests.get(
        f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/git/refs/heads/{branch}"
    )
    return response.json()["object"]["sha"]


# Example usage
if __name__ == "__main__":
    # branch_name = f'new_machine_{round(time.time())}'

    machine_title, address, area, location = (
        "last test",
        "1 Mars street, Mars",
        "Marsstate",
        [1000, 1000],
    )
    multimachine = 2
    paywall = True

    # retrieve new ID
    new_machine_id = 1
    # design new item to be added to the machine
    new_machine_entry = {
        "type": "Feature",
        "geometry": {
            "type": "Point",
            "coordinates": location
        },
        "properties":
            {
                "name": machine_title,
                "active": True,
                "area": area,
                "address": address,
                "status": "unvisited",
                "external_url": "null",
                "internal_url": "null",
                "latitude": location[1],
                "longitude": location[0],
                "id": new_machine_id,
                "last_updated": str(datetime.today()).split(" ")[0],
                "multimachine": multimachine,
                "paywall": paywall,
            },
    }

    push_newmachine_to_github(new_machine_entry)
