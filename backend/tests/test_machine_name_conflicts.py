import ast
import unittest
from pathlib import Path
from unittest.mock import Mock

from flask import Flask, jsonify, request
from thefuzz import process as fuzzysearch

from pennyme.utils import find_machine_name_conflict


class MachineNameConflictTests(unittest.TestCase):
    def setUp(self):
        self.machine = {
            "id": 42,
            "name": "Museum Gift Shop",
            "address": "1 Main Street",
            "area": "Switzerland",
            "machine_status": "available",
            "distance_m": 250,
        }

    def test_exact_match_ignores_surrounding_whitespace_and_case(self):
        kind, machine, score = find_machine_name_conflict(
            "  museum gift shop  ", [self.machine]
        )

        self.assertEqual(kind, "exact")
        self.assertEqual(machine, self.machine)
        self.assertEqual(score, 100)

    def test_fuzzy_match_is_distinguished_from_exact_match(self):
        kind, machine, score = find_machine_name_conflict(
            "Museum Gift Shops", [self.machine]
        )

        self.assertEqual(kind, "similar")
        self.assertEqual(machine, self.machine)
        self.assertGreater(score, 90)

    def test_distinct_name_has_no_conflict(self):
        kind, machine, score = find_machine_name_conflict(
            "Railway Station", [self.machine]
        )

        self.assertIsNone(kind)
        self.assertIsNone(machine)
        self.assertIsNone(score)


class MachineNameSubmissionTests(unittest.TestCase):
    def setUp(self):
        # Load the real route without app.py's credential and service startup.
        source = (Path(__file__).resolve().parents[1] / "app.py").read_text()
        route = next(
            node
            for node in ast.parse(source).body
            if isinstance(node, ast.FunctionDef) and node.name == "create_machine"
        )
        self.machine = {
            "id": 42,
            "name": "Erlebnis-Zoo Hannover *Machine 6",
            "machine_status": "available",
            "distance_m": 50,
        }
        self.geocode = Mock(return_value=(False, (None, None)))
        namespace = {
            "blocked_contributor_response": lambda: None,
            "request": request,
            "jsonify": jsonify,
            "text_block_reason": lambda title: None,
            "fuzzysearch": fuzzysearch,
            "COUNTRIES": ["Germany"],
            "get_nearby_machines_db": Mock(return_value=[self.machine]),
            "find_machine_name_conflict": find_machine_name_conflict,
            "address_to_coordinates": self.geocode,
        }
        exec(
            "from __future__ import annotations\n"
            + ast.get_source_segment(source, route),
            namespace,
        )
        app = Flask(__name__)
        app.add_url_rule(
            "/create_machine", view_func=namespace["create_machine"], methods=["POST"]
        )
        self.client = app.test_client()

    def test_only_non_exact_names_can_bypass_warnings(self):
        for title, warning in [
            ("  erlebnis-zoo hannover *machine 6  ", "duplicate_machine"),
            ("Erlebnis-Zoo Hannover *Machine 7", "similar_machine"),
            ("Erlebnis-Zoo Hannover *Machine 6 (Outback)", "similar_machine"),
            ("Zoo gift shop", "nearby_machines"),
        ]:
            for confirmed in [False, True]:
                with self.subTest(title=title, confirmed=confirmed):
                    self.geocode.reset_mock()
                    response = self.client.post(
                        "/create_machine",
                        query_string={
                            "title": title,
                            "address": "Zoo Hannover",
                            "area": "Germany",
                            "lon_coord": "9.77",
                            "lat_coord": "52.38",
                            "ignore_nearby": str(confirmed).lower(),
                        },
                    )
                    if not confirmed or warning == "duplicate_machine":
                        self.assertEqual(response.status_code, 409)
                        self.assertIn(warning, response.json)
                        self.geocode.assert_not_called()
                    else:
                        # Reaching address validation proves all warnings were bypassed.
                        self.geocode.assert_called_once()
                        self.assertEqual(response.status_code, 400)
                        self.assertEqual(
                            response.json,
                            {"error": "Google Maps does not know this address"},
                        )


if __name__ == "__main__":
    unittest.main()
