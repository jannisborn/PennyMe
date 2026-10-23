import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from pennyme.database import (
    DeletedMachine,
    archive_and_delete_machine,
    approve_pending_change,
    get_nearby_machines_db,
)


class NearbyMachinesDatabaseTest(unittest.TestCase):
    def test_radius_exclusion_and_unbounded_limit_are_supported(self):
        for radius, excluded_id, limit, expected_filters in (
            (250, 42, None, 3),
            (None, None, 3, 1),
        ):
            with self.subTest(radius=radius, limit=limit):
                session = Mock()
                query = Mock()
                session.query.return_value = query
                query.filter.return_value = query
                query.order_by.return_value = query
                query.limit.return_value = query
                query.all.return_value = [
                    SimpleNamespace(
                        id=7,
                        name="Museum",
                        address="Main Street",
                        area="Switzerland",
                        machine_status="available",
                        external_url="https://pennycollector.com/machine/7",
                        distance_m=40.4,
                    )
                ]

                with patch("pennyme.database.get_session", return_value=session):
                    result = get_nearby_machines_db(
                        47.4,
                        8.6,
                        "Switzerland",
                        radius_m=radius,
                        exclude_machine_id=excluded_id,
                        limit=limit,
                    )

                self.assertEqual(query.filter.call_count, expected_filters)
                if limit is None:
                    query.limit.assert_not_called()
                else:
                    query.limit.assert_called_once_with(limit)
                self.assertEqual(result[0]["distance_m"], 40)
                self.assertEqual(
                    result[0]["external_url"],
                    "https://pennycollector.com/machine/7",
                )
                session.close.assert_called_once_with()


class PendingChangeApprovalTest(unittest.TestCase):
    def test_create_persists_the_final_machine_id_on_the_pending_change(self):
        change = SimpleNamespace(
            id=7,
            status="open",
            change_type="create",
            machine_id=None,
            reviewed_at=None,
        )
        machine = SimpleNamespace(id=42)
        session = Mock()
        session.query.return_value.filter.return_value.first.return_value = change

        with (
            patch("pennyme.database.get_session", return_value=session),
            patch("pennyme.database.Machine", return_value=machine),
            patch("pennyme.database._copy_pending_change_to_machine"),
            patch("pennyme.database._rename_pending_change_image"),
            patch("pennyme.database.clear_machine_geojson_cache"),
        ):
            result = approve_pending_change(7)

        self.assertEqual(change.machine_id, 42)
        self.assertEqual(result.machine_id, 42)
        self.assertEqual(result.change_type, "create")
        session.commit.assert_called_once_with()
        session.close.assert_called_once_with()


class DeletedMachineTest(unittest.TestCase):
    def test_archive_contains_every_machine_column_and_deletion_metadata(self):
        self.assertEqual(
            {column.name for column in DeletedMachine.__table__.columns},
            {
                "id",
                "name",
                "area",
                "address",
                "geom",
                "machine_status",
                "status",
                "num_coins",
                "paywall",
                "external_url",
                "internal_url",
                "last_updated",
                "deleted_at",
                "slack_reviewer",
                "report_id",
            },
        )

    def test_archives_and_deletes_in_one_commit(self):
        machine = SimpleNamespace(
            id=42,
            name="Museum",
            area="Switzerland",
            address="Main Street",
            geom="point",
            machine_status="available",
            status="unvisited",
            num_coins=4,
            paywall=False,
            external_url=None,
            internal_url=None,
            last_updated="2026-10-20",
        )
        session = Mock()
        query = session.query.return_value
        query.filter.return_value.with_for_update.return_value.first.return_value = (
            machine
        )
        archived = Mock()

        with (
            patch("pennyme.database.get_session", return_value=session),
            patch("pennyme.database.DeletedMachine", return_value=archived) as model,
            patch("pennyme.database.clear_machine_geojson_cache") as clear_cache,
        ):
            applied = archive_and_delete_machine(42, "U123", "report-id")

        self.assertTrue(applied)
        self.assertEqual(model.call_args.kwargs["id"], 42)
        self.assertEqual(model.call_args.kwargs["geom"], "point")
        self.assertEqual(model.call_args.kwargs["slack_reviewer"], "U123")
        self.assertEqual(model.call_args.kwargs["report_id"], "report-id")
        session.add.assert_called_once_with(archived)
        session.delete.assert_called_once_with(machine)
        session.commit.assert_called_once_with()
        session.rollback.assert_not_called()
        clear_cache.assert_called_once_with()
        session.close.assert_called_once_with()

    def test_failed_archive_rolls_back_the_deletion(self):
        machine = SimpleNamespace(
            **{
                column.name: None
                for column in DeletedMachine.__table__.columns
                if column.name not in {"deleted_at", "slack_reviewer", "report_id"}
            }
        )
        machine.id = 42
        session = Mock()
        session.query.return_value.filter.return_value.with_for_update.return_value.first.return_value = machine
        session.commit.side_effect = RuntimeError("database unavailable")

        with (
            patch("pennyme.database.get_session", return_value=session),
            patch("pennyme.database.clear_machine_geojson_cache") as clear_cache,
            self.assertRaises(RuntimeError),
        ):
            archive_and_delete_machine(42, "U123", "report-id")

        session.rollback.assert_called_once_with()
        clear_cache.assert_not_called()
        session.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
