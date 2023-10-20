#!/bin/bash

# Assuming the full path to your Conda executable
. /root/miniconda3/etc/profile.d/conda.sh
conda activate myenv

# Define paths to the old and new JSON files
OLD_JSON_FILE="/root/PennyMe/new_data/old_server_locations.json"
NEW_JSON_FILE="/root/PennyMe/new_data/server_locations.json"
OLD_PROBLEMS_JSON_FILE="/root/PennyMe/new_data/old_problems.json"
NEW_PROBLEMS_JSON_FILE="/root/PennyMe/new_data/problems.json"
DEBUG_PATH="/root/PennyMe/debug_new_data"

python /root/PennyMe/backend/scripts/location_differ.py --load_from_github -o /root/PennyMe/new_data -d /root/PennyMe/data/all_locations.json -s ${OLD_JSON_FILE} -a ${GCLOUD_KEY}


# Check if there is a difference in at least one of the two files, if yes, open PR
python /root/PennyMe/backend/scripts/open_diff_pull_request.py -f "$NEW_JSON_FILE" -p "$NEW_PROBLEMS_JSON_FILE"

# Move the new files to make sure that they are not mistakenly used if the location_differ fails next time
mv $NEW_PROBLEMS_JSON_FILE $DEBUG_PATH
mv $NEW_JSON_FILE $DEBUG_PATH
