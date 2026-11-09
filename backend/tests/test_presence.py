import unittest
from datetime import date, datetime, timezone
from unittest.mock import MagicMock, patch

from flask import Flask
import geopandas as gpd
from shapely.geometry import Point

from pennyme.database import _query_all_machines_geojson
from pennyme.presence import parse_location, presence_api


class PresenceTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.fix = {
            "latitude": 47.37,
            "longitude": 8.54,
            "accuracy": 5,
            "measured_at": self.now.timestamp(),
        }
        app = Flask(__name__)
        app.testing = True
        app.register_blueprint(presence_api)
        self.client = app.test_client()
        self.headers = {"X-PennyMe-Anonymous-ID": "test-contributor"}

    def test_location_validation_includes_age_accuracy_and_numeric_boundaries(self):
        for changes in [
            {"latitude": 90, "longitude": -180, "accuracy": 0},
            {"accuracy": 10, "measured_at": self.now.timestamp() - 15},
            {"measured_at": self.now.timestamp() + 5},
        ]:
            with self.subTest(changes=changes):
                parse_location({**self.fix, **changes}, self.now)
        for changes in [
            {"latitude": 90.01},
            {"longitude": -180.01},
            {"accuracy": -1},
            {"accuracy": 10.01},
            {"latitude": True},
            {"longitude": "8.54"},
            {"accuracy": float("nan")},
            {"measured_at": float("inf")},
            {"latitude": 10**400},
            {"measured_at": self.now.timestamp() - 15.01},
            {"measured_at": self.now.timestamp() + 5.01},
        ]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                parse_location({**self.fix, **changes}, self.now)

    def test_invalid_or_missing_fix_never_reaches_sql(self):
        with patch("pennyme.presence.get_connection") as connect:
            for path in [
                "/machines/nearby-confirmations",
                "/machines/42/confirm-presence",
            ]:
                for payload in [
                    None,
                    [],
                    {},
                    {**self.fix, "accuracy": 100},
                    {**self.fix, "measured_at": self.now.timestamp() - 60},
                ]:
                    with self.subTest(path=path, payload=payload):
                        response = self.client.post(
                            path, json=payload, headers=self.headers
                        )
                        self.assertEqual(response.status_code, 400)
                response = self.client.post(path, json=self.fix)
                self.assertEqual(response.status_code, 400)
            connect.assert_not_called()

    def test_candidates_are_live_geodesic_and_older_than_seven_days(self):
        connection = MagicMock()
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.fetchall.return_value = [
            {
                "id": machine_id,
                "name": f"Zoo {machine_id}",
                "latitude": 47.37,
                "longitude": 8.54,
                "num_coins": 4,
                "needs_confirmation": eligible,
            }
            for machine_id, eligible in [(42, True), (43, False), (44, True)]
        ]
        with patch("pennyme.presence.get_connection", return_value=connection):
            response = self.client.post(
                "/machines/nearby-confirmations", json=self.fix, headers=self.headers
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.json["machines"]], [42, 44])
        self.assertEqual(
            [row["id"] for row in response.json["nearby_machines"]], [42, 43, 44]
        )
        self.assertEqual(response.json["machines"][0]["num_coins"], 4)
        self.assertNotIn("needs_confirmation", response.json["machines"][0])
        sql, params = cursor.execute.call_args.args
        self.assertIn(
            "last_seen IS NULL OR last_seen < CURRENT_TIMESTAMP - INTERVAL '7 days'",
            sql,
        )
        self.assertIn("ST_DWithin(geom::geography", sql)
        self.assertIn("::geography, 20)", sql)
        self.assertIn("::geography, 120)", sql)
        # Recently confirmed and inactive neighbors must remain visible as context.
        self.assertNotIn("last_seen", sql.split("FROM machines", 1)[1])
        self.assertNotIn("machine_status", sql)
        self.assertEqual(params, (8.54, 47.37, 8.54, 47.37, 8.54, 47.37))
        connection.close.assert_called_once()

    def test_confirmation_is_one_conditional_update_of_only_last_seen(self):
        connection = MagicMock()
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.fetchone.side_effect = [
            {
                "last_seen": self.now,
                "id": 42,
                "name": "Zoo",
                "address": "Main Street",
                "area": "Germany",
                "machine_status": "retired",
                "num_coins": 4,
                "paywall": False,
                "external_url": None,
                "internal_url": None,
                "last_updated": date(2026, 10, 1),
                "latitude": 47.37,
                "longitude": 8.54,
            },
            None,
        ]
        with patch("pennyme.presence.get_connection", return_value=connection):
            first = self.client.post(
                "/machines/42/confirm-presence", json=self.fix, headers=self.headers
            )
            repeated = self.client.post(
                "/machines/42/confirm-presence", json=self.fix, headers=self.headers
            )
        self.assertEqual(first.status_code, 200)
        self.assertEqual(first.json["last_seen"], self.now.isoformat())
        self.assertEqual(
            first.json["machine"]["properties"]["machine_status"], "retired"
        )
        self.assertEqual(first.json["machine"]["properties"]["address"], "Main Street")
        self.assertEqual(repeated.status_code, 409)
        for call in cursor.execute.call_args_list:
            sql, params = call.args
            self.assertTrue(
                sql.startswith(
                    "UPDATE machines SET last_seen = CURRENT_TIMESTAMP WHERE"
                )
            )
            self.assertIn("last_seen < CURRENT_TIMESTAMP - INTERVAL '7 days'", sql)
            self.assertIn("::geography, 20)", sql)
            self.assertIn("INTERVAL '15 seconds'", sql)
            assignments = sql.split(" WHERE", 1)[0]
            self.assertNotIn("last_updated", assignments)
            self.assertNotIn("machine_status", assignments)
            self.assertEqual(params[:3], (42, 8.54, 47.37))
            self.assertEqual(params[3].tzinfo, timezone.utc)

    def test_database_failure_closes_connection_and_propagates(self):
        connection = MagicMock()
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.execute.side_effect = RuntimeError("SQL failed")
        with patch("pennyme.presence.get_connection", return_value=connection):
            with self.assertRaisesRegex(RuntimeError, "SQL failed"):
                self.client.post(
                    "/machines/42/confirm-presence", json=self.fix, headers=self.headers
                )
        self.assertEqual(connection.__exit__.call_args.args[0], RuntimeError)
        connection.close.assert_called_once()

    def test_machine_feed_serializes_unknown_and_confirmed_sightings(self):
        frame = gpd.GeoDataFrame(
            {
                "id": [1, 2],
                "last_updated": [date(2026, 10, 1)] * 2,
                "last_seen": [None, self.now],
                "external_url": [None, None],
                "internal_url": [None, None],
                "geom": [Point(8.54, 47.37)] * 2,
            },
            geometry="geom",
            crs="EPSG:4326",
        )
        with (
            patch("pennyme.database.gpd.read_postgis", return_value=frame),
            patch("pennyme.database.get_engine"),
        ):
            feed = _query_all_machines_geojson(None)
        self.assertIsNone(feed["features"][0]["properties"]["last_seen"])
        self.assertEqual(
            feed["features"][1]["properties"]["last_seen"], self.now.isoformat()
        )
        self.assertEqual(
            feed["features"][1]["properties"]["last_updated"], "2026-10-01"
        )


if __name__ == "__main__":
    unittest.main()
