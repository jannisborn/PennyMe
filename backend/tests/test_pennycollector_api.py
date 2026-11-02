import json
import unittest
from copy import deepcopy
from unittest.mock import Mock, patch

import requests

from pennyme.pennycollector_api import _get_collection, get_locations


def location_record():
    # Fields observed on the public API on 2026-10-27. The WordPress ID and
    # legacy location ID are deliberately different.
    return {
        "id": 23458,
        "title": {"rendered": "Centro Comercial da Torre"},
        "pc_area": [181],
        "acf": {
            "legacy_id": 319574,
            "status": "Active",
            "last_updated": "2024-04-23",
            "address": "Alvoco da Serra, Loriga",
            "city": "Seia, Serra da Estrela",
            "source_url": "http://locations.pennycollector.com/Details.aspx?location=319574",
        },
    }


def response(rows, total, pages, status=200):
    result = requests.Response()
    result.status_code = status
    result.url = "https://pennycollector.com/wp-json/wp/v2/pc_location"
    result.headers.update(
        {
            "Content-Type": "application/json; charset=UTF-8",
            "X-WP-Total": str(total),
            "X-WP-TotalPages": str(pages),
        }
    )
    result._content = json.dumps(rows).encode()
    return result


class PennyCollectorApiTests(unittest.TestCase):
    def test_reads_all_pages_and_rejects_incomplete_or_inconsistent_catalogues(self):
        first = [{"id": i} for i in range(100)]
        with patch("pennyme.pennycollector_api.time.sleep"):
            session = Mock()
            session.get.side_effect = [
                response(first, 101, 2),
                response([{"id": 100}], 101, 2),
            ]
            self.assertEqual(len(_get_collection(session, "pc_location", "id")), 101)
            self.assertEqual(session.get.call_args.kwargs["params"]["page"], 2)
            self.assertEqual(session.get.call_args.kwargs["timeout"], (10, 40))

            bad_sequences = [
                [response([], 0, 0)],
                [response(first[:99], 101, 2)],
                [response(first, 101, 2), response([], 101, 2)],
                [response(first, 101, 2), response([{"id": 100}], 102, 2)],
                [response(first, 101, 2), response([{"id": 0}], 101, 2)],
            ]
            for replies in bad_sequences:
                with self.subTest(replies=replies):
                    session.get.side_effect = replies
                    with self.assertRaises(ValueError):
                        _get_collection(session, "pc_location", "id")

    def test_blocks_challenges_html_http_errors_and_timeouts(self):
        for status, content_type, challenge in [
            (200, "text/html", None),
            (200, "text/html", "challenge"),
            (403, "text/html", "challenge"),
            (503, "application/json", None),
        ]:
            with self.subTest(status=status, challenge=challenge):
                result = response([], 0, 0, status)
                result.headers["Content-Type"] = content_type
                if challenge:
                    result.headers["cf-mitigated"] = challenge
                with self.assertRaises((ValueError, requests.HTTPError)):
                    _get_collection(
                        Mock(get=Mock(return_value=result)), "pc_location", "id"
                    )
        with self.assertRaises(requests.Timeout):
            _get_collection(
                Mock(get=Mock(side_effect=requests.Timeout)), "pc_location", "id"
            )

    def test_preserves_legacy_identity_status_dates_and_unicode(self):
        record = location_record()
        record["title"]["rendered"] = "Torre &amp; Café"
        terms = [{"id": 181, "name": "Portugal"}]
        for state, expected in [
            ("Active", "available"),
            ("Gone", "Gone"),
            ("Moved", "Moved"),
            ("Out of Order", "Out of Order"),
        ]:
            record["acf"]["status"] = state
            with patch(
                "pennyme.pennycollector_api._get_collection",
                side_effect=[terms, [record]],
            ):
                feature = get_locations()["Portugal"][0]
            self.assertEqual(
                feature["properties"]["external_url"], record["acf"]["source_url"]
            )
            self.assertEqual(feature["properties"]["id"], -1)
            self.assertEqual(feature["properties"]["name"], "Torre & Café")
            self.assertEqual(feature["properties"]["machine_status"], expected)
            self.assertEqual(feature["temporary"]["website_updated"], "2024-04-23")

    def test_rejects_unsafe_identity_dates_status_and_taxonomy(self):
        record = location_record()
        invalid_records = []
        for key, value in [
            ("legacy_id", None),
            ("legacy_id", 0),
            ("source_url", "https://pennycollector.com/locations/portugal/torre/"),
            ("status", "Unknown"),
            ("last_updated", "bad-date"),
        ]:
            bad = deepcopy(record)
            bad["acf"][key] = value
            invalid_records.append([bad])
        invalid_records.append([record, record])
        bad = deepcopy(record)
        bad["pc_area"] = [181, 182]
        invalid_records.append([bad])
        for rows in invalid_records:
            with (
                self.subTest(rows=rows),
                patch(
                    "pennyme.pennycollector_api._get_collection",
                    side_effect=[[{"id": 181, "name": "Portugal"}], rows],
                ),
            ):
                with self.assertRaises(ValueError):
                    get_locations()
        with patch(
            "pennyme.pennycollector_api._get_collection",
            return_value=[{"id": 1, "name": "Unknown area"}],
        ):
            with self.assertRaisesRegex(ValueError, "Unknown PennyCollector areas"):
                get_locations()

    def test_excludes_books_and_private_rollers(self):
        terms = [
            {"id": 181, "name": "Portugal"},
            {"id": 155, "name": "Collector Books"},
            {"id": 173, "name": "Private Rollers"},
        ]
        records = [
            location_record(),
            {"id": 1, "pc_area": [155]},
            {"id": 2, "pc_area": [173]},
        ]
        with patch(
            "pennyme.pennycollector_api._get_collection", side_effect=[terms, records]
        ):
            self.assertEqual(list(get_locations()), ["Portugal"])

    def test_native_listings_use_canonical_url_without_inventing_legacy_ids(self):
        record = location_record()
        record.update(
            id=30245,
            link="https://pennycollector.com/locations/germany/alfred-kunze-sportpark/",
        )
        record["acf"].update(legacy_id="", source_url="")
        for legacy in ("", None, 0):
            record["acf"]["legacy_id"] = legacy
            with patch(
                "pennyme.pennycollector_api._get_collection",
                side_effect=[[{"id": 181, "name": "Germany"}], [record]],
            ):
                feature = get_locations()["Germany"][0]
            self.assertEqual(feature["properties"]["external_url"], record["link"])
            self.assertEqual(feature["temporary"]["wordpress_id"], 30245)
            self.assertEqual(feature["properties"]["id"], -1)
        for url in (
            "",
            "https://example.com/locations/germany/test/",
            "http://pennycollector.com/locations/germany/test/",
            "https://pennycollector.com/",
            "https://pennycollector.com/locations/germany/test/?location=30245",
        ):
            record["link"] = url
            with patch(
                "pennyme.pennycollector_api._get_collection",
                side_effect=[[{"id": 181, "name": "Germany"}], [record]],
            ):
                with self.assertRaises(ValueError):
                    get_locations()


if __name__ == "__main__":
    unittest.main()
