import autoroot  # noqa: F401  # initializes repo root
import json
import os
import sys
from datetime import date
from pathlib import Path

from pennyme.database import get_all_machines_geojson

MAIN_PATH = os.path.join("..", "..", "images")
DAILY_BACKUP_PATH = Path(os.path.join(MAIN_PATH, "backup_server_locations"))
KEEP_DAYS = 20

# Allow running this script from any working directory.
BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))


def _write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=4, ensure_ascii=False)
    os.replace(tmp_path, path)


def _prune_old_daily_backups(daily_dir: Path, keep_days: int) -> None:
    backups = sorted(daily_dir.glob("server_locations_*.json"))
    stale = backups[:-keep_days]
    for path in stale:
        path.unlink(missing_ok=True)


def backup_server_locations() -> None:
    """Backup the machines table to server_locations.json and keep one daily snapshot."""

    data = get_all_machines_geojson()

    latest_path = Path(MAIN_PATH) / "server_locations.json"
    _write_json_atomic(latest_path, data)

    today_str = date.today().isoformat()
    daily_path = DAILY_BACKUP_PATH / f"server_locations_{today_str}.json"
    _write_json_atomic(daily_path, data)

    _prune_old_daily_backups(DAILY_BACKUP_PATH, KEEP_DAYS)

    count = len(data.get("features", []))
    print(f"Wrote latest snapshot: {latest_path}")
    print(f"Wrote daily snapshot:  {daily_path}")
    print(f"Kept rolling window:   {KEEP_DAYS} day(s)")
    print(f"Feature count:         {count}")


def main() -> None:
    backup_server_locations()


if __name__ == "__main__":
    main()
