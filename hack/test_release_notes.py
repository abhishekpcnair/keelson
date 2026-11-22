"""Unit tests for hack/release_notes.py. Run: python3 -m unittest hack/test_release_notes.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_notes  # noqa: E402

CHANGELOG = """# Changelog

## v0.2.0

### Features
- second

## v0.1.0-alpha.1 (2026-12-01)

### Features
- first thing
- second thing

### Fixes
- a fix

## v0.1.0

### Features
- final

## v0.0.1

- empty-ish
"""


class Section(unittest.TestCase):
    def test_returns_the_body_without_the_heading(self):
        text = release_notes.section(CHANGELOG, "v0.1.0-alpha.1")
        self.assertTrue(text.startswith("### Features\n- first thing"))
        self.assertIn("### Fixes\n- a fix", text)
        self.assertNotIn("## v", text)
        self.assertNotIn("final", text)

    def test_a_release_is_not_matched_by_its_prerelease_or_the_reverse(self):
        self.assertEqual(release_notes.section(CHANGELOG, "v0.1.0"), "### Features\n- final\n")
        self.assertNotIn("final", release_notes.section(CHANGELOG, "v0.1.0-alpha.1"))

    def test_dots_in_the_version_are_literal(self):
        with self.assertRaises(ValueError):
            release_notes.section("## v0x1x0\n- x\n", "v0.1.0")

    def test_last_section_runs_to_the_end(self):
        self.assertEqual(release_notes.section(CHANGELOG, "v0.0.1"), "- empty-ish\n")

    def test_missing_section_fails(self):
        with self.assertRaisesRegex(ValueError, "no '## v9.9.9' section"):
            release_notes.section(CHANGELOG, "v9.9.9")

    def test_empty_section_fails(self):
        with self.assertRaisesRegex(ValueError, "is empty"):
            release_notes.section("## v1.0.0\n\n## v0.9.0\n- x\n", "v1.0.0")

    def test_tag_without_v_prefix_works(self):
        self.assertEqual(release_notes.section(CHANGELOG, "0.0.1"), "- empty-ish\n")


if __name__ == "__main__":
    unittest.main()
