import json
import tempfile
import unittest
from argparse import Namespace
from copy import deepcopy
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import MagicMock, Mock, patch

from haversine import haversine

from scripts.location_differ_api import (
    SourceEvidence,
    apply_report,
    compare,
    main,
    parse_machine_table,
    read_database,
    send_slack_reports,
    slack_change_thread,
    record_application,
    run,
    write_report,
)


def machine(mid=1, **overrides):
    return {
        "id": mid,
        "name": "Museum",
        "area": "Portugal",
        "address": "1 Main Street, Town",
        "machine_status": "retired",
        "external_url": None,
        "latitude": 40.0,
        "longitude": -8.0,
        "num_coins": 8,
        "paywall": True,
        "last_updated": "2026-10-27",
        **overrides,
    }


def source(legacy_id=319574, **overrides):
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": ["N.A.", "N.A."]},
        "properties": {
            "id": -1,
            "name": "Museum",
            "area": "Portugal",
            "address": "1 Main Street, Town",
            "machine_status": "available",
            "external_url": f"http://locations.pennycollector.com/Details.aspx?location={legacy_id}",
            **overrides,
        },
        "temporary": {
            "website_updated": "2026-10-01",
            "canonical_url": "https://pennycollector.com/locations/portugal/museum/",
        },
    }


def inputs(sources=None, machines=None, deleted=None, pending=None, problems=None):
    return {
        "snapshot_at": "2026-10-27T20:00:00Z",
        "source": sources or [source()],
        "database": {
            "machines": machines or [],
            "deleted_machines": deleted or [],
            "pending_changes": pending or [],
        },
        "github": {
            "branch": "main",
            "commit": "test-commit",
            "problems": {"type": "FeatureCollection", "features": problems or []},
            "skip": {"type": "FeatureCollection", "features": []},
        },
    }


def evidence(count=1):
    return {
        "machines": [
            {
                "label": f"Machine {i + 1}",
                "num_coins": 4,
                "coin_type": "Penny",
                "retired_or_book": False,
            }
            for i in range(count)
        ],
        "geocode": {
            "safe": True,
            "latitude": 40.0,
            "longitude": -8.0,
            "formatted_address": "1 Main Street, Town",
        },
    }


