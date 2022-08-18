import requests
from bs4 import BeautifulSoup


LOCATION_PREFIX = "http://209.221.138.252/Locations.aspx?area="


def get_website(url: str):
    mhtml = requests.get(url).content
    unicode_str = mhtml.decode("utf8")
    encoded_str = unicode_str.encode("ascii", "ignore")
    website = BeautifulSoup(encoded_str, "html.parser")
    return website
