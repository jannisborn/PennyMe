import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from pennyme.moderation import (
    ModerationStore,
    parse_report_request,
    text_block_reason,
    validate_report,
)


class TextModerationTests(unittest.TestCase):
    def test_blocks_profanity_as_a_word(self):
        self.assertIsNotNone(
            text_block_reason("A normal title", "This is fucking awful")
        )

    def test_does_not_block_substrings_in_normal_words(self):
        self.assertIsNone(
            text_block_reason("Classic brass machine", "A family attraction")
        )

    def test_blocks_threatening_phrase(self):
        self.assertIsNotNone(text_block_reason("I will hurt you"))

    def test_validates_report_fields(self):
        self.assertIsNone(validate_report("image", "spam_scam"))
        self.assertIsNotNone(validate_report("profile", "spam_scam"))
        self.assertIsNotNone(validate_report("image", "invalid"))

    def test_ignores_ip_field_from_legacy_request(self):
        parsed = parse_report_request(
            {
                "machine_id": "42",
                "target_kind": "image",
                "target_id": "machine",
                "reason": "other",
                "block_contributor": "true",
                "ip": "203.0.113.7",
            }
        )

        self.assertNotIn("ip", parsed)
        self.assertEqual(parsed["machine_id"], "42")
        self.assertTrue(parsed["block_contributor"])


class ModerationStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        root = Path(self.temp_dir.name)
        self.store = ModerationStore(root / "attribution.json", root / "reports.jsonl")

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_records_public_pseudonym_without_exposing_installation_id(self):
        contributor = self.store.record_content(
            "42", "image:coin_0", "secret-installation-id"
        )
        manifest = self.store.manifest("42", viewer_id="viewer-a")

        self.assertNotEqual(manifest["image:coin_0"], contributor)
        self.assertNotIn("secret-installation-id", json.dumps(manifest))
        resolved = self.store.resolve_content("42", "image:coin_0")
        self.assertEqual(resolved["contributor_id"], contributor)

    def test_block_ids_are_stable_for_one_viewer_but_differ_between_viewers(self):
        contributor = self.store.record_content("42", "image:coin_0", "installation-id")
        first = self.store.block_id(contributor, "viewer-a")
        second = self.store.block_id(contributor, "viewer-a")
        other_viewer = self.store.block_id(contributor, "viewer-b")
        self.assertEqual(first, second)
        self.assertNotEqual(first, other_viewer)

    def test_repeated_manifests_reuse_the_attribution_cache(self):
        self.store.attribution_path.write_text(
            json.dumps(
                {
                    "42": {
                        "image:machine": {
                            "contributor_id": "contributor-a",
                            "updated_at": "2026-07-24T00:00:00+00:00",
                        }
                    },
                    "43": {
                        "image:machine": {
                            "contributor_id": "contributor-b",
                            "updated_at": "2026-07-24T00:00:00+00:00",
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

        with patch("pennyme.moderation.json.load", wraps=json.load) as json_load:
            first = self.store.manifest("42", viewer_id="viewer-a")
            second = self.store.manifest("42", viewer_id="viewer-a")

        self.assertEqual(first, second)
        self.assertEqual(json_load.call_count, 1)

    def test_listing_manifest_returns_only_listing_owners(self):
        listing_contributor = self.store.record_content(
            "42", "machine:listing", "listing-installation"
        )
        self.store.record_content("42", "image:machine", "image-installation")
        self.store.record_content("43", "comment:now", "comment-installation")

        manifest = self.store.listing_manifest(viewer_id="viewer-a")

        self.assertEqual(
            manifest,
            {"42": self.store.block_id(listing_contributor, "viewer-a")},
        )

    def test_legacy_clients_are_scoped_to_individual_content(self):
        first = self.store.record_content("42", "comment:a", "")
        second = self.store.record_content("43", "comment:b", "")
        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith("legacy-"))
        self.assertTrue(second.startswith("legacy-"))

    def test_contributor_id_requires_an_installation_id(self):
        self.assertIsNone(self.store.contributor_id(""))
        self.assertIsNone(self.store.contributor_id("   "))

    def test_contributor_ids_are_stable_and_installation_specific(self):
        first = self.store.contributor_id("installation-a")
        repeated = self.store.contributor_id("installation-a")
        other = self.store.contributor_id("installation-b")
        self.assertEqual(first, repeated)
        self.assertNotEqual(first, other)

    def test_legacy_content_gets_stable_content_scoped_identity(self):
        first = self.store.resolve_content("42", "image:machine")
        second = self.store.resolve_content("42", "image:machine")
        other = self.store.resolve_content("42", "image:coin_0")
        self.assertEqual(first, second)
        self.assertNotEqual(first["contributor_id"], other["contributor_id"])

    def test_appends_reports(self):
        first_report = {
            "machine_id": "42",
            "content_key": "image:machine",
            "reason": "other",
            "block_contributor": False,
            "contributor_id": "contributor-a",
            "reporter_id": "reporter-a",
        }
        second_report = {**first_report, "machine_id": "43", "reason": "violence"}
        self.store.record_report(first_report)
        self.store.record_report(second_report)
        lines = self.store.reports_path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(json.loads(lines[1])["machine_id"], "43")


if __name__ == "__main__":
    unittest.main()
