import importlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from pennyme.moderation import ModerationStore

from PIL import Image
from slack_bolt.request import BoltRequest
from slack_bolt.response import BoltResponse

os.environ.setdefault("SLACK_TOKEN", "test")

with patch(
    "slack_sdk.WebClient.auth_test", return_value={"ok": True, "bot_id": "test"}
):
    slack = importlib.import_module("pennyme.slack")
process_uploaded_image = slack.process_uploaded_image


class ProcessUploadedImageTest(unittest.TestCase):
    def test_large_machine_jpg_and_rembg_coin_png_are_below_500_kb(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Image.effect_noise((2000, 2000), 100).convert("RGB")

            machine_path = Path(directory) / "1.jpg"
            image.save(machine_path, quality=100)
            self.assertGreater(machine_path.stat().st_size, 1024 * 1024)

            code, _, saved_path = process_uploaded_image(str(machine_path))
            self.assertEqual(code, 200)
            self.assertLessEqual(Path(saved_path).stat().st_size, 500 * 1024)

            coin_path = Path(directory) / "1_coin_0.jpg"
            image.save(coin_path, quality=100)
            self.assertGreater(coin_path.stat().st_size, 1024 * 1024)

            with patch("pennyme.slack.new_session", return_value=object()):
                with patch(
                    "pennyme.slack.remove",
                    side_effect=lambda processed_image,
                    session: processed_image.convert("RGBA"),
                ) as remove:
                    code, _, saved_path = process_uploaded_image(str(coin_path))

            self.assertEqual(code, 200)
            self.assertEqual(Path(saved_path).suffix, ".png")
            self.assertLessEqual(Path(saved_path).stat().st_size, 500 * 1024)
            remove.assert_called_once()


class ReportSlackTest(unittest.TestCase):
    def test_approved_new_machine_reassigns_attribution_to_final_id(self):
        body = {
            "actions": [{"value": "7"}],
            "user": {"id": "U123", "name": "reviewer"},
        }
        result = SimpleNamespace(
            applied=True,
            status="approved",
            machine_id=42,
            change_type="create",
        )
        with (
            patch.object(slack, "approve_pending_change", return_value=result),
            patch.object(slack._MODERATION, "reassign_machine_content") as reassign,
            patch.object(slack, "delete_pending_image_messages"),
        ):
            slack.handle_approve_change(Mock(), body, Mock())

        reassign.assert_called_once_with("7", "42")

    def test_pending_location_change_includes_route_and_neighbors(self):
        neighbors = [
            {"id": 7, "name": "Museum", "distance_m": 40},
            {"id": 8, "name": "Station", "distance_m": 120},
        ]
        with patch.object(slack, "message_slack_raw") as post:
            slack.message_slack_pending_change(
                change_id=12,
                change_type="update",
                title="Moved machine",
                area="Switzerland",
                change_summary="Location changed",
                machine_id=42,
                latitude=47.4,
                longitude=8.6,
                old_latitude=47.3,
                old_longitude=8.5,
                movement_distance_m=250,
                nearby_radius_m=250,
                nearby_machines=neighbors,
            )

        text = post.call_args.args[0]
        self.assertIn("*Moved machine*", text)
        self.assertIn(
            "https://www.google.com/maps/dir/?api=1&origin=47.3,8.5"
            "&destination=47.4,8.6",
            text,
        )
        self.assertIn("Moved farther than the nearest neighbor (ID 7 at 40 m)", text)
        self.assertIn("ID 7 — Museum — 40 m", text)
        self.assertIn("ID 8 — Station — 120 m", text)

    def test_pending_location_change_reports_no_neighbors(self):
        with patch.object(slack, "message_slack_raw") as post:
            slack.message_slack_pending_change(
                change_id=12,
                change_type="update",
                title="Moved machine",
                area="Switzerland",
                change_summary="Location changed",
                machine_id=42,
                latitude=47.4,
                longitude=8.6,
                old_latitude=47.3,
                old_longitude=8.5,
                movement_distance_m=50,
                nearby_radius_m=150,
                nearby_machines=[],
            )

        self.assertIn("No other machines within 150 m", post.call_args.args[0])

    def test_pending_new_machine_includes_three_nearest(self):
        neighbors = [
            {"id": 1, "name": "One", "distance_m": 10},
            {"id": 2, "name": "Two", "distance_m": 20},
            {"id": 3, "name": "Three", "distance_m": 30},
        ]
        with patch.object(slack, "message_slack_raw") as post:
            slack.message_slack_pending_change(
                change_id=13,
                change_type="create",
                title="New machine",
                area="Switzerland",
                change_summary="new machine",
                latitude=47.4,
                longitude=8.6,
                nearby_machines=neighbors,
            )

        text = post.call_args.args[0]
        self.assertIn("*Three nearest machines:*", text)
        for machine in neighbors:
            self.assertIn(
                f"ID {machine['id']} — {machine['name']} — {machine['distance_m']} m",
                text,
            )

    def test_pending_image_notification_includes_machine_title(self):
        with patch.object(
            slack.CLIENT,
            "chat_postMessage",
            return_value={"channel": "C123", "ts": "123"},
        ) as post:
            slack.image_slack(12, m_name="New machine", pending=True)

        self.assertIn("New machine", post.call_args.kwargs["text"])

    def test_source_and_nearby_images_are_temporary_thread_replies(self):
        neighbors = [
            {
                "id": 7,
                "name": "Museum",
                "distance_m": 40,
                "external_url": "https://locations.pennycollector.com/Details.aspx?id=7",
            },
            {
                "id": 8,
                "name": "Station",
                "distance_m": 120,
                "external_url": "https://example.com/not-pennycollector",
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in (
                "42.jpg",
                "42_coin_0.png",
                "7.jpg",
                "7_coin_0.png",
                "70.jpg",
                "7_other.png",
            ):
                (root / name).touch()

            with (
                patch.object(slack, "PATH_IMAGES", directory),
                patch.object(slack, "_PENDING_IMAGE_MESSAGES", {}),
                patch.object(
                    slack,
                    "message_slack_raw",
                    side_effect=[
                        {"channel": "C123", "ts": "root-ts"},
                        {"channel": "C123", "ts": "source-images-ts"},
                        {"channel": "C123", "ts": "nearby-images-ts"},
                    ],
                ) as post,
            ):
                slack.message_slack_pending_change(
                    change_id=12,
                    change_type="update",
                    title="Moved machine",
                    area="Switzerland",
                    change_summary="Location changed",
                    machine_id=42,
                    movement_distance_m=250,
                    nearby_radius_m=250,
                    nearby_machines=neighbors,
                )

                root_text = post.call_args_list[0].args[0]
                self.assertIn(
                    "<https://locations.pennycollector.com/Details.aspx?id=7|PennyCollector>",
                    root_text,
                )
                self.assertNotIn("<https://example.com/not-pennycollector|", root_text)

                source_image_message = post.call_args_list[1]
                self.assertEqual(source_image_message.kwargs["thread_ts"], "root-ts")
                self.assertEqual(
                    [
                        block["image_url"]
                        for block in source_image_message.kwargs["blocks"]
                    ],
                    [f"{slack.IMG_PORT}42.jpg"],
                )
                nearby_image_message = post.call_args_list[2]
                self.assertEqual(nearby_image_message.kwargs["thread_ts"], "root-ts")
                self.assertEqual(
                    [
                        block["image_url"]
                        for block in nearby_image_message.kwargs["blocks"]
                    ],
                    [f"{slack.IMG_PORT}7.jpg"],
                )
                self.assertEqual(
                    slack._PENDING_IMAGE_MESSAGES[12],
                    [
                        ("C123", "source-images-ts"),
                        ("C123", "nearby-images-ts"),
                    ],
                )

    def test_pending_image_cleanup_deletes_every_tracked_message(self):
        with (
            patch.object(
                slack,
                "_PENDING_IMAGE_MESSAGES",
                {12: [("C123", "one"), ("C123", "two")]},
            ),
            patch.object(slack.CLIENT, "chat_delete") as delete,
        ):
            slack.delete_pending_image_messages(12)

        self.assertEqual(delete.call_count, 2)
        delete.assert_any_call(channel="C123", ts="one")
        delete.assert_any_call(channel="C123", ts="two")

    def test_pending_change_splits_large_neighbor_lists_into_valid_blocks(self):
        neighbors = [
            {"id": index, "name": "Museum " + "x" * 50, "distance_m": index}
            for index in range(100)
        ]
        with patch.object(slack, "message_slack_raw") as post:
            slack.message_slack_pending_change(
                change_id=12,
                change_type="update",
                title="Moved machine",
                area="Switzerland",
                change_summary="Location changed",
                machine_id=42,
                latitude=47.4,
                longitude=8.6,
                old_latitude=47.3,
                old_longitude=8.5,
                movement_distance_m=500,
                nearby_radius_m=500,
                nearby_machines=neighbors,
            )

        sections = [
            block["text"]["text"]
            for block in post.call_args.kwargs["blocks"]
            if block["type"] == "section"
        ]
        self.assertGreater(len(sections), 1)
        self.assertTrue(all(len(section) <= 3000 for section in sections))
        self.assertIn("ID 99", "\n".join(sections))

    def test_machine_and_ugc_actions_match_separate_handlers(self):
        for action in (
            "approve_change",
            "reject_change",
            "approve_report",
            "reject_report",
        ):
            body = {
                "type": "block_actions",
                "actions": [{"action_id": action, "value": "42"}],
                "user": {"id": "U123", "name": "reviewer"},
                "trigger_id": "trigger-42",
                "channel": {"id": "C123"},
                "message": {
                    "ts": "123.456",
                    "text": "Change requested\n*Machine title* (Area)",
                },
            }
            request = BoltRequest(body=body, mode="socket_mode")
            listeners = [
                listener
                for listener in slack.SLACK_APP._listeners
                if listener.matches(req=request, resp=BoltResponse(status=200))
            ]
            self.assertEqual(len(listeners), 1, action)
            self.assertEqual(listeners[0].ack_function.__name__, f"handle_{action}")
            ack, respond = Mock(), Mock()
            with (
                patch.object(slack, "approve_pending_change") as approve,
                patch.object(slack, "reject_pending_change") as reject,
                patch.object(slack, "handle_report_review") as review,
                patch.object(slack, "delete_pending_image_messages"),
                patch.object(slack.CLIENT, "views_open") as views_open,
            ):
                listeners[0].ack_function(ack, body, respond)
                ack.assert_called_once_with()
                if action == "approve_change":
                    approve.assert_called_once_with(42)
                    reject.assert_not_called()
                    review.assert_not_called()
                    self.assertTrue(respond.call_args.kwargs["replace_original"])
                    self.assertIn(
                        "Machine title", respond.call_args.kwargs["text"]
                    )
                elif action == "reject_change":
                    reject.assert_not_called()
                    views_open.assert_called_once()
                    self.assertEqual(
                        views_open.call_args.kwargs["view"]["callback_id"],
                        "reject_change_modal",
                    )
                    metadata = json.loads(
                        views_open.call_args.kwargs["view"]["private_metadata"]
                    )
                    self.assertEqual(metadata["machine_title"], "Machine title")
                    approve.assert_not_called()
                    review.assert_not_called()
                else:
                    review.assert_called_once_with(
                        body,
                        respond,
                        "approved" if action.startswith("approve") else "rejected",
                    )
                    approve.assert_not_called()
                    reject.assert_not_called()

    def test_rejection_modal_persists_reason_and_updates_original_message(self):
        body = {"user": {"id": "U123", "name": "reviewer"}}
        view = {
            "private_metadata": json.dumps(
                {
                    "change_id": 42,
                    "channel_id": "C123",
                    "message_ts": "123.456",
                    "machine_title": "Machine title",
                }
            ),
            "state": {
                "values": {
                    "rejection_reason": {"reason": {"value": "Not accurate"}}
                }
            },
        }
        result = SimpleNamespace(applied=True, status="rejected")
        with (
            patch.object(slack, "reject_pending_change", return_value=result) as reject,
            patch.object(slack, "delete_pending_image_messages"),
            patch.object(slack.CLIENT, "chat_update") as update,
        ):
            ack = Mock()
            slack.handle_reject_change_submission(ack, body, view)

        ack.assert_called_once_with()
        reject.assert_called_once_with(42, "Not accurate")
        update.assert_called_once_with(
            channel="C123",
            ts="123.456",
            text=":x: *Machine title* — Pending change #42 *rejected* by reviewer.",
            blocks=[],
        )

    def test_reports_include_only_target_content_and_thread_in_approvals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            (root / "comments/42.json").write_text('{"date": "flagged comment"}')
            for name in ("42.jpg", "42_coin_0.png", "420.jpg", "42_other.png"):
                (root / name).touch()
            for kind, target, expected_linked_images in (
                ("image", "machine", ["42.jpg"]),
                ("image", "coin_0", ["42_coin_0.png"]),
                ("comment", "all", []),
                ("machine", "listing", ["42.jpg", "42_coin_0.png"]),
            ):
                with (
                    self.subTest(kind=kind, target=target),
                    patch.object(
                        slack.CLIENT,
                        "chat_postMessage",
                        return_value={"channel": "C123", "ts": "123"},
                    ) as post,
                    patch.object(
                        slack,
                        "find_machine_in_database",
                        return_value={"properties": {"name": "Listing"}},
                    ),
                ):
                    slack.message_slack_report(
                        "<!channel> UGC REPORT",
                        "report-id",
                        "This content is wrong",
                        "42",
                        kind,
                        target,
                        directory,
                    )
                    calls = [call.kwargs for call in post.call_args_list]
                    self.assertEqual(
                        calls[0]["text"], "<!channel> UGC REPORT\n*Listing*"
                    )
                    self.assertTrue(
                        all(call["username"] == "PennyMe" for call in calls)
                    )
                    action_ids = [
                        element["action_id"]
                        for block in calls[0]["blocks"]
                        if block["type"] == "actions"
                        for element in block["elements"]
                    ]
                    self.assertEqual(
                        action_ids,
                        ["approve_report", "reject_report"],
                    )
                    self.assertTrue(all(c["channel"] == "C123" for c in calls[1:]))
                    self.assertTrue(all(c["thread_ts"] == "123" for c in calls[1:]))
                    self.assertIn(
                        "UGC REPORT\n*Listing*\nReporter explanation: This content is wrong",
                        calls[1]["blocks"][0]["text"]["text"],
                    )
                    linked_images = [
                        c["text"]
                        for c in calls[1:]
                        if c["blocks"][0]["type"] == "image"
                    ]
                    self.assertEqual(linked_images, expected_linked_images)
                    if kind in {"image", "machine"}:
                        image_blocks = [
                            c["blocks"][0]
                            for c in calls[1:]
                            if c["blocks"][0]["type"] == "image"
                        ]
                        for filename, image_block in zip(
                            expected_linked_images, image_blocks
                        ):
                            snapshot = root / "reported" / f"report-id_{filename}"
                            self.assertEqual(
                                snapshot.read_bytes(), (root / filename).read_bytes()
                            )
                            self.assertEqual(
                                image_block["image_url"],
                                f"{slack.IMG_PORT}reported/{snapshot.name}",
                            )
                    text = "".join(c["text"] for c in calls[1:])
                    self.assertEqual(
                        "flagged comment" in text, kind in {"comment", "machine"}
                    )
                    self.assertIn("Listing", text)

    def test_long_comments_are_preserved_as_plain_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            comment = "<!channel>" + "x" * 7000
            (root / "comments/42.json").write_text(slack.json.dumps({"date": comment}))
            with (
                patch.object(
                    slack.CLIENT, "chat_postMessage", return_value={"ts": "123"}
                ) as post,
                patch.object(
                    slack,
                    "find_machine_in_database",
                    return_value={"properties": {"name": "Listing"}},
                ),
            ):
                slack.message_slack_report(
                    "alert",
                    "report-id",
                    "A proper explanation",
                    "42",
                    "comment",
                    "all",
                    directory,
                )
            chunks = [
                call.kwargs["blocks"][0]["text"] for call in post.call_args_list[2:]
            ]
            self.assertTrue(
                all(
                    c["type"] == "plain_text" and len(c["text"]) <= 3000 for c in chunks
                )
            )
            self.assertEqual(
                slack.json.loads("".join(c["text"] for c in chunks))["comments"][
                    "date"
                ],
                comment,
            )

    def test_approval_moves_the_exact_reported_file_and_records_the_reviewer(self):
        for kind, target, relative_source, other_name in (
            ("image", "machine", "42.jpg", "42_coin_0.png"),
            ("image", "coin_0", "42_coin_0.png", "42.jpg"),
            ("comment", "all", "comments/42.json", "42.jpg"),
        ):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "comments").mkdir()
                source = root / relative_source
                source.write_text("reported content", encoding="utf-8")
                other_image = root / other_name
                other_image.write_text("keep", encoding="utf-8")
                store = ModerationStore(
                    root / "attribution.json", root / "reports.jsonl"
                )
                store.record_report(
                    {
                        "report_id": "report-id",
                        "machine_id": "42",
                        "target_kind": kind,
                        "target_id": target,
                        "content_key": f"{kind}:{target}",
                        "reason": "spam",
                        "comment": "This is spam",
                        "block_contributor": False,
                        "contributor_id": "contributor",
                        "reporter_id": "reporter",
                    }
                )
                ack = Mock()
                respond = Mock()
                body = {
                    "actions": [{"value": "report-id"}],
                    "user": {"id": "U123", "name": "reviewer"},
                    "message": {"text": "UGC report\n*Machine title*"},
                }

                with (
                    patch.object(slack, "_MODERATION", store),
                    patch.object(slack, "PATH_IMAGES", directory),
                ):
                    slack.handle_approve_report(ack, body, respond)

                self.assertFalse(source.exists())
                self.assertEqual(
                    (root / "reported" / source.name).read_text(encoding="utf-8"),
                    "reported content",
                )
                self.assertEqual(other_image.read_text(encoding="utf-8"), "keep")
                _, decision = store.report_status("report-id")
                self.assertEqual(decision, "approved")
                review = json.loads(
                    store.reports_path.read_text(encoding="utf-8").splitlines()[-1]
                )
                self.assertEqual(review["reviewer_id"], "U123")
                ack.assert_called_once_with()
                self.assertEqual(respond.call_args.kwargs["blocks"], [])
                self.assertTrue(respond.call_args.kwargs["replace_original"])
                self.assertIn("Machine title", respond.call_args.kwargs["text"])

    def test_rejection_records_the_reviewer_without_moving_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "42.jpg"
            source.write_text("keep", encoding="utf-8")
            store = ModerationStore(root / "attribution.json", root / "reports.jsonl")
            store.record_report(
                {
                    "report_id": "report-id",
                    "machine_id": "42",
                    "target_kind": "machine",
                    "target_id": "listing",
                    "content_key": "machine:listing",
                    "reason": "wrong_content",
                    "comment": "The image is wrong",
                    "block_contributor": False,
                    "contributor_id": "contributor",
                    "reporter_id": "reporter",
                }
            )
            with (
                patch.object(slack, "_MODERATION", store),
                patch.object(slack, "PATH_IMAGES", directory),
                patch.object(slack, "archive_and_delete_machine") as archive,
            ):
                slack.handle_reject_report(
                    Mock(),
                    {
                        "actions": [{"value": "report-id"}],
                        "user": {"id": "U123", "name": "reviewer"},
                    },
                    respond := Mock(),
                )

            self.assertTrue(source.exists())
            self.assertFalse((root / "reported").exists())
            archive.assert_not_called()
            _, decision = store.report_status("report-id")
            self.assertEqual(decision, "rejected")
            self.assertEqual(respond.call_args.kwargs["blocks"], [])

    def test_machine_approval_backs_up_all_content_and_deletes_sql_row(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            expected_sources = [
                root / "42.jpg",
                root / "42.jpeg",
                root / "42_coin_0.png",
                root / "42_coin_1.jpg",
                root / "comments/42.json",
            ]
            for index, source in enumerate(expected_sources):
                source.write_text(f"content-{index}", encoding="utf-8")
            unrelated = [root / "420.jpg", root / "42_other.png"]
            for path in unrelated:
                path.write_text("keep", encoding="utf-8")

            store = ModerationStore(root / "attribution.json", root / "reports.jsonl")
            store.record_report(
                {
                    "report_id": "report-id",
                    "machine_id": "42",
                    "target_kind": "machine",
                    "target_id": "listing",
                    "content_key": "machine:listing",
                    "reason": "wrong_content",
                    "comment": "This listing is wrong",
                    "block_contributor": False,
                    "contributor_id": "contributor",
                    "reporter_id": "reporter",
                }
            )

            with (
                patch.object(slack, "_MODERATION", store),
                patch.object(slack, "PATH_IMAGES", directory),
                patch.object(slack, "archive_and_delete_machine") as archive,
            ):
                slack.handle_approve_report(
                    Mock(),
                    {
                        "actions": [{"value": "report-id"}],
                        "user": {"id": "U123", "name": "reviewer"},
                    },
                    respond := Mock(),
                )

            archive.assert_called_once_with(42, "U123", "report-id")
            for index, source in enumerate(expected_sources):
                self.assertFalse(source.exists())
                backup = root / "reported" / f"report-id_{source.name}"
                self.assertEqual(backup.read_text(encoding="utf-8"), f"content-{index}")
            self.assertTrue(all(path.exists() for path in unrelated))
            _, decision = store.report_status("report-id")
            self.assertEqual(decision, "approved")
            self.assertTrue(respond.call_args.kwargs["replace_original"])

    def test_failed_machine_archive_leaves_original_files_in_place(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "42.jpg"
            source.write_text("keep", encoding="utf-8")
            store = ModerationStore(root / "attribution.json", root / "reports.jsonl")
            store.record_report(
                {
                    "report_id": "report-id",
                    "machine_id": "42",
                    "target_kind": "machine",
                    "target_id": "listing",
                    "content_key": "machine:listing",
                    "reason": "wrong_content",
                    "comment": "This listing is wrong",
                    "block_contributor": False,
                    "contributor_id": "contributor",
                    "reporter_id": "reporter",
                }
            )

            with (
                patch.object(slack, "_MODERATION", store),
                patch.object(slack, "PATH_IMAGES", directory),
                patch.object(
                    slack,
                    "archive_and_delete_machine",
                    side_effect=RuntimeError("database unavailable"),
                ),
            ):
                slack.handle_approve_report(
                    Mock(),
                    {
                        "actions": [{"value": "report-id"}],
                        "user": {"id": "U123", "name": "reviewer"},
                    },
                    respond := Mock(),
                )

            self.assertTrue(source.exists())
            self.assertEqual(list((root / "reported").iterdir()), [])
            _, decision = store.report_status("report-id")
            self.assertIsNone(decision)
            self.assertFalse(respond.call_args.kwargs["replace_original"])


if __name__ == "__main__":
    unittest.main()
