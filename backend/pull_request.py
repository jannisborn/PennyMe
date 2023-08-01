import requests
import base64
import json
from datetime import datetime
import time


def push_to_github_and_open_pr(file_content, branch_name, commit_message):
    with open("github_token.json", "r") as infile:
        github_infos = json.load(infile)
    # Define GitHub repository information
    github_token = github_infos["token"]
    repo_owner = github_infos["owner"]
    repo_name = github_infos["repo"]
    base_branch = 'main'  # Replace with the appropriate base branch name

    # Create a new branch for the changes
    headers = {
        'Authorization': f'token {github_token}',
        "accept": 'application/vnd.github+json'
    }
    payload = {
        'ref': f'refs/heads/{branch_name}',
        'sha': get_latest_commit_sha(repo_owner, repo_name, base_branch),
    }
    response = requests.post(
        f'https://api.github.com/repos/{repo_owner}/{repo_name}/git/refs',
        headers=headers,
        json=payload
    )

    if response.status_code != 201:
        print('Failed to create a new branch.')
        return

    # Update the file on the newly created branch
    file_path = '/data/server_locations.json'

    file_content_encoded = base64.b64encode(
        json.dumps(file_content, indent=4, ensure_ascii=False).encode('utf-8')
    ).decode('utf-8')

    url = 'https://api.github.com/repos/jannisborn/PennyMe/contents/data/server_locations.json'
    response_sha = requests.get(url).json()["sha"]

    payload = {
        'message': commit_message,
        'content': file_content_encoded,
        'branch': branch_name,
        'sha': response_sha
    }
    response = requests.put(
        f'https://api.github.com/repos/{repo_owner}/{repo_name}/contents{file_path}',
        headers=headers,
        json=payload
    )

    if response.status_code != 200:
        print('Failed to update the file.')
        return

    # Open a pull request
    payload = {
        'title': commit_message,
        'body': 'New machine submitted for review',
        'head': branch_name,
        'base': base_branch,
    }
    response = requests.post(
        f'https://api.github.com/repos/{repo_owner}/{repo_name}/pulls',
        headers=headers,
        json=payload
    )


def get_latest_commit_sha(repo_owner, repo_name, branch):
    response = requests.get(
        f'https://api.github.com/repos/{repo_owner}/{repo_name}/git/refs/heads/{branch}'
    )
    return response.json()['object']['sha']


# Example usage
if __name__ == '__main__':
    branch_name = f'new_machine_{round(time.time())}'

    machine_title, address, area, location = (
        "Machine on Mars", "1 Mars street, Mars", "Marsstate", [1000, 1000]
    )
    multimachine = 2
    paywall = True

    # load the current server locations file
    with open("../data/server_locations.json", "r") as infile:
        server_locations = json.load(infile)
    # retrieve new ID
    new_machine_id = max(
        [item["properties"]["id"] for item in server_locations["features"]]
    ) + 1
    # add new item to json
    server_locations["features"].append(
        {
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
                    "paywall": paywall
                }
        }
    )

    commit_message = f'add new machine {new_machine_id} named {machine_title}'
    push_to_github_and_open_pr(server_locations, branch_name, commit_message)
