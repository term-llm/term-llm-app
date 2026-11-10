"""Offline nginx download-route contract; never access the production server."""
from pathlib import Path
import re
import unittest

import sparkle_updates as sparkle


CONFIG = Path(__file__).resolve().parents[2] / "docs/deployment/mac.conf"


class DownloadConfigTests(unittest.TestCase):
    def test_stable_download_is_direct_uncached_attachment(self):
        config = CONFIG.read_text()
        location = config.split("location = /mac/download {", 1)[1].split("\n}", 1)[0]
        for directive in (
            "alias /var/www/term-llm-downloads/mac/term-llm-macos-latest.zip;",
            "disable_symlinks on;",
            "types { }",
            "default_type application/zip;",
            """add_header Content-Disposition 'attachment; filename="term-llm-macos.zip"' always;""",
            'add_header Cache-Control "no-cache, max-age=0, must-revalidate" always;',
            "add_header X-Content-Type-Options nosniff always;",
        ):
            self.assertIn(directive, location)
        self.assertNotRegex(location, r"\b(return|rewrite)\b")
        self.assertEqual(sparkle.DOWNLOAD, "https://term-llm.com/mac/download")
        self.assertEqual(sparkle.LATEST_ASSET, "term-llm-macos-latest.zip")

    def test_fixed_filename_is_not_public(self):
        config = CONFIG.read_text()
        archive_pattern = re.search(r'location ~ "([^"]+)"', config).group(1)
        self.assertIsNotNone(re.fullmatch(archive_pattern, "/mac/term-llm-macos-1.0.1-7-" + "0" * 64 + ".zip"))
        self.assertIsNone(re.fullmatch(archive_pattern, "/mac/term-llm-macos-latest.zip"))
        self.assertNotIn("location = /mac/term-llm-macos-latest.zip", config)
        self.assertIn("location /mac/ { return 404; }", config)


if __name__ == "__main__":
    unittest.main()