class SqlDifferReportTests(unittest.TestCase):
    def test_canonical_alias_protects_deleted_pending_and_github_exceptions(self):
        for kind in ("deleted", "pending", "problems", "skip"):
            with self.subTest(kind=kind):
                src = source()
                canonical = src["temporary"]["canonical_url"]
                data = inputs(sources=[src])
                if kind == "deleted":
                    data["database"]["deleted_machines"] = [
                        machine(name="App correction", external_url=canonical)
                    ]
                    category = "protected_deleted"
                elif kind == "pending":
                    data["database"]["pending_changes"] = [
                        {
                            "machine_id": None,
                            "change_type": "create",
                            "external_url": canonical,
                        }
                    ]
                    category = "deferred"
                else:
                    data["github"][kind]["features"] = [source(external_url=canonical)]
                    category = "known_exception"
                result = compare(
                    data, Mock(side_effect=AssertionError("Protected source inspected"))
                )
                self.assertEqual(result["records"][0]["category"], category)
                self.assertEqual(result["status_updates"], [])

    def test_canonical_link_does_not_absorb_a_distinct_sibling_machine(self):
        first, second = source(1), source(2)
        second["temporary"]["canonical_url"] += "second/"
        current = machine(external_url=first["temporary"]["canonical_url"])
        for sources in ([first, second], [second, first]):
            result = compare(
                inputs(sources=sources, machines=[current]), lambda _: evidence()
            )
            categories = {
                r["source"]["properties"]["external_url"]: r["category"]
                for r in result["records"]
            }
            self.assertEqual(
                categories[first["properties"]["external_url"]], "represented"
            )
            self.assertEqual(
                categories[second["properties"]["external_url"]], "addition"
            )

    def test_single_progress_bar_counts_only_locations_needing_inspection(self):
        sources = [source(i) for i in range(1, 6)]
        sources[1]["properties"]["machine_status"] = "Gone"
        data = inputs(
            sources=sources,
            machines=[machine(external_url=sources[0]["properties"]["external_url"])],
            problems=[sources[2]],
        )
        lookup = Mock(return_value=evidence())
        with patch(
            "scripts.location_differ_api.tqdm",
            side_effect=lambda rows, **kwargs: nullcontext(rows),
        ) as progress:
            compare(data, lookup)
        progress.assert_called_once()
        self.assertEqual(len(progress.call_args.args[0]), 2)
        self.assertEqual(lookup.call_count, 2)

    def test_bucees_duplicate_is_ignored_without_matching_or_creating(self):
        data = inputs(sources=[source(460896)], machines=[machine(9549), machine(8003)])
        fetch = Mock(side_effect=AssertionError("Confirmed duplicate needs no lookup"))
        item = compare(data, fetch)["records"][0]
        self.assertEqual(
            (item["category"], item["registry"]), ("known_exception", "local")
        )
        self.assertIn("466359", item["reason"])

    def test_universal_scans_region_even_if_listing_already_has_a_link(self):
        src = source(424410, name="Universal Studios Florida", area="Florida")

        def local(mid, **kw):
            return machine(
                mid, area="Florida", latitude=28.4749822, longitude=-81.4665043, **kw
            )

        db = [
            local(1, external_url=src["properties"]["external_url"]),
            local(2, name="The Mummy"),
            local(3, name="Transformers", external_url="null"),
            local(4, name="Awaiting edit"),
            local(5, external_url="https://example.com/app-link"),
            machine(6, area="Florida", latitude=28.49, longitude=-81.4665),
            machine(7),  # An identically named machine in another region.
        ]
        pending = {**local(4), "machine_id": 4, "change_type": "update"}
        data = inputs(sources=[src], machines=db, pending=[pending], deleted=[local(8)])
        before = deepcopy(data)
        fetch = Mock(
            side_effect=AssertionError("Regional listing never creates devices")
        )
        result = compare(data, fetch)
        item = result["records"][0]
        self.assertEqual(item["category"], "regional_links")
        self.assertEqual([r["machine_id"] for r in item["link_updates"]], [2, 3])
        self.assertEqual(item["pending_machine_ids"], [4])
        self.assertEqual(data, before)
        with tempfile.TemporaryDirectory() as directory:
            summary = write_report(data, result, directory)
            changes = json.loads((Path(directory) / "planned_changes.json").read_text())
            self.assertEqual(summary["proposed_machine_additions"], 0)
            self.assertEqual(summary["proposed_link_additions"], 2)
            self.assertEqual([r["machine_id"] for r in changes["link_updates"]], [2, 3])
            self.assertEqual(changes["machine_deletions"], [])

    def test_specific_source_wins_over_regional_fallback_in_either_order(self):
        regional = source(424410, name="Universal Studios Florida", area="Florida")
        specific = source(123, name="The Mummy", area="Florida")
        current = machine(
            1,
            name="The Mummy",
            area="Florida",
            latitude=28.4749822,
            longitude=-81.4665043,
        )
        detail = evidence()
        detail["geocode"].update(
            latitude=current["latitude"], longitude=current["longitude"]
        )
        for sources in ([regional, specific], [specific, regional]):
            result = compare(
                inputs(sources=sources, machines=[current]), lambda _: detail
            )
            self.assertEqual(
                next(r for r in result["records"] if r["category"] == "regional_links")[
                    "link_updates"
                ],
                [],
            )
            self.assertEqual(
                next(r for r in result["records"] if r["category"] == "link")[
                    "after_url"
                ],
                specific["properties"]["external_url"],
            )

    def test_database_snapshot_enforces_read_only_and_rolls_back(self):
        connection = MagicMock()
        connection.__enter__.return_value = connection
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.fetchone.return_value = {"transaction_read_only": "on"}
        cursor.fetchall.side_effect = [[machine()], [], []]
        with tempfile.TemporaryDirectory() as directory:
            credentials = Path(directory) / "login.json"
            credentials.write_text(json.dumps({"host": "test-only"}))
            with patch(
                "scripts.location_differ_api.psycopg2.connect", return_value=connection
            ):
                snapshot = read_database(credentials)
        connection.set_session.assert_called_once_with(
            readonly=True, isolation_level="REPEATABLE READ"
        )
        connection.rollback.assert_called_once_with()
        self.assertEqual(len(snapshot["machines"]), 1)
        self.assertTrue(
            all(
                call.args[0].startswith(("SELECT", "SHOW", "SET LOCAL"))
                for call in cursor.execute.call_args_list
            )
        )

    def test_existing_values_and_distinct_ids_are_never_overwritten(self):
        src = source()
        current = [
            machine(1, external_url=src["properties"]["external_url"]),
            machine(
                2,
                external_url=src["properties"]["external_url"].replace(
                    "http:", "https:"
                ),
            ),
        ]
        data = inputs(machines=current)
        before = deepcopy(data)
        fetch = Mock(
            side_effect=AssertionError("Existing locations need no detail requests")
        )
        result = compare(data, fetch)
        self.assertEqual(result["records"][0]["category"], "represented")
        self.assertEqual(result["records"][0]["machine_ids"], [1, 2])
        self.assertEqual(len(result["status_disagreements"]), 2)
        self.assertEqual(data, before)
        fetch.assert_not_called()

    def test_fills_only_a_unique_blank_link_and_keeps_machine_status(self):
        result = compare(inputs(machines=[machine()]), lambda _: evidence())
        item = result["records"][0]
        self.assertEqual(item["category"], "link")
        self.assertEqual(item["machine_id"], 1)
        self.assertEqual(item["candidates"][0]["machine_status"], "retired")
        for current, expected in [
            ([machine(1), machine(2)], "review"),
            (
                [machine(external_url="https://example.com/museum")],
                "represented_by_identity",
            ),
        ]:
            self.assertEqual(
                compare(inputs(machines=current), lambda _: evidence())["records"][0][
                    "category"
                ],
                expected,
            )

    def test_deleted_and_pending_machines_are_not_recreated(self):
        deleted = machine(external_url=source()["properties"]["external_url"])
        fetch = Mock(side_effect=AssertionError("Known deletion needs no requests"))
        self.assertEqual(
            compare(inputs(deleted=[deleted]), fetch)["records"][0]["category"],
            "protected_deleted",
        )
        pending = {**machine(), "machine_id": None, "change_type": "create"}
        self.assertEqual(
            compare(inputs(pending=[pending]), lambda _: evidence())["records"][0][
                "category"
            ],
            "pending",
        )
        pending_update = {**machine(), "machine_id": 1, "change_type": "update"}
        self.assertEqual(
            compare(
                inputs(machines=[machine()], pending=[pending_update]),
                lambda _: evidence(),
            )["records"][0]["category"],
            "pending",
        )

    def test_duplicate_sources_add_distinct_spaced_pins_and_only_missing_siblings(self):
        sources = [source(1), source(2)]
        data = inputs(sources=sources)
        result = compare(data, lambda _: evidence())
        self.assertEqual(
            [r["category"] for r in result["records"]], ["addition", "addition"]
        )
        with tempfile.TemporaryDirectory() as directory:
            write_report(data, result, directory)
            additions = json.loads((Path(directory) / "report.json").read_text())[
                "additions"
            ]
            distance = haversine(
                tuple(additions[0][k] for k in ("latitude", "longitude")),
                tuple(additions[1][k] for k in ("latitude", "longitude")),
                unit="m",
            )
            self.assertAlmostEqual(distance, 10.1, places=1)
        existing = machine(external_url=sources[0]["properties"]["external_url"])
        for order in (sources, sources[::-1]):
            result = compare(
                inputs(sources=order, machines=[existing]), lambda _: evidence()
            )
            self.assertEqual(
                sorted(r["category"] for r in result["records"]),
                ["addition", "represented"],
            )
        result = compare(
            inputs(sources=sources, machines=[machine()]), lambda _: evidence()
        )
        self.assertEqual(
            [r["category"] for r in result["records"]], ["link", "addition"]
        )

    def test_coordinates_match_and_weak_neighbors_do_not_block_new_machines(self):
        near = machine(name="Another attraction", address="2 Side Street")
        self.assertEqual(
            compare(inputs(machines=[near]), lambda _: evidence())["records"][0][
                "category"
            ],
            "link",
        )
        near["latitude"] += 0.001
        self.assertEqual(
            compare(inputs(machines=[near]), lambda _: evidence())["records"][0][
                "category"
            ],
            "addition",
        )
        detail = evidence()
        detail["geocode"]["safe"] = False
        self.assertEqual(
            compare(inputs(), lambda _: detail)["records"][0]["category"], "addition"
        )

    def test_confirmed_identity_survives_user_corrections_and_deletion(self):
        src = source(481162, name="Basilica St. Michael")
        corrected = machine(
            7294, name="Corrected title", address="Corrected address", latitude=42.0
        )
        data = inputs(sources=[src], machines=[corrected])
        before = deepcopy(data)
        result = compare(data, lambda _: evidence())["records"][0]
        self.assertEqual((result["category"], result["machine_id"]), ("link", 7294))
        self.assertEqual(data, before)
        for db in (inputs(sources=[src], deleted=[corrected]), inputs(sources=[src])):
            self.assertEqual(
                compare(db, lambda _: evidence())["records"][0]["category"],
                "protected_deleted",
            )
        corrected["external_url"] = src["properties"]["external_url"]
        fetch = Mock(side_effect=AssertionError("Never regeocode app corrections"))
        self.assertEqual(
            compare(inputs(sources=[src], machines=[corrected]), fetch)["records"][0][
                "category"
            ],
            "represented",
        )

    def test_exact_identity_beats_geocoder_pin_and_linked_ambiguity_needs_no_action(
        self,
    ):
        src = source(name="Berjaya Times Square Theme Park")
        db = [
            machine(1, name=src["properties"]["name"], latitude=40.0001),
            machine(
                2,
                name="Berjaya Times Square",
                address="Elsewhere",
                external_url="https://example.com/old",
            ),
        ]
        item = compare(inputs(sources=[src], machines=db), lambda _: evidence())[
            "records"
        ][0]
        self.assertEqual((item["category"], item["machine_id"]), ("link", 1))
        db = [
            machine(1, external_url="https://example.com/a"),
            machine(2, external_url="https://example.com/b"),
        ]
        item = compare(inputs(machines=db), lambda _: evidence())["records"][0]
        self.assertEqual(item["category"], "represented_by_identity")
        self.assertEqual(item["machine_ids"], [1, 2])

    def test_one_proposed_row_per_physical_machine_and_accumulating_problems(self):
        old_problem = source(2, name="Known exception")
        old_problem["problem"] = "Permanent manual decision"
        data = inputs(
            sources=[
                source(1, name="New venue"),
                old_problem,
                source(3, name="Unknown table"),
            ],
            problems=[old_problem],
            machines=[
                machine(1, name="Unknown table"),
                machine(2, name="Unknown table"),
            ],
        )

        def lookup(src):
            result = evidence(2)
            if src["properties"]["name"] == "Unknown table":
                result["machines"][0]["num_coins"] = None
            if src["properties"]["name"] == "New venue":
                result["geocode"]["latitude"] += 1
            return result

        result = compare(data, lookup)
        with tempfile.TemporaryDirectory() as directory:
            summary = write_report(data, result, directory)
            report = json.loads((Path(directory) / "report.json").read_text())
            problems = json.loads(
                (Path(directory) / "problems.proposed.json").read_text()
            )
            self.assertEqual(summary["proposed_machine_additions"], 2)
            self.assertEqual(len({a["proposed_key"] for a in report["additions"]}), 2)
            self.assertTrue(all(a["machine_id"] is None for a in report["additions"]))
            self.assertEqual(problems["features"][0], old_problem)
            self.assertEqual(len(problems["features"]), 2)
            preview = json.loads((Path(directory) / "slack_preview.json").read_text())
            self.assertFalse(preview["sent"])
            self.assertIn("changes by area", preview["thread_messages"][0])
            self.assertIn("2 new machines", preview["thread_messages"][0])
            self.assertEqual(preview["thread_messages"][1].count("Add machine:"), 2)
            self.assertEqual(
                preview["root_text"],
                "Screened 3 PennyCollector listings; SQL: 2 machines.\n"
                "Dry run: 2 machines to add; 0 links to add; 0 statuses to change; links to remove from 0 machines.",
            )

    def test_relaxed_identity_ignores_unrelated_neighbors_and_partial_geocodes(self):
        src = source(name="Kitzsteinhorn ‘Top of Salzburg’", address="Kaprun")
        db = [
            machine(7719, name="Kitzsteinhorn Top of Salzburg", address="2. OG"),
            machine(2, name="Unrelated Gift Shop"),
        ]
        detail = evidence()
        detail["geocode"]["safe"] = False
        result = compare(inputs(sources=[src], machines=db), lambda _: detail)
        self.assertEqual(result["records"][0]["category"], "link")
        self.assertEqual(result["records"][0]["machine_id"], 7719)

        detail["geocode"]["latitude"] += 0.001
        for source_name, target_name, expected in [
            ("Iglesia de San Francisco", "Templo de San Francisco", "link"),
            ("Museum Gift Shop", "Different Gift Shop", "addition"),
        ]:
            result = compare(
                inputs(
                    sources=[source(name=source_name)],
                    machines=[machine(name=target_name)],
                ),
                lambda _: detail,
            )
            self.assertEqual(result["records"][0]["category"], expected)

    def test_notification_ledger_repeats_counts_but_not_unchanged_problems(self):
        data = inputs(machines=[machine(1), machine(2)])
        comparison = compare(data, lambda _: evidence())
        client = Mock()
        client.chat_postMessage.return_value = {"ok": True, "ts": "1.0"}
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("scripts.location_differ_api.time.sleep"),
        ):
            root = Path(directory)
            state = root / "state.json"
            write_report(data, comparison, root)
            first = send_slack_reports(root, state, client=client)
            self.assertEqual(first["new_or_changed"], 1)
            self.assertEqual(client.chat_postMessage.call_count, 3)
            client.reset_mock()
            self.assertTrue(
                send_slack_reports(root, state, client=client)["already_sent"]
            )
            client.chat_postMessage.assert_not_called()
            data["snapshot_at"] = "2026-10-28T20:00:00Z"
            write_report(data, comparison, root)
            second = send_slack_reports(root, state, client=client)
            self.assertEqual(second["new_or_changed"], 0)
            self.assertEqual(second["unresolved"], 1)
            self.assertEqual(client.chat_postMessage.call_count, 2)
            self.assertNotIn("thread_ts", client.chat_postMessage.call_args.kwargs)

    def test_failed_problem_delivery_is_retried_without_reposting_counts(self):
        data = inputs(machines=[machine(1), machine(2)])
        comparison = compare(data, lambda _: evidence())
        client = Mock()
        client.chat_postMessage.side_effect = [
            {"ok": True, "ts": "1"},
            {"ok": True, "ts": "2"},
            RuntimeError("Slack unavailable"),
        ]
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("scripts.location_differ_api.time.sleep"),
        ):
            root = Path(directory)
            state = root / "state.json"
            write_report(data, comparison, root)
            with self.assertRaisesRegex(RuntimeError, "Slack unavailable"):
                send_slack_reports(root, state, client=client)
            self.assertEqual(
                json.loads(state.read_text())["#pennyme_approvals"]["cases"], {}
            )
            client.reset_mock()
            client.chat_postMessage.side_effect = None
            client.chat_postMessage.return_value = {"ok": True, "ts": "3"}
            sent = send_slack_reports(root, state, client=client)
            self.assertTrue(sent["complete"])
            client.chat_postMessage.assert_called_once()
            self.assertEqual(client.chat_postMessage.call_args.kwargs["thread_ts"], "2")

    def test_change_thread_summarizes_areas_before_listing_every_change(self):
        report = {
            "additions": [
                {
                    "name": "Museum & <shop>",
                    "area": "Portugal",
                    "external_url": "https://example.com/new",
                    "machine_id": None,
                    "proposed_key": "new:1",
                }
            ],
            "links": [
                {
                    "name": "Website name",
                    "pennyme_name": "App name",
                    "area": "Austria",
                    "after_url": "https://example.com/link",
                    "machine_id": 7,
                }
            ],
            "status_updates": [
                {
                    "name": "Museum",
                    "area": "Portugal",
                    "external_url": "https://example.com/status",
                    "machine_id": 8,
                    "pennyme_status": "retired",
                    "target_status": "available",
                }
            ],
        }
        messages = slack_change_thread(report)
        self.assertEqual(len(messages), 2)
        self.assertIn("Proposed (dry run)", messages[0])
        self.assertLess(messages[0].index("Austria"), messages[0].index("Portugal"))
        self.assertIn("Portugal*: 1 new machine; 1 retired → available", messages[0])
        self.assertIn("Austria*: 1 link added", messages[0])
        self.assertIn(
            "Add machine: <https://example.com/new|Museum &amp; &lt;shop&gt;>",
            messages[1],
        )
        self.assertIn(
            "Add link: <https://example.com/link|App name> (SQL #7)", messages[1]
        )
        self.assertIn("(SQL #8): retired → available", messages[1])
        receipt = {
            "machines_added": [{"proposed_key": "new:1", "machine_id": 100}],
            "links_added": [],
            "statuses_changed": [
                {"machine_id": 8, "from": "retired", "to": "available"}
            ],
        }
        applied = slack_change_thread(report, receipt)
        self.assertIn("Applied changes", applied[0])
        self.assertNotIn("Austria", "\n".join(applied))
        self.assertIn("(SQL #100)", applied[1])
        self.assertIn("Added machine:", applied[1])
        self.assertNotIn("dry run", "\n".join(applied))
        self.assertEqual(
            slack_change_thread({"additions": [], "links": [], "status_updates": []}),
            [],
        )

    def test_change_thread_chunks_preserve_every_change_and_all_summaries_first(self):
        rows = [
            {
                "name": f"Machine {i}",
                "area": f"Area {i:03}",
                "external_url": f"https://example.com/{i}",
                "machine_id": i,
                "pennyme_status": "available",
                "target_status": "retired",
            }
            for i in range(160)
        ]
        messages = slack_change_thread(
            {"additions": [], "links": [], "status_updates": rows}
        )
        self.assertGreater(len(messages), 3)
        self.assertTrue(all(len(message) <= 3000 for message in messages))
        text = "\n".join(messages)
        summary_end = text.index("Every individual change")
        for row in rows:
            self.assertIn(f"{row['area']}*: 1 available → retired", text[:summary_end])
            self.assertEqual(text[summary_end:].count(f"(SQL #{row['machine_id']})"), 1)

    def test_diff_thread_delivery_retries_and_backfills_existing_root(self):
        data = inputs(machines=[machine()])
        comparison = compare(data, lambda _: evidence())
        client = Mock()
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("scripts.location_differ_api.time.sleep"),
        ):
            root = Path(directory)
            state = root / "state.json"
            write_report(data, comparison, root)
            client.chat_postMessage.side_effect = [
                {"ok": True, "ts": "diff"},
                {"ok": True, "ts": "summary"},
                RuntimeError("Thread interrupted"),
            ]
            with self.assertRaisesRegex(RuntimeError, "Thread interrupted"):
                send_slack_reports(root, state, client=client)
            calls = client.chat_postMessage.call_args_list
            self.assertNotIn("thread_ts", calls[0].kwargs)
            self.assertEqual(calls[1].kwargs["thread_ts"], "diff")
            self.assertEqual(calls[2].kwargs["thread_ts"], "diff")
            client.reset_mock()
            client.chat_postMessage.side_effect = None
            client.chat_postMessage.return_value = {"ok": True, "ts": "rest"}
            send_slack_reports(root, state, client=client)
            self.assertEqual(client.chat_postMessage.call_count, 2)
            self.assertIn(
                "Every individual change",
                client.chat_postMessage.call_args_list[0].kwargs["text"],
            )
            self.assertEqual(
                client.chat_postMessage.call_args_list[0].kwargs["thread_ts"], "diff"
            )
            self.assertIn(
                "problem report",
                client.chat_postMessage.call_args_list[1].kwargs["text"],
            )
            client.reset_mock()
            self.assertTrue(
                send_slack_reports(root, state, client=client)["already_sent"]
            )
            client.chat_postMessage.assert_not_called()
            # A report delivered by the previous script has root timestamps but
            # no change-thread receipts. Append details without reposting roots.
            ledger = json.loads(state.read_text())
            saved = next(iter(ledger["#pennyme_approvals"]["runs"].values()))
            saved.pop("diff_threads")
            state.write_text(json.dumps(ledger))
            send_slack_reports(root, state, client=client)
            self.assertEqual(client.chat_postMessage.call_count, 2)
            self.assertTrue(
                all(
                    call.kwargs.get("thread_ts") == "diff"
                    for call in client.chat_postMessage.call_args_list
                )
            )

    def test_inactive_sources_and_transient_failures_do_not_become_additions(self):
        result = compare(
            inputs(sources=[source(1, machine_status="Gone"), source(2)]),
            lambda _: {"error": "Temporary access failure"},
        )
        self.assertEqual(
            [r["category"] for r in result["records"]],
            ["unavailable_unrepresented", "deferred"],
        )
        with self.assertRaisesRegex(ValueError, "Duplicate PennyMe"):
            compare(inputs(machines=[machine(1), machine(1)]), lambda _: evidence())

    def test_different_products_of_one_machine_are_not_separate_machine_additions(self):
        details = evidence(2)
        details["machines"][0]["label"] = "Machine 1 (Eurocent)"
        details["machines"][1]["label"] = "Machine 1 (Token)"
        item = compare(inputs(), lambda _: details)["records"][0]
        self.assertEqual(item["category"], "addition")
        self.assertEqual(len(item["devices"]), 1)
        self.assertEqual(item["devices"][0]["num_coins"], 4)
        details["machines"][0]["label"] = "Penny Machine 1"
        details["machines"][1]["label"] = "Medallion Machine 1"
        self.assertEqual(
            len(compare(inputs(), lambda _: details)["records"][0]["devices"]), 1
        )

    def test_geocoding_fallback_reverse_address_and_transient_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            detail = SourceEvidence(directory, geocode=False)
            detail.cache["legacy:319574"] = {"machines": evidence()["machines"]}
            detail.maps = Mock()
            detail.maps.geocode.side_effect = [
                [],
                [
                    {
                        "geometry": {
                            "location": {"lat": 40, "lng": -8},
                            "location_type": "APPROXIMATE",
                        },
                        "types": ["locality"],
                        "address_components": [],
                        "formatted_address": "Town",
                    }
                ],
            ]
            detail.maps.reverse_geocode.return_value = [
                {"formatted_address": "Town, Country"}
            ]
            geo = detail.get(source())["geocode"]
            self.assertEqual(
                (geo["latitude"], geo["reverse_address"]), (40, "Town, Country")
            )
            self.assertFalse(geo["safe"])
            self.assertEqual(detail.maps.geocode.call_count, 2)
            detail.get(source())
            self.assertEqual(detail.maps.geocode.call_count, 2)
            detail.session.close()

    def test_complete_address_geocode_wins_over_partial_venue_match(self):
        with tempfile.TemporaryDirectory() as directory:
            detail = SourceEvidence(directory, geocode=False)
            detail.cache["legacy:319574"] = {"machines": evidence()["machines"]}
            partial = {
                "geometry": {
                    "location": {"lat": 40.001, "lng": -8},
                    "location_type": "ROOFTOP",
                },
                "types": ["church"],
                "partial_match": True,
                "address_components": [
                    {"types": ["country"], "long_name": "Portugal", "short_name": "PT"}
                ],
            }
            exact = deepcopy(partial)
            exact["partial_match"] = False
            exact["geometry"]["location"]["lat"] = 40
            detail.maps = Mock()
            detail.maps.geocode.side_effect = [[partial], [exact]]
            geo = detail.get(source())["geocode"]
            self.assertEqual(geo["latitude"], 40)
            self.assertFalse(geo["partial_match"])
            self.assertEqual(geo["query"], "1 Main Street, Town, Portugal")
            # A complete street/region centroid is less useful than the partial
            # venue point; it must not move a known museum/mountain match away.
            detail.cache["legacy:319574"].pop("geocode")
            exact["geometry"]["location_type"] = "GEOMETRIC_CENTER"
            detail.maps.geocode.side_effect = [[partial], [exact]]
            detail.maps.reverse_geocode.return_value = []
            geo = detail.get(source())["geocode"]
            self.assertEqual(geo["latitude"], 40.001)
            detail.session.close()

    def test_parses_actual_machine_table_structure_and_rejects_partial_pages(self):
        html = '<table class="pc-machines"><caption>2 machines</caption><tbody><tr><th>Machine 1</th><td>4</td><td>Penny</td></tr><tr><th>Retired A</th><td>?</td><td>Penny</td></tr></tbody></table>'
        rows = parse_machine_table(html)
        self.assertEqual(rows[0]["num_coins"], 4)
        self.assertTrue(rows[1]["retired_or_book"])
        for invalid in [
            "<html>Just a moment...</html>",
            html.replace("2 machines", "3 machines"),
        ]:
            with self.assertRaises(ValueError):
                parse_machine_table(invalid)


