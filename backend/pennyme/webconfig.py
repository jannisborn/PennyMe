import requests
from bs4 import BeautifulSoup
from typing import List


def get_website(url: str):
    mhtml = requests.get(url).content
    unicode_str = mhtml.decode("utf8")
    encoded_str = unicode_str.encode("ascii", "ignore")
    website = BeautifulSoup(encoded_str, "html.parser")
    return website


def get_elongated_coin_title(url: str) -> str:
    """
    Get the title of a url pointing to a forum entry on elongated-coin.de.
    """

    mhtml = requests.get(url).content
    unicode_str = mhtml.decode("utf8")
    encoded_str = unicode_str.encode("ascii", "ignore")
    website = BeautifulSoup(encoded_str, "html.parser")
    raw_title = str(website.find("title"))
    title = raw_title.split("Thema anzeigen - ")[-1].split("</title>")[0]
    return title


def get_elongated_coin_comments(url: str) -> List[str]:
    """
    Extract comments/posts from an elongated-coin.de site.
    """
    mhtml = requests.get(url).content
    unicode_str = mhtml.decode("utf8")
    soup = BeautifulSoup(unicode_str, "html.parser")

    # Find the last post using its class, assuming the class "post bg3" is for the last post.
    posts = soup.find_all("div", class_="post")

    comments = []
    if len(posts) >= 2:
        for post in posts[2:-1]:
            post_content = post.find("div", class_="content")
            if post_content:
                c = (
                    post_content.get_text()
                    .replace("\n", " ")
                    .replace("\t", " ")
                    .strip()
                )
                comments.append(c)
    return comments
