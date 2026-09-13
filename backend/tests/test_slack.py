import importlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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
                    side_effect=lambda processed_image,
                    session: processed_image.convert("RGBA"),
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
                    images = [
                        c["text"]
                        for c in calls[1:]
                        if c["blocks"][0]["type"] == "image"
                    ]
                    self.assertEqual(images, expected_images)
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
                slack.message_slack_report("alert", "42", "comment", "all", directory)
            chunks = [
                call.kwargs["blocks"][0]["text"] for call in post.call_args_list[1:]
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


if __name__ == "__main__":
    unittest.main()