class SqlDifferStatusTests(unittest.TestCase):
    def linked_data(
        self,
        pin_status="retired",
        website_status="available",
        pin_date="2026-10-10",
        website_date="2026-10-20",
        count=1,
    ):
        src = source(machine_status=website_status)
        src["temporary"]["website_updated"] = website_date
        return inputs(
            sources=[src],
            machines=[
                machine(
                    i + 1,
                    machine_status=pin_status,
                    last_updated=pin_date,
                    external_url=src["properties"]["external_url"],
                )
                for i in range(count)
            ],
        )

    def compare(self, data):
        return compare(
            data,
            Mock(
                side_effect=AssertionError("Linked statuses need no detail inspection")
            ),
        )

    def test_all_historical_status_transitions_and_unchanged_equivalents(self):
        mapping = {
            "available": "available",
            "Gone": "retired",
            "Moved": "retired",
            "Out of Order": "out-of-order",
        }
        for before in ("available", "retired", "out-of-order"):
            for website, target in mapping.items():
                with self.subTest(before=before, website=website):
                    data = self.linked_data(before, website)
                    snapshot = deepcopy(data)
                    result = self.compare(data)
                    self.assertEqual(
                        len(result["status_updates"]), int(before != target)
                    )
                    if before != target:
                        self.assertEqual(
                            result["status_updates"][0]["target_status"], target
                        )
                    self.assertEqual(data, snapshot)

    def test_any_pin_edit_is_confirmation_and_equal_website_dates_qualify(self):
        for pin_date, website_date, outcome in (
            ("2026-10-21", "2026-10-20", "preserved"),
            ("2026-10-20", "2026-10-20", "planned"),
            ("2026-10-19", "2026-10-20", "planned"),
            ("2026-10-26", "2026-10-27", "deferred"),
            ("2026-10-27", "2026-10-27", "deferred"),
        ):
            with self.subTest(pin_date=pin_date, website_date=website_date):
                result = self.compare(
                    self.linked_data(pin_date=pin_date, website_date=website_date)
                )
                self.assertEqual(
                    result["status_disagreements"][0]["disposition"], outcome
                )
                self.assertEqual(
                    len(result["status_updates"]), int(outcome == "planned")
                )

    def test_shared_url_consistency_and_historical_guard_order(self):
        data = self.linked_data(count=5)
        self.assertEqual(len(self.compare(data)["status_updates"]), 5)
        data["database"]["machines"][0]["machine_status"] = "available"
        result = self.compare(data)
        self.assertEqual(result["status_updates"], [])
        self.assertEqual(result["records"][0]["category"], "review")
        data = self.linked_data(count=2)
        data["database"]["machines"][1]["last_updated"] = "2026-10-11"
        result = self.compare(data)
        self.assertEqual(result["status_updates"], [])
        self.assertIn("different last_updated", result["records"][0]["reason"])
        # Matching states skip the date conflict, as in the historical differ.
        data["source"][0]["properties"]["machine_status"] = "Gone"
        self.assertEqual(self.compare(data)["records"][0]["category"], "represented")

    def test_pending_edits_exceptions_and_deletions_block_status_writes(self):
        data = self.linked_data(count=2)
        data["database"]["pending_changes"] = [
            {**machine(99), "machine_id": 1, "change_type": "update"}
        ]
        result = self.compare(data)
        self.assertEqual(result["status_updates"], [])
        self.assertTrue(
            all(r["disposition"] == "deferred" for r in result["status_disagreements"])
        )
        for registry in ("problems", "skip"):
            data = self.linked_data()
            data["github"][registry]["features"] = [data["source"][0]]
            self.assertEqual(self.compare(data)["status_updates"], [])
        data = self.linked_data()
        data["database"]["deleted_machines"] = data["database"]["machines"]
        data["database"]["machines"] = []
        result = self.compare(data)
        self.assertEqual(result["status_updates"], [])
        self.assertEqual(result["records"][0]["category"], "protected_deleted")

    def test_universal_is_link_only_for_active_and_inactive_venue_status(self):
        for website in ("available", "Gone", "Out of Order"):
            data = self.linked_data(website_status=website)
            url = source(424410)["properties"]["external_url"]
            data["source"][0]["properties"]["external_url"] = url
            data["database"]["machines"][0].update(
                external_url=url,
                area="Florida",
                latitude=28.4749822,
                longitude=-81.4665043,
            )
            result = self.compare(data)
            self.assertEqual(result["status_updates"], [])
            self.assertEqual(result["records"][0]["category"], "regional_links")
            self.assertTrue(
                all(
                    r["disposition"] == "preserved"
                    for r in result["status_disagreements"]
                )
            )

    def test_legacy_and_canonical_aliases_cannot_hide_conflicting_states(self):
        data = self.linked_data(count=2)
        data["database"]["machines"][1].update(
            external_url=data["source"][0]["temporary"]["canonical_url"],
            machine_status="available",
        )
        result = self.compare(data)
        self.assertEqual(result["status_updates"], [])
        self.assertEqual(result["records"][0]["category"], "review")
        # Two website IDs proposing different statuses for one canonical match.
        data = self.linked_data()
        data["database"]["machines"][0]["external_url"] = data["source"][0][
            "temporary"
        ]["canonical_url"]
        other = deepcopy(data["source"][0])
        other["properties"].update(
            external_url=source(2)["properties"]["external_url"],
            machine_status="Out of Order",
        )
        data["source"].append(other)
        result = self.compare(data)
        self.assertEqual(result["status_updates"], [])
        self.assertTrue(all(r["category"] == "review" for r in result["records"]))

    def test_alias_agreeing_with_pin_still_blocks_a_contradictory_status_change(self):
        data = self.linked_data(pin_status="available", website_status="Gone", count=2)
        data["database"]["machines"][1]["external_url"] = data["source"][0][
            "temporary"
        ]["canonical_url"]
        other = deepcopy(data["source"][0])
        other["properties"].update(
            external_url=source(2)["properties"]["external_url"],
            machine_status="available",
        )
        data["source"].append(other)
        for sources in (data["source"], list(reversed(data["source"]))):
            with self.subTest(
                order=[s["properties"]["machine_status"] for s in sources]
            ):
                result = self.compare({**data, "source": sources})
                self.assertEqual(result["status_updates"], [])
                self.assertTrue(
                    all(r["category"] == "review" for r in result["records"])
                )
                self.assertTrue(
                    all(
                        r["disposition"] == "review"
                        for r in result["status_disagreements"]
                    )
                )
                review = next(
                    r for r in result["records"] if len(r["machine_ids"]) == 2
                )
                self.assertEqual({c["id"] for c in review["candidates"]}, {1, 2})

    def test_status_plan_report_apply_receipt_and_atomic_failure(self):
        for fail_second in (False, True):
            with (
                self.subTest(fail_second=fail_second),
                tempfile.TemporaryDirectory() as directory,
            ):
                data = self.linked_data(count=2)
                summary = write_report(data, self.compare(data), directory)
                self.assertEqual(summary["proposed_status_changes"], 2)
                self.assertEqual(summary["preserved_status_disagreements"], 0)
                self.assertEqual(summary["status_changes_by_target"], {"available": 2})
                plan = json.loads(Path(directory, "planned_changes.json").read_text())
                self.assertEqual(
                    [r["set"] for r in plan["status_updates"]],
                    [{"machine_status": "available"}] * 2,
                )
                self.assertIn(
                    "2 statuses to change",
                    Path(directory, "slack_preview.txt").read_text(),
                )
                report = json.loads(Path(directory, "report.json").read_text())
                credentials = Path(directory, "db.json")
                credentials.write_text("{}")
                connection = MagicMock()
                cursor = connection.cursor.return_value.__enter__.return_value
                cursor.fetchone.side_effect = [
                    {"id": 1},
                    None if fail_second else {"id": 2},
                ]
                with (
                    patch(
                        "scripts.location_differ_api.psycopg2.connect",
                        return_value=connection,
                    ),
                    patch(
                        "scripts.location_differ_api.database_snapshot",
                        return_value=data["database"],
                    ),
                ):
                    if fail_second:
                        with self.assertRaisesRegex(RuntimeError, "rolling back"):
                            apply_report(data, report, credentials)
                        connection.rollback.assert_called_once()
                        connection.commit.assert_not_called()
                    else:
                        receipt = apply_report(data, report, credentials)
                        self.assertEqual(len(receipt["statuses_changed"]), 2)
                        connection.commit.assert_called_once()
                        record_application(directory, receipt)
                        self.assertIn(
                            "2 statuses changed",
                            Path(directory, "slack_preview.txt").read_text(),
                        )
                mutations = [
                    c
                    for c in cursor.execute.call_args_list
                    if c.args[0].startswith(
                        ("UPDATE machines", "INSERT INTO machines", "DELETE")
                    )
                ]
                self.assertEqual(len(mutations), 2)
                self.assertTrue(
                    all(
                        "SET machine_status = %s, last_updated = CURRENT_DATE"
                        in c.args[0]
                        for c in mutations
                    )
                )
                self.assertEqual(
                    mutations[0].args[1],
                    (
                        "available",
                        1,
                        "retired",
                        "2026-10-10",
                        data["source"][0]["properties"]["external_url"],
                    ),
                )
                audits = [
                    c
                    for c in cursor.execute.call_args_list
                    if c.args[0].startswith("INSERT INTO pending_changes")
                ]
                self.assertEqual(len(audits), 1 if fail_second else 2)
                self.assertIn("last_updated, machine_status)", audits[0].args[0])
                self.assertEqual(
                    audits[0].args[1],
                    ("update", "machine_status from: retired to: available", 1),
                )


