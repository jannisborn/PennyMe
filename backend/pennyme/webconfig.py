import requests
from bs4 import BeautifulSoup


def get_website(url: str):
    mhtml = requests.get(url).content
    unicode_str = mhtml.decode("utf8")
    encoded_str = unicode_str.encode("ascii", "ignore")
    website = BeautifulSoup(encoded_str, "html.parser")
    return website
