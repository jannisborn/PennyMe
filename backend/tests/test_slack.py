import importlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from pennyme.moderation import ModerationStore

from PIL import Image

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
                    side_effect=lambda processed_image, session: processed_image.convert(
                        "RGBA"
                    ),
                ) as remove:
                    code, _, saved_path = process_uploaded_image(str(coin_path))

            self.assertEqual(code, 200)
            self.assertEqual(Path(saved_path).suffix, ".png")
            self.assertLessEqual(Path(saved_path).stat().st_size, 500 * 1024)
            remove.assert_called_once()


class ReportSlackTest(unittest.TestCase):
    def test_reports_include_only_target_content_and_thread_in_approvals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            (root / "comments/42.json").write_text('{"date": "flagged comment"}')
            for name in ("42.jpg", "42_coin_0.png", "420.jpg", "42_other.png"):
                (root / name).touch()
            for kind, target, expected_uploads, expected_linked_images in (
                ("image", "machine", ["42.jpg"], []),
                ("image", "coin_0", ["42_coin_0.png"], []),
                ("comment", "all", [], []),
                ("machine", "listing", [], ["42.jpg", "42_coin_0.png"]),
            ):
                with (
                    self.subTest(kind=kind, target=target),
                    patch.object(
                        slack.CLIENT,
                        "chat_postMessage",
                        return_value={"channel": "C123", "ts": "123"},
                    ) as post,
                    patch.object(slack.CLIENT, "files_upload_v2") as upload,
                    patch.object(
                        slack,
                        "find_machine_in_database",
                        return_value={"name": "Listing"},
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
                    self.assertEqual(calls[0]["text"], "<!channel> UGC REPORT")
                    action_ids = [
                        element["action_id"]
                        for block in calls[0]["blocks"]
                        if block["type"] == "actions"
                        for element in block["elements"]
                    ]
                    self.assertEqual(
                        action_ids,
                        (
                            ["approve_report", "reject_report"]
                            if kind in {"comment", "image"}
                            else []
                        ),
                    )
                    self.assertTrue(all(c["channel"] == "C123" for c in calls[1:]))
                    self.assertTrue(all(c["thread_ts"] == "123" for c in calls[1:]))
                    self.assertIn(
                        "UGC REPORT\nReporter explanation: This content is wrong",
                        calls[1]["blocks"][0]["text"]["text"],
                    )
                    linked_images = [
                        c["text"]
                        for c in calls[1:]
                        if c["blocks"][0]["type"] == "image"
                    ]
                    self.assertEqual(linked_images, expected_linked_images)
                    uploads = [
                        Path(call.kwargs["file"]).name for call in upload.call_args_list
                    ]
                    self.assertEqual(uploads, expected_uploads)
                    text = "".join(c["text"] for c in calls[1:])
                    self.assertEqual(
                        "flagged comment" in text, kind in {"comment", "machine"}
                    )
                    self.assertEqual("Listing" in text, kind == "machine")

    def test_long_comments_are_preserved_as_plain_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "comments").mkdir()
            comment = "<!channel>" + "x" * 7000
            (root / "comments/42.json").write_text(slack.json.dumps({"date": comment}))
            with patch.object(
                slack.CLIENT, "chat_postMessage", return_value={"ts": "123"}
            ) as post:
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
                    "target_kind": "image",
                    "target_id": "machine",
                    "content_key": "image:machine",
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
            _, decision = store.report_status("report-id")
            self.assertEqual(decision, "rejected")
            self.assertEqual(respond.call_args.kwargs["blocks"], [])


if __name__ == "__main__":
    unittest.main()
