"""Private, short-lived coin cutouts for new-machine forms."""

from contextlib import contextmanager
from fcntl import LOCK_EX, flock
from hashlib import sha256
from pathlib import Path
from re import fullmatch
from shutil import rmtree
from time import time
from uuid import uuid4

from itsdangerous import BadSignature, TimestampSigner

UPLOAD_LIFETIME = 24 * 60 * 60
PREVIEW_LIFETIME = 15 * 60
MAX_UPLOAD_BYTES = 20 * 1024 * 1024


def valid_upload_id(value: str) -> bool:
    return fullmatch(r"[0-9a-f]{32}", value) is not None


def draft_key(installation_id: str, draft_id: str) -> str:
    return sha256(f"{installation_id}:{draft_id}".encode()).hexdigest()


def preview_root(images_path: str) -> Path:
    # Keep originals and cutouts outside the public image directory.
    root = Path(images_path).resolve().with_name(".pennyme-coin-previews")
    root.mkdir(mode=0o700, exist_ok=True)
    return root


@contextmanager
def locked_previews(images_path: str):
    root = preview_root(images_path)
    # The lock covers publication and attachment across workers. Image
    # processing runs outside the lock since it can take several seconds.
    with (root / ".lock").open("ab") as lock:
        flock(lock, LOCK_EX)
        yield root


def remove_expired_drafts(root: Path) -> None:
    cutoff = time() - UPLOAD_LIFETIME
    for draft in root.iterdir():
        if draft.is_dir():
            if draft.stat().st_mtime < cutoff:
                rmtree(draft)
            else:
                for path in draft.glob("*.*.png"):
                    if path.stat().st_mtime < cutoff:
                        path.unlink()


def saved_previews(draft: Path) -> dict[str, Path]:
    cutoff = time() - UPLOAD_LIFETIME
    return {
        path.stem.split(".")[1]: path
        for path in draft.glob("*.*.png")
        if path.stat().st_mtime >= cutoff
    }


def save_preview(draft: Path, source: Path) -> tuple[str, Path]:
    draft.mkdir(mode=0o700, exist_ok=True)
    upload_id = uuid4().hex
    target = draft / f"{uuid4().hex}.{upload_id}.png"
    source.rename(target)
    return upload_id, target


def preview_token(path: Path) -> str:
    preview_id, upload_id = path.stem.split(".")
    return (
        TimestampSigner(upload_id, salt="pennyme-coin-preview")
        .sign(preview_id)
        .decode()
    )


def verified_preview(draft: Path, preview_id: str, token: str) -> Path | None:
    cutoff = time() - UPLOAD_LIFETIME
    for path in draft.glob(f"{preview_id}.*.png"):
        try:
            expected = TimestampSigner(
                path.stem.split(".")[1], salt="pennyme-coin-preview"
            ).unsign(token, max_age=PREVIEW_LIFETIME)
        except BadSignature:
            return None
        if expected == preview_id.encode() and path.stat().st_mtime >= cutoff:
            return path
    return None
