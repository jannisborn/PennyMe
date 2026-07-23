import importlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

os.environ.setdefault("SLACK_TOKEN", "test")

process_uploaded_image = importlib.import_module("pennyme.slack").process_uploaded_image


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

            with (
                patch("pennyme.slack.new_session", return_value=object()),
                patch(
                    "pennyme.slack.remove",
                    side_effect=lambda processed_image,
                    session: processed_image.convert("RGBA"),
                ) as remove,
            ):
                code, _, saved_path = process_uploaded_image(str(coin_path))

            self.assertEqual(code, 200)
            self.assertEqual(Path(saved_path).suffix, ".png")
            self.assertLessEqual(Path(saved_path).stat().st_size, 500 * 1024)
            remove.assert_called_once()


if __name__ == "__main__":
    unittest.main()