class SqlDifferApplyTests(unittest.TestCase):
    def plan(self, directory):
        data = inputs(
            sources=[
                source(1),
                source(2, name="New aquarium", address="Different street"),
            ],
            machines=[machine()],
        )

        def lookup(src):
            result = evidence(2)
            if src["properties"]["name"] == "New aquarium":
                result["geocode"]["latitude"] = 41
            return result

        write_report(data, compare(data, lookup), directory)
        return data, json.loads((Path(directory) / "report.json").read_text())

    def test_atomic_apply_assigns_distinct_ids_and_next_comparison_is_empty(self):
        connection = MagicMock()
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.fetchone.side_effect = [{"id": 1}, {"id": 100}, {"id": 101}]
        with tempfile.TemporaryDirectory() as directory:
            data, report = self.plan(directory)
            credentials = Path(directory) / "db.json"
            credentials.write_text("{}")
            with (
                patch(
                    "scripts.location_differ_api.psycopg2.connect",
                    return_value=connection,
                ),
                patch(
                    "scripts.location_differ_api.database_snapshot",
                    return_value=data["database"],
                ),
            ):
                receipt = apply_report(data, report, credentials)
            connection.commit.assert_called_once()
            connection.rollback.assert_not_called()
            connection.close.assert_called_once()
            self.assertEqual(
                [r["machine_id"] for r in receipt["machines_added"]], [100, 101]
            )
            self.assertEqual(receipt["links_added"], [1])
            self.assertEqual(receipt["sql_machines_after"], 3)
            sql = [call.args[0] for call in cursor.execute.call_args_list]
            update = next(s for s in sql if s.startswith("UPDATE"))
            self.assertIn("SET external_url = %s, last_updated = CURRENT_DATE", update)
            self.assertNotIn("machine_status =", update)
            self.assertTrue(
                all(
                    "(name, area" in s
                    for s in sql
                    if s.startswith("INSERT INTO machines")
                )
            )
            audits = [
                c
                for c in cursor.execute.call_args_list
                if c.args[0].startswith("INSERT INTO pending_changes")
            ]
            self.assertEqual(
                [c.args[1][0] for c in audits], ["update", "create", "create"]
            )
            self.assertEqual([c.args[1][-1] for c in audits], [1, 100, 101])
            self.assertIn("last_updated, external_url)", audits[0].args[0])
            self.assertTrue(
                all(
                    "'location_differ'" in c.args[0] and "'approved'" in c.args[0]
                    for c in audits
                )
            )
            self.assertFalse(any(s.startswith("DELETE") for s in sql))
            record_application(directory, receipt)
            preview = json.loads((Path(directory) / "slack_preview.json").read_text())
            self.assertIn("SQL: 3 machines.", preview["root_text"])
            self.assertIn(
                "Applied: 2 machines added; 1 links added", preview["root_text"]
            )
            self.assertNotIn("Dry run", preview["root_text"])
            data["database"]["machines"][0]["external_url"] = report["links"][0][
                "after_url"
            ]
            for added, proposed in zip(receipt["machines_added"], report["additions"]):
                data["database"]["machines"].append(
                    machine(
                        added["machine_id"],
                        **{
                            k: proposed[k]
                            for k in (
                                "name",
                                "area",
                                "address",
                                "latitude",
                                "longitude",
                                "external_url",
                            )
                        },
                    )
                )
            result = compare(
                data,
                Mock(
                    side_effect=AssertionError("Applied source must not be recreated")
                ),
            )
            self.assertTrue(
                all(r["category"] == "represented" for r in result["records"])
            )

    def test_stale_snapshot_aborts_before_any_write(self):
        for kind in ("user_edit", "deletion", "pending"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                data, report = self.plan(directory)
                current = deepcopy(data["database"])
                if kind == "user_edit":
                    current["machines"][0]["name"] = "User correction"
                elif kind == "deletion":
                    current["deleted_machines"] = current.pop("machines")
                    current["machines"] = []
                else:
                    current["pending_changes"] = [{"machine_id": 1}]
                credentials = Path(directory) / "db.json"
                credentials.write_text("{}")
                connection = MagicMock()
                with (
                    patch(
                        "scripts.location_differ_api.psycopg2.connect",
                        return_value=connection,
                    ),
                    patch(
                        "scripts.location_differ_api.database_snapshot",
                        return_value=current,
                    ),
                ):
                    with self.assertRaisesRegex(RuntimeError, "SQL changed"):
                        apply_report(data, report, credentials)
                connection.commit.assert_not_called()
                connection.rollback.assert_called_once()
                calls = connection.cursor.return_value.__enter__.return_value.execute.call_args_list
                self.assertFalse(
                    any(
                        c.args[0].startswith(("INSERT", "UPDATE", "DELETE"))
                        for c in calls
                    )
                )

    def test_insert_failure_rolls_back_links_and_archived_ids_are_not_reused(self):
        for fail_insert in (True, False):
            with (
                self.subTest(fail_insert=fail_insert),
                tempfile.TemporaryDirectory() as directory,
            ):
                data, report = self.plan(directory)
                data["database"]["deleted_machines"] = [machine(100)]
                credentials = Path(directory) / "db.json"
                credentials.write_text("{}")
                connection = MagicMock()
                cursor = connection.cursor.return_value.__enter__.return_value
                cursor.fetchone.side_effect = [{"id": 1}, {"id": 100}]

                def execute(sql, *args):
                    if fail_insert and sql.startswith("INSERT"):
                        raise RuntimeError("Insert failed")

                cursor.execute.side_effect = execute
                with (
                    patch(
                        "scripts.location_differ_api.psycopg2.connect",
                        return_value=connection,
                    ),
                    patch(
                        "scripts.location_differ_api.database_snapshot",
                        return_value=data["database"],
                    ),
                ):
                    with self.assertRaises(RuntimeError):
                        apply_report(data, report, credentials)
                connection.commit.assert_not_called()
                connection.rollback.assert_called_once()

    def test_audit_failure_rolls_back_the_machine_change(self):
        with tempfile.TemporaryDirectory() as directory:
            data, report = self.plan(directory)
            credentials = Path(directory, "db.json")
            credentials.write_text("{}")
            connection = MagicMock()
            cursor = connection.cursor.return_value.__enter__.return_value
            cursor.fetchone.return_value = {"id": 1}

            def execute(sql, *args):
                if sql.startswith("INSERT INTO pending_changes"):
                    raise RuntimeError("Audit insert failed")

            cursor.execute.side_effect = execute
            with (
                patch(
                    "scripts.location_differ_api.psycopg2.connect",
                    return_value=connection,
                ),
                patch(
                    "scripts.location_differ_api.database_snapshot",
                    return_value=data["database"],
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "Audit insert failed"):
                    apply_report(data, report, credentials)
            connection.commit.assert_not_called()
            connection.rollback.assert_called_once()

    def test_cli_defaults_to_dry_run_and_rejects_applying_saved_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            data, report = self.plan(directory)
            Path(directory, "inputs.json").write_text(json.dumps(data))
            with (
                patch(
                    "sys.argv",
                    ["differ", "--apply", "--reuse-inputs", "--output-dir", directory],
                ),
                patch("scripts.location_differ_api.apply_report") as apply,
            ):
                with self.assertRaises(SystemExit) as error:
                    main()
                self.assertEqual(error.exception.code, 2)
                apply.assert_not_called()
            with (
                patch(
                    "sys.argv",
                    [
                        "differ",
                        "--reuse-inputs",
                        "--no-slack",
                        "--output-dir",
                        directory,
                    ],
                ),
                patch("scripts.location_differ_api.SourceEvidence") as details,
                patch("scripts.location_differ_api.apply_report") as apply,
                patch("scripts.location_differ_api.logger") as log,
            ):
                details.return_value.get.return_value = evidence()
                main()
                apply.assert_not_called()
                self.assertIn("START", log.info.call_args_list[0].args[0])
                self.assertIn("COMPLETE", log.success.call_args.args[0])
                self.assertIn("disabled", log.success.call_args.args)
                log.error.assert_not_called()

    def test_slack_failure_logs_failure_instead_of_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            data, _ = self.plan(directory)
            Path(directory, "inputs.json").write_text(json.dumps(data))
            args = Namespace(
                output_dir=Path(directory),
                send_report=False,
                apply=False,
                no_slack=False,
                reuse_inputs=True,
                geocode=False,
                slack_state=Path(directory) / "slack.json",
            )
            with (
                patch("scripts.location_differ_api.SourceEvidence") as details,
                patch(
                    "scripts.location_differ_api.send_slack_reports",
                    side_effect=RuntimeError("Slack unavailable"),
                ),
                patch("scripts.location_differ_api.logger") as log,
                patch.dict("os.environ", {"SLACK_TOKEN": "test-token"}),
                patch("scripts.location_differ_api.WebClient") as slack,
            ):
                slack.return_value.chat_postMessage.return_value = {"ok": True}
                details.return_value.get.return_value = evidence()
                with self.assertRaisesRegex(RuntimeError, "Slack unavailable"):
                    run(args)
                self.assertIn("START", log.info.call_args_list[0].args[0])
                self.assertIn("FAILED", log.error.call_args.args[0])
                log.success.assert_not_called()
                details.return_value.session.close.assert_called_once()
                message = slack.return_value.chat_postMessage.call_args.kwargs["text"]
                self.assertIn("DRY RUN FAILED", message)
                self.assertIn("No SQL writes", message)

    def test_failure_after_commit_alerts_without_reapplying_or_leaking_error(self):
        with tempfile.TemporaryDirectory() as directory:
            data, report = self.plan(directory)
            Path(directory, "inputs.json").write_text(json.dumps(data))
            args = Namespace(
                output_dir=Path(directory),
                send_report=False,
                apply=True,
                no_slack=False,
                reuse_inputs=False,
                geocode=False,
                slack_state=Path(directory, "slack.json"),
            )
            receipt = {
                "status": "applied",
                "machines_added": [],
                "links_added": [],
                "statuses_changed": [],
                "sql_machines_after": 1,
            }
            with (
                patch("scripts.location_differ_api.fetch_inputs", return_value=data),
                patch("scripts.location_differ_api.SourceEvidence") as details,
                patch(
                    "scripts.location_differ_api.apply_report", return_value=receipt
                ) as apply,
                patch(
                    "scripts.location_differ_api.send_slack_reports",
                    side_effect=RuntimeError("sensitive-example"),
                ),
                patch.dict("os.environ", {"SLACK_TOKEN": "test-token"}),
                patch("scripts.location_differ_api.WebClient") as slack,
                patch("scripts.location_differ_api.logger") as log,
            ):
                details.return_value.get.return_value = evidence()
                slack.return_value.chat_postMessage.return_value = {"ok": True}
                with self.assertRaisesRegex(RuntimeError, "sensitive-example"):
                    run(args)
                apply.assert_called_once()
                log.success.assert_not_called()
                message = slack.return_value.chat_postMessage.call_args.kwargs["text"]
                self.assertIn("SQL committed", message)
                self.assertIn("--send-report", message)
                self.assertNotIn("sensitive-example", message)
                self.assertEqual(
                    json.loads(Path(directory, "apply_result.json").read_text()),
                    receipt,
                )


if __name__ == "__main__":
    unittest.main()
