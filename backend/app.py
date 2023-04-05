import json
from datetime import date
import os
from PIL import Image, ImageOps
from slack import WebClient
from slack.errors import SlackApiError

from flask import Flask, jsonify, request

app = Flask(__name__)

PATH_COMMENTS = os.path.join("..", "..", "images", "comments")
PATH_IMAGES = os.path.join("..", "..", "images")
SLACK_TOKEN = os.environ.get('SLACK_TOKEN')

client = WebClient(token=os.environ['SLACK_TOKEN'])


@app.route('/add_comment', methods=['GET'])
def add_comment():
    """
    Receives a comment and adds it to the json file
    """

    comment = str(request.args.get('comment'))
    machine_id = str(request.args.get('id'))

    path_machine_comments = os.path.join(PATH_COMMENTS, f"{machine_id}.json")
    if os.path.exists(path_machine_comments):
        with open(path_machine_comments, "r") as infile:
            # take previous comments and add paragaph
            prev_comments = "\n" + json.load(infile)[machine_id]
    else:
        prev_comments = ""

    new_comment = f"{date.today()}: {comment}"

    all_comments = {machine_id: new_comment + prev_comments}

    with open(path_machine_comments, "w") as outfile:
        json.dump(all_comments, outfile)

    # send message to slack
    send_to_slack(machine_id, "comment", new_comment)

    return jsonify({"response": 200})


@app.route('/upload_image', methods=['POST'])
def upload_image():
    machine_id = str(request.args.get('id'))

    if 'image' not in request.files:
        return 'No image file', 400

    image = request.files['image']
    image.save(os.path.join(PATH_IMAGES, f'{machine_id}.jpg'))

    # optimize file size
    img = Image.open(os.path.join(PATH_IMAGES, f'{machine_id}.jpg'))
    img = ImageOps.exif_transpose(img)
    basewidth = 400
    wpercent = (basewidth / float(img.size[0]))
    if wpercent > 1:
        return "Image uploaded successfully, no resize necessary"
    # resize
    hsize = int((float(img.size[1]) * float(wpercent)))
    img = img.resize((basewidth, hsize), Image.Resampling.LANCZOS)
    img.save(os.path.join(PATH_IMAGES, f'{machine_id}.jpg'), quality=95)

    # send message to slack
    send_to_slack(machine_id, "image", "")

    return 'Image uploaded successfully'


def send_to_slack(machine_id, upload_type, comment_text):
    if upload_type == "image":
        text = f"Image uploaded for machine {machine_id}"
    else:
        text = f"New comment for machine {machine_id}: {comment_text}"

    try:
        response = client.chat_postMessage(
            channel='#pennyme_uploads', text=text, username="PennyMe"
        )
    except SlackApiError as e:
        assert e.response["ok"] is False
        assert e.response["error"]
        raise e


def create_app():
    return app


if __name__ == '__main__':
    app.run(host='0.0.0.0')
