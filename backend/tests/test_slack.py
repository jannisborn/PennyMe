import importlib
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from PIL import Image

os.environ.setdefault("SLACK_TOKEN", "test")

with patch(
    "slack_sdk.WebClient.auth_test", return_value={"ok": True, "bot_id": "test"}
):
    slack = importlib.import_module("pennyme.slack")
process_uploaded_image = slack.process_uploaded_image


class PendingChangeSlackTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name, value in (
            ("PENDING_SLACK_STATE", self.root / "reviews.sqlite3"),
            ("PATH_IMAGES", str(self.root)),
        ):
            patcher = patch.object(slack, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.body = {
            "channel": {"id": "C123"},
            "user": {"id": "U123"},
            "actions": [{"action_id": "approve_change", "value": "42"}],
            "message": {
                "ts": "root",
                "text": "Original proposal",
                "blocks": [
                    {
                        "type": "section",
                        "text": {"type": "plain_text", "text": "Original proposal"},
                    },
                    {"type": "actions"},
                ],
            },
        }

    def post_image(self):
        (self.root / "pending_42.jpg").write_bytes(b"submitted image")
        with (
            patch.object(
                slack.CLIENT,
                "files_upload_v2",
                return_value={"files": [{"id": "F123"}]},
            ),
            patch.object(
                slack.CLIENT,
                "chat_postMessage",
                return_value={"channel": "C123", "ts": "image"},
            ),
        ):
            slack.image_slack(42, pending=True)

    def test_both_decisions_archive_images_before_server_file_removal(self):
        for decision in ("approve", "reject"):
            with self.subTest(decision=decision):
                with slack.pending_slack_state(42) as state:
                    state.clear()
                self.post_image()
                # A fresh SQLite connection restores references without an in-memory map.
                with slack.pending_slack_state(42) as restored:
                    self.assertEqual(
                        restored["images"]["pending_42.jpg"]["ts"], "image"
                    )
                self.body["actions"][0]["action_id"] = f"{decision}_change"
                events = Mock()

                def apply_decision(change_id):
                    self.assertEqual(change_id, 42)
                    self.assertEqual(events.archive.call_count, 2)
                    (self.root / "pending_42.jpg").unlink()
                    return SimpleNamespace(applied=True, machine_id=99)

                events.review.side_effect = apply_decision
                with (
                    patch.object(slack, "message_slack_raw", events.archive),
                    patch.object(slack, f"{decision}_pending_change", events.review),
                    patch.object(slack.CLIENT, "chat_delete", events.delete),
                    patch.object(slack.CLIENT, "chat_update", events.update),
                ):
                    slack.handle_pending_change_review(
                        events.ack, self.body, events.respond
                    )
                    self.assertEqual(
                        [call[0] for call in events.mock_calls],
                        ["ack", "archive", "archive", "review", "delete", "update"],
                    )
                    archives = [call.kwargs for call in events.archive.call_args_list]
                    self.assertTrue(
                        all(item["thread_ts"] == "root" for item in archives)
                    )
                    self.assertEqual(
                        archives[1]["blocks"][0]["slack_file"], {"id": "F123"}
                    )
                    self.assertFalse(
                        any(b["type"] == "actions" for b in archives[0]["blocks"])
                    )
                    events.delete.assert_called_once_with(channel="C123", ts="image")
                    self.assertEqual(events.update.call_args.kwargs["blocks"], [])
                    self.assertIn(
                        f"*{decision}d*" if decision == "approve" else "*rejected*",
                        events.update.call_args.kwargs["text"],
                    )
                    events.respond.assert_not_called()
                    # A duplicate click reuses the original result and archive.
                    slack.handle_pending_change_review(
                        events.ack, self.body, events.respond
                    )
                    self.assertEqual(events.archive.call_count, 2)
                    events.review.assert_called_once()
                    events.delete.assert_called_once()

    def test_archive_failure_keeps_submission_and_database_untouched(self):
        self.post_image()
        with (
            patch.object(
                slack,
                "message_slack_raw",
                side_effect=slack.SlackApiError("failed", {"error": "missing_scope"}),
            ),
            patch.object(slack, "approve_pending_change") as review,
            patch.object(slack.CLIENT, "chat_delete") as delete,
            patch.object(slack.CLIENT, "chat_update") as update,
        ):
            respond = Mock()
            slack.handle_pending_change_review(Mock(), self.body, respond)
            review.assert_not_called()
            delete.assert_not_called()
            update.assert_not_called()
            self.assertFalse(respond.call_args.kwargs["replace_original"])
        self.assertTrue((self.root / "pending_42.jpg").exists())

    def test_cleanup_failure_resumes_saved_decision(self):
        self.post_image()
        with (
            patch.object(slack, "message_slack_raw") as archive,
            patch.object(
                slack,
                "approve_pending_change",
                return_value=SimpleNamespace(applied=True, machine_id=99),
            ) as review,
            patch.object(
                slack.CLIENT,
                "chat_delete",
                side_effect=slack.SlackApiError("failed", {"error": "ratelimited"}),
            ) as delete,
            patch.object(slack.CLIENT, "chat_update") as update,
        ):
            slack.handle_pending_change_review(Mock(), self.body, Mock())
            update.assert_not_called()
            delete.side_effect = None
            # Even a conflicting stale click resumes the decision already applied.
            self.body["actions"][0]["action_id"] = "reject_change"
            slack.handle_pending_change_review(Mock(), self.body, Mock())
            self.assertEqual(archive.call_count, 2)
            review.assert_called_once()
            self.assertIn("*approved*", update.call_args.kwargs["text"])

    def test_review_waits_for_background_image_processing(self):
        with slack.pending_slack_state(42) as state:
            state["awaiting_image"] = True
        with patch.object(slack, "approve_pending_change") as review:
            respond = Mock()
            slack.handle_pending_change_review(Mock(), self.body, respond)
            review.assert_not_called()
            self.assertFalse(respond.call_args.kwargs["replace_original"])

    def test_legacy_image_recovery_paginates_and_matches_only_own_exact_id(self):
        self.body["message"]["bot_id"] = "B123"
        image_block = {
            "type": "image",
            "image_url": f"{slack.IMG_PORT}pending_42.jpg",
            "alt_text": "Original image",
        }
        with (
            patch.object(
                slack.CLIENT,
                "conversations_history",
                side_effect=[
                    {
                        "messages": [
                            {
                                "ts": "other-bot",
                                "bot_id": "B456",
                                "blocks": [image_block],
                            },
                            {
                                "ts": "other-id",
                                "bot_id": "B123",
                                "blocks": [
                                    {
                                        **image_block,
                                        "image_url": f"{slack.IMG_PORT}pending_420.jpg",
                                    }
                                ],
                            },
                        ],
                        "response_metadata": {"next_cursor": "next"},
                    },
                    {
                        "messages": [
                            {"ts": "image", "bot_id": "B123", "blocks": [image_block]}
                        ]
                    },
                ],
            ) as history,
            patch.object(
                slack.CLIENT,
                "files_upload_v2",
                return_value={"files": [{"id": "F123"}]},
            ) as upload,
        ):
            with slack.pending_slack_state(42) as state:
                slack.recover_pending_images(42, self.body, state)
            self.assertEqual(history.call_args.kwargs["cursor"], "next")
            upload.assert_called_once_with(file=str(self.root / "pending_42.jpg"))
        with slack.pending_slack_state(42) as restored:
            self.assertEqual(list(restored["images"]), ["image"])
            self.assertEqual(
                restored["images"]["image"]["block"]["slack_file"], {"id": "F123"}
            )


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
    def test_reports_show_target_content_and_buttons_in_approvals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            (root / "comments/42.json").write_text('{"date": "flagged comment"}')
            for name in ("42.jpg", "42_coin_0.png", "420.jpg", "42_other.png"):
                (root / name).touch()
            for kind, target, expected_images in (
                ("image", "machine", ["42.jpg"]),
                ("image", "coin_0", ["42_coin_0.png"]),
                ("comment", "all", []),
                ("machine", "listing", ["42.jpg", "42_coin_0.png"]),
            ):
                with (
                    self.subTest(kind=kind, target=target),
                    patch.object(
                        slack.CLIENT, "chat_postMessage", return_value={"ts": "123"}
                    ) as post,
                    patch.object(
                        slack,
                        "find_machine_in_database",
                        return_value={"name": "Listing"},
                    ),
                ):
                    slack.message_slack_report(
                        "<!channel> UGC REPORT", "42", kind, target, directory
                    )
                    calls = [call.kwargs for call in post.call_args_list]
                    self.assertEqual(calls[0]["text"], "<!channel> UGC REPORT")
                    self.assertTrue(
                        all(c["channel"] == "#pennyme_approvals" for c in calls)
                    )
                    self.assertTrue(all(c["thread_ts"] == "123" for c in calls[1:]))
                    blocks = calls[0]["blocks"]
                    images = [b["alt_text"] for b in blocks if b["type"] == "image"]
                    self.assertEqual(images, expected_images)
                    text = slack.json.dumps(blocks)
                    self.assertEqual(
                        "flagged comment" in text, kind in {"comment", "machine"}
                    )
                    self.assertEqual("Listing" in text, kind == "machine")
                    self.assertEqual(
                        [b["action_id"] for b in blocks[-1]["elements"]],
                        ["approve_report", "reject_report"],
                    )

    def test_long_comments_are_preserved_as_plain_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            comment = "<!channel>" + "x" * 7000
            (root / "comments/42.json").write_text(slack.json.dumps({"date": comment}))
            with patch.object(
                slack.CLIENT, "chat_postMessage", return_value={"ts": "123"}
            ) as post:
                slack.message_slack_report("alert", "42", "comment", "all", directory)
            chunks = [block["text"] for block in post.call_args.kwargs["blocks"][1:-1]]
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

    def test_large_listing_keeps_all_images_within_slack_block_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            for index in range(105):
                (Path(directory) / f"42_coin_{index}.png").touch()
            with (
                patch.object(
                    slack.CLIENT, "chat_postMessage", return_value={"ts": "123"}
                ) as post,
                patch.object(
                    slack, "find_machine_in_database", return_value={"id": 42}
                ),
            ):
                slack.message_slack_report(
                    "alert", "42", "machine", "listing", directory
                )
            messages = [call.kwargs for call in post.call_args_list]
            self.assertTrue(all(len(message["blocks"]) <= 50 for message in messages))
            self.assertTrue(
                all(message["thread_ts"] == "123" for message in messages[1:])
            )
            images = [
                block["alt_text"]
                for message in messages
                for block in message["blocks"]
                if block["type"] == "image"
            ]
            self.assertEqual(len(set(images)), 105)

    def test_review_archives_content_before_clearing_channel_message(self):
        for decision in ("approve", "reject"):
            with self.subTest(decision=decision):
                body = {
                    "channel": {"id": "C123"},
                    "user": {"id": "U123"},
                    "actions": [{"action_id": f"{decision}_report", "value": "42"}],
                    "message": {
                        "ts": "123",
                        "text": "<!channel> UGC REPORT",
                        "blocks": [
                            {"type": "section"},
                            {
                                "type": "image",
                                "image_url": "https://example.com/42.jpg",
                            },
                            {"type": "actions"},
                        ],
                    },
                }
                callbacks = Mock()
                with patch.object(slack, "message_slack_raw", callbacks.archive):
                    slack.handle_report_review(callbacks.ack, body, callbacks.respond)
                self.assertEqual(
                    [call[0] for call in callbacks.mock_calls],
                    ["ack", "archive", "respond"],
                )
                archive = callbacks.archive.call_args.kwargs
                self.assertEqual(archive["thread_ts"], "123")
                self.assertEqual(archive["channel"], "C123")
                self.assertEqual(archive["blocks"][1], body["message"]["blocks"][1])
                self.assertNotIn("<!channel>", slack.json.dumps(archive))
                result = callbacks.respond.call_args.kwargs
                self.assertTrue(result["replace_original"])
                self.assertEqual(result["blocks"], [])
                self.assertIn(
                    "approved" if decision == "approve" else "rejected", result["text"]
                )

                callbacks.reset_mock()
                callbacks.archive.side_effect = slack.SlackApiError(
                    "failed", {"ok": False}
                )
                with patch.object(slack, "message_slack_raw", callbacks.archive):
                    slack.handle_report_review(callbacks.ack, body, callbacks.respond)
                self.assertFalse(callbacks.respond.call_args.kwargs["replace_original"])


if __name__ == "__main__":
    unittest.main()
