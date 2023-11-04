import requests
from bs4 import BeautifulSoup


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
