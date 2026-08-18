"""approve.py – Review and apply pending machine changes.

Usage (from the backend/ directory):
    python -c "from approve import approve_all; approve_all()"
    python -c "from approve import approve_one_by_one; approve_one_by_one()"
"""

import os
from pathlib import Path

from loguru import logger

from pennyme.database import (
    approve_pending_change,
    get_open_pending_changes,
    reject_pending_change,
)
from pennyme.moderation import ModerationStore

# Adjust these paths to match the server layout
_PATH_IMAGES = Path(os.path.join("..", "images"))
_MODERATION = ModerationStore(
    Path(os.path.join("..", "content_attribution.json")),
    Path(os.path.join("..", "moderation_reports.jsonl")),
)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _handle_image_rename(change: dict, machine_id: int) -> None:
    """For 'create' changes, rename pending_{change_id}.jpg → {machine_id}.jpg."""
    if change["change_type"] != "create":
        return
    src = _PATH_IMAGES / f"pending_{change['id']}.jpg"
    dst = _PATH_IMAGES / f"{machine_id}.jpg"
    if src.exists():
        src.rename(dst)
        logger.info(f"Renamed {src} → {dst}")
    else:
        logger.warning(f"Expected pending image {src} not found; skipping rename")


def _record_moderation(change: dict, machine_id: int) -> None:
    """For 'create' changes, update content attribution to the final machine ID.

    Content attribution is initially recorded in process_pending_image with the pending_id.
    On approval, we remap it to the final machine_id for proper moderation manifests.
    """
    if change["change_type"] != "create":
        return
    # Note: future enhancement to remap pending_id → machine_id in moderation store
    # For now, the attribution recorded in process_pending_image serves as the audit trail


def _display_change(change: dict) -> None:
    """Print a human-readable summary of a pending change."""
    print("\n" + "=" * 60)
    print(f"  Pending change #{change['id']}  [{change['change_type'].upper()}]")
    print("=" * 60)
    if change["change_type"] == "update":
        print(f"  Machine ID : {change['machine_id']}")
    print(f"  Name       : {change['name']}")
    print(f"  Area       : {change['area']}")
    print(f"  Address    : {change['address']}")
    print(f"  Status     : {change['machine_status']}")
    print(f"  Coords     : {change['latitude']:.5f}, {change['longitude']:.5f}")
    print(
        f"  Submitted  : {change['submitted_at']}  by {change['submitted_by'] or 'anonymous'}"
    )
    summary = change.get("change_summary") or ""
    if summary:
        print(f"  Summary    :\n{summary}")
    print()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def approve_all() -> None:
    """Apply all open pending changes without prompting."""
    changes = get_open_pending_changes()
    if not changes:
        print("No open pending changes.")
        return

    logger.info(f"Approving {len(changes)} pending change(s)…")
    for change in changes:
        try:
            machine_id = approve_pending_change(change["id"])
            _handle_image_rename(change, machine_id)
            _record_moderation(change, machine_id)
            logger.info(
                f"Approved pending change #{change['id']} "
                f"({change['change_type']}) → machine {machine_id}"
            )
        except Exception as exc:
            logger.error(f"Failed to approve pending change #{change['id']}: {exc}")

    print(f"Done. Processed {len(changes)} change(s).")


def approve_one_by_one() -> None:
    """Iterate over open changes, display each, and prompt for [a/r/s/q]."""
    changes = get_open_pending_changes()
    if not changes:
        print("No open pending changes.")
        return

    print(f"\n{len(changes)} open pending change(s) to review.\n")
    approved = rejected = skipped = 0

    for change in changes:
        _display_change(change)
        while True:
            raw = input("[a]pprove / [r]eject / [s]kip / [q]uit: ").strip().lower()
            if raw in ("a", "r", "s", "q"):
                break
            print("  Please enter a, r, s, or q.")

        if raw == "q":
            print("Quitting. Remaining changes left open.")
            break

        if raw == "s":
            skipped += 1
            continue

        if raw == "a":
            try:
                machine_id = approve_pending_change(change["id"])
                _handle_image_rename(change, machine_id)
                _record_moderation(change, machine_id)
                print(
                    f"  Approved → machine {machine_id}"
                    + (" (new)" if change["change_type"] == "create" else "")
                )
                approved += 1
            except Exception as exc:
                print(f"  ERROR approving: {exc}")
                logger.error(f"Failed to approve pending change #{change['id']}: {exc}")
        else:  # raw == "r"
            try:
                reject_pending_change(change["id"])
                print("  Rejected.")
                rejected += 1
            except Exception as exc:
                print(f"  ERROR rejecting: {exc}")
                logger.error(f"Failed to reject pending change #{change['id']}: {exc}")

    print(f"\nSummary: {approved} approved, {rejected} rejected, {skipped} skipped.")


if __name__ == "__main__":
    approve_one_by_one()
