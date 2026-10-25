import unittest
from datetime import datetime
from types import SimpleNamespace
from unittest.mock import Mock, patch

from pennyme.database import (
    _pending_change_display_fields,
    get_change_requests_for_submitter,
)


def pending_change(**overrides):
    values = {
        "id": 7,
        "machine_id": 42,
        "change_type": "update",
        "name": None,
        "address": None,
        "area": None,
        "latitude": None,
        "longitude": None,
        "machine_status": None,
        "num_coins": None,
        "paywall": None,
        "external_url": None,
        "internal_url": None,
        "submitted_at": datetime(2026, 10, 24, 12, 0),
        "reviewed_at": None,
        "rejection_reason": None,
        "status": "open",
        "change_summary": "",
    }
    values.update(overrides)
    return SimpleNamespace(**values)


class ChangeRequestHistoryTest(unittest.TestCase):
    def test_returns_only_fields_submitted_by_the_user(self):
        change = pending_change(
            latitude=47.3769,
            longitude=8.5417,
            change_summary="Location from: 47.3700, 8.5300 to: 47.3769, 8.5417.",
        )

        self.assertEqual(
            _pending_change_display_fields(change),
            [
                {
                    "field": "location",
                    "label": "Location",
                    "old_value": "47.3700, 8.5300",
                    "new_value": "47.37690, 8.54170",
                }
            ],
        )

    def test_returns_newest_first_and_maps_open_to_pending(self):
        change = pending_change(
            address="New address",
            change_summary="Address from: Old address to: New address",
        )
        session = Mock()
        query = session.query.return_value
        query.outerjoin.return_value = query
        query.filter.return_value = query
        query.order_by.return_value = query
        query.all.return_value = [(change, "Museum")]

        with patch("pennyme.database.get_session", return_value=session):
            result = get_change_requests_for_submitter("installation-id")

        query.outerjoin.assert_called_once()
        query.order_by.assert_called_once()
        self.assertEqual(result[0]["machine_name"], "Museum")
        self.assertEqual(result[0]["status"], "pending")
        self.assertEqual(result[0]["changed_fields"][0]["field"], "address")
        self.assertNotIn("submitted_by", result[0])
        self.assertIsNone(result[0]["rejection_reason"])
        session.close.assert_called_once_with()

    def test_history_includes_rejection_reason(self):
        change = pending_change(
            status="rejected",
            rejection_reason="The address could not be verified.",
        )
        session = Mock()
        query = session.query.return_value
        query.outerjoin.return_value = query
        query.filter.return_value = query
        query.order_by.return_value = query
        query.all.return_value = [(change, "Museum")]

        with patch("pennyme.database.get_session", return_value=session):
            result = get_change_requests_for_submitter("installation-id")

        self.assertEqual(
            result[0]["rejection_reason"],
            "The address could not be verified.",
        )

    def test_preserves_whitespace_only_changes(self):
        change = pending_change(
            name="Fisherman's Wharf",
            change_summary=("Title from: Fisherman's Wharf  to: Fisherman's Wharf"),
        )

        fields = _pending_change_display_fields(change)

        self.assertEqual(fields[0]["old_value"], "Fisherman's Wharf ")
        self.assertEqual(fields[0]["new_value"], "Fisherman's Wharf")


if __name__ == "__main__":
    unittest.main()
