import unittest

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


if __name__ == "__main__":
    unittest.main()
