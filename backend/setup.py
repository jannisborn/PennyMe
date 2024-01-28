"""Install package."""

import io
import os
import re

from setuptools import find_packages, setup

__version__ = re.search(
    r'__version__\s*=\s*[\'"]([^\'"]*)[\'"]',
    io.open("pennyme/__init__.py", encoding="utf_8_sig").read(),
).group(1)

LONG_DESCRIPTION = ""
if os.path.exists("README.md"):
    with open("README.md") as fp:
        LONG_DESCRIPTION = fp.read()

setup(
    name="pennyme",
    version=__version__,
    description="app for collecting pressed pennys",
    long_description=LONG_DESCRIPTION,
    long_description_content_type="text/markdown",
    author="Jannis Born",
    author_email=("jannis.born@gmx.de"),
    url="https://github.com/jannisborn/pennyme",
    license="GPL-3.0 license",
    install_requires=["requests", "bs4", "googlemaps"],
    keywords=["iOS App Store", "App", "Pressed Penny", "Collecting", "Coins"],
    packages=find_packages("."),
    zip_safe=False,
    classifiers=[
        "Development Status :: 3 - Alpha",
        "Intended Audience :: Developers",
        "Intended Audience :: Science/Research",
        "License :: OSI Approved :: MIT License",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Topic :: Software Development :: Libraries :: Python Modules",
    ],
)
