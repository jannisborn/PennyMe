"""Seed and backfill the machines table from the location GeoJSON files.

Run from the backend/ directory:
    python seed_db.py

For a new database, this loads server_locations.json first, then adds any
machines from all_locations.json that are not already present.
After loading, the identity sequence is advanced past the highest known ID so
that new user-submitted machines receive IDs that don't collide.
"""

import sys
import argparse
from pathlib import Path
from loguru import logger
import geopandas as gpd

from pennyme.database import get_connection, get_engine, create_tables

THIS_DIR = Path(__file__).resolve().parent
SERVER_LOCS = THIS_DIR.parent / "data" / "server_locations.json"
ALL_LOCS = THIS_DIR.parent / "data" / "all_locations.json"


def table_exists(table_name: str) -> bool:
    """Check if a table exists in the database."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_schema = 'public' 
                    AND table_name = %s
                )
                """,
                (table_name,),
            )
            return cur.fetchone()[0]


def load_locations(path: Path) -> gpd.GeoDataFrame:
    """Read and normalize a locations GeoJSON for the machines table."""
    gdf = gpd.read_file(str(path))
    # print(f"Loaded {len(gdf)} locations from {path}")
    gdf = gdf.rename_geometry("geom").drop(columns=["logs"], errors="ignore")

    for col in ("external_url", "internal_url"):
        if col in gdf.columns:
            gdf[col] = gdf[col].replace("null", None)

    gdf.fillna({"num_coins": int(4)}, inplace=True)
    gdf.fillna({"status": "unvisited"}, inplace=True)
    gdf["num_coins"] = gdf["num_coins"].astype(int)
    gdf.fillna({"paywall": False}, inplace=True)
    gdf["paywall"] = gdf["paywall"].astype(bool)
    gdf.drop(columns=["type", "notes"], errors="ignore", inplace=True)
    gdf["address"] = (
        gdf["address"].fillna("Unknown address").replace("", "Unknown address")
    )
    return gdf


def seed_missing_all_locations() -> None:
    """Insert all_locations machines whose IDs are not already in the DB."""
    if not ALL_LOCS.exists():
        logger.error(f"File not found: {ALL_LOCS}")
        sys.exit(1)

    gdf = load_locations(ALL_LOCS)
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM machines")
            existing_ids = {row[0] for row in cur.fetchall()}

    missing = gdf[~gdf["id"].isin(existing_ids)]
    if missing.empty:
        logger.info("No missing all_locations machines to add.")
        return

    missing.to_postgis("machines", get_engine(), if_exists="append", index=False)
    logger.info(f"Added {len(missing)} missing machines from {ALL_LOCS}.")


def advance_identity_sequence() -> int | None:
    """Advance the machines ID sequence if it is behind the largest row ID."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT MAX(id),
                    pg_sequence_last_value(
                        pg_get_serial_sequence('machines', 'id')::regclass
                    )
                FROM machines
                """
            )
            max_id, sequence_value = cur.fetchone()

            if max_id is not None and (
                sequence_value is None or sequence_value < max_id
            ):
                cur.execute(
                    """
                    SELECT setval(
                        pg_get_serial_sequence('machines', 'id'), %s, true
                    )
                    """,
                    (max_id,),
                )
                sequence_value = cur.fetchone()[0]
        conn.commit()

    if sequence_value is not None:
        logger.info(f"Identity sequence is at {sequence_value}")
    return sequence_value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--all-locations-only",
        action="store_true",
        help="only add missing all_locations machines; never drop or create tables",
    )
    args = parser.parse_args()

    if args.all_locations_only:
        if not table_exists("machines"):
            logger.error(
                "Table 'machines' does not exist; refusing to create or modify tables."
            )
            sys.exit(1)

        seed_missing_all_locations()
        advance_identity_sequence()
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) FROM machines")
                count = cur.fetchone()[0]
        logger.info(f"Done. {count} machines in the database.")
        return

    # Check if machines table exists and handle user input
    seed_server_locations = True
    if table_exists("machines"):
        logger.warning("Table 'machines' already exists.")
        response = (
            input(
                "Drop 'machines' and 'pending_changes' and reseed from potentially "
                "out-of-date server_locations.json? (yes/no): "
            )
            .strip()
            .lower()
        )

        if response in ("yes", "y"):
            with get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("DROP TABLE pending_changes")
                    cur.execute("DROP TABLE machines")
                conn.commit()
            logger.info("Tables 'machines' and 'pending_changes' dropped successfully.")
        else:
            logger.info(
                "Keeping existing 'machines' table; skipping server_locations.json "
                "because the database may be newer."
            )
            seed_server_locations = False

    # Create tables
    create_tables()
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM machines")
            count = cur.fetchone()[0]
    logger.info(f"Database connection OK. {count} machines in the table.")

    if seed_server_locations:
        if not SERVER_LOCS.exists():
            logger.error(f"File not found: {SERVER_LOCS}")
            sys.exit(1)

        logger.info(f"Seeding from {SERVER_LOCS} ...")
        load_locations(SERVER_LOCS).to_postgis(
            "machines", get_engine(), if_exists="append", index=False
        )

    seed_missing_all_locations()

    advance_identity_sequence()

    # Quick sanity check
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM machines")
            count = cur.fetchone()[0]
    logger.info(f"Done. {count} machines in the database.")


if __name__ == "__main__":
    main()
