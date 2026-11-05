import unittest
from unittest.mock import patch

from pennyme.database import clear_machine_geojson_cache, get_all_machines_geojson


class MachineCacheTest(unittest.TestCase):
    def test_external_commits_become_visible_within_one_minute(self):
        clear_machine_geojson_cache()
        self.addCleanup(clear_machine_geojson_cache)
        with (
            patch("pennyme.database.monotonic", side_effect=[120, 179, 180]),
            patch(
                "pennyme.database._query_all_machines_geojson",
                side_effect=[{"old": True}, {"new": True}],
            ) as query,
        ):
            self.assertEqual(get_all_machines_geojson(), {"old": True})
            self.assertEqual(get_all_machines_geojson(), {"old": True})
            self.assertEqual(get_all_machines_geojson(), {"new": True})
            self.assertEqual(query.call_count, 2)
