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
import geopandas as gpd

from pennyme.database import get_connection, get_engine, create_tables

THIS_DIR = Path(__file__).resolve().parent
SERVER_LOCS = THIS_DIR.parent / "data" / "server_locations.json"


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


def main() -> None:
    # Check if machines table exists and handle user input
    if table_exists("machines"):
        logger.warning("Table 'machines' already exists.")
        response = (
            input("Do you want to drop the 'machines' table? (yes/no): ")
            .strip()
            .lower()
        )

        if response in ("yes", "y"):
            with get_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("DROP TABLE machines")
                conn.commit()
            logger.info("Table 'machines' dropped successfully.")
        else:
            logger.info(
                "Keeping existing 'machines' table. Proceeding with create_tables()."
            )

    # Create tables
    create_tables()
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM machines")
            count = cur.fetchone()[0]
    logger.info(f"Database connection OK. {count} machines in the table.")

    # check if server_locations.json exists
    if not SERVER_LOCS.exists():
        logger.error(f"File not found: {SERVER_LOCS}")
        sys.exit(1)

    logger.info(f"Seeding from {SERVER_LOCS} ...")

    gdf = gpd.read_file(str(SERVER_LOCS))

    # Rename geometry column to match DB schema
    gdf = gdf.rename_geometry("geom").drop(columns=["logs"], errors="ignore")

    # Normalise "null" URL strings to actual None
    for col in ("external_url", "internal_url"):
        if col in gdf.columns:
            gdf[col] = gdf[col].replace("null", None)

    # Fill optional columns that may be absent in older GeoJSON exports
    gdf.fillna({"num_coins": int(4)}, inplace=True)
    gdf.fillna({"status": "unvisited"}, inplace=True)
    gdf["num_coins"] = gdf["num_coins"].astype(int)
    gdf.fillna({"paywall": False}, inplace=True)
    gdf["paywall"] = gdf["paywall"].astype(bool)
    # print(gdf[["num_coins", "paywall"]].head(5))

    gdf.to_postgis("machines", get_engine(), if_exists="append", index=False)

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
            cur.execute("SELECT COUNT(*) FROM machines")
            count = cur.fetchone()[0]
    logger.info(f"Done. {count} machines in the database.")


if __name__ == "__main__":
    main()
