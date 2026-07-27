"""Seed the machines table from the existing server_locations.json.

Run from the backend/ directory:
    python seed_db.py

This mirrors the old server_locations.json into the database.
all_locations.json stays bundled with the app and is NOT seeded here.

After loading, the identity sequence is advanced past the highest known ID so
that new user-submitted machines receive IDs that don't collide.
"""

import sys
from pathlib import Path

from loguru import logger

THIS_DIR = Path(__file__).resolve().parent
SERVER_LOCS = THIS_DIR.parent / "data" / "server_locations.json"


def main() -> None:
    from pennyme.database import get_connection, upsert_machines_from_file

    if not SERVER_LOCS.exists():
        logger.error(f"File not found: {SERVER_LOCS}")
        sys.exit(1)

    logger.info(f"Seeding from {SERVER_LOCS} ...")
    upsert_machines_from_file(str(SERVER_LOCS))

    # Advance the identity sequence so new inserts don't collide with seeded IDs.
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT setval(
                    pg_get_serial_sequence('machines', 'id'),
                    (SELECT MAX(id) FROM machines)
                )
                """
            )
            new_val = cur.fetchone()[0]
        conn.commit()
    logger.info(f"Identity sequence advanced to {new_val}")

    # Quick sanity check
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM machines WHERE approved = TRUE")
            count = cur.fetchone()[0]
    logger.info(f"Done. {count} approved machines in the database.")


if __name__ == "__main__":
    main()
