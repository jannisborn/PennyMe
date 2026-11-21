"""Photo availability from the same filenames served to the app."""

import re
from functools import lru_cache
from pathlib import Path


_PHOTO = re.compile(r"(?P<id>\d+)(?:\.jpg|_coin_(?P<coin>\d+)\.png)\Z")


@lru_cache(maxsize=4)
def _scan_photos(root: str, modified_ns: int) -> dict[str, list[str]]:
    inventory: dict[str, list[str]] = {}
    for path in Path(root).iterdir():
        match = _PHOTO.fullmatch(path.name)
        if match and path.is_file():
            coin = match["coin"]
            inventory.setdefault(match["id"], []).append(
                "machine" if coin is None else f"coin_{coin}"
            )
    for keys in inventory.values():
        keys.sort(key=lambda key: -1 if key == "machine" else int(key[5:]))
    return inventory


def photo_inventory(images_path: str) -> dict[str, list[str]] | None:
    """Cache one directory scan until photos are added or removed.

    An inaccessible image directory means unknown availability, not no photos.
    """
    try:
        root = Path(images_path).resolve()
        return _scan_photos(str(root), root.stat().st_mtime_ns)
    except OSError:
        return None
