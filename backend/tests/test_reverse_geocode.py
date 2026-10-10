import unittest

from pennyme.locations import area_from_google_result, first_reverse_geocode_result


class FakeGoogleMapsClient:
    def __init__(self, results):
        self.results = results
        self.calls = []

    def reverse_geocode(self, coordinates, **kwargs):
        self.calls.append((coordinates, kwargs))
        return self.results


class ReverseGeocodeResultTests(unittest.TestCase):
    def test_returns_first_result_and_forwards_result_type(self):
        expected = {"formatted_address": "Main Street 1"}
        client = FakeGoogleMapsClient([expected, {"formatted_address": "Other"}])

        result = first_reverse_geocode_result(
            client, 47.0, 8.0, result_type="street_address"
        )

        self.assertEqual(result, expected)
        self.assertEqual(
            client.calls,
            [((47.0, 8.0), {"result_type": "street_address"})],
        )


class ReverseGeocodeAreaTests(unittest.TestCase):
    def result(self, country, country_code, region=None):
        components = [
            {
                "long_name": country,
                "short_name": country_code,
                "types": ["country"],
            }
        ]
        if region:
            components.append(
                {
                    "long_name": region,
                    "short_name": "",
                    "types": ["administrative_area_level_1"],
                }
            )
        return {"address_components": components}

    def test_uses_state_for_united_states(self):
        result = self.result("United States", "US", "California")

        self.assertEqual(area_from_google_result(result), "California")

    def test_maps_district_of_columbia_to_pennyme_area(self):
        result = self.result("United States", "US", "District of Columbia")

        self.assertEqual(area_from_google_result(result), "Washington DC")

    def test_uses_country_outside_us_and_uk(self):
        result = self.result("Germany", "DE", "North Rhine-Westphalia")

        self.assertEqual(area_from_google_result(result), "Germany")

    def test_uses_constituent_country_for_united_kingdom(self):
        result = self.result("United Kingdom", "GB", "Scotland")

        self.assertEqual(area_from_google_result(result), "Scotland")


if __name__ == "__main__":
    unittest.main()
