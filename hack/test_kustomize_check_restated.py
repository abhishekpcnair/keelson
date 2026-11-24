"""Unit tests for the restated-file drift guard in hack/kustomize_check.py. Run: python3 -m unittest hack/test_kustomize_check_restated.py"""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import kustomize_check  # noqa: E402

OURS = "restated/labels.yaml"
THEIRS = "up/labels.yaml"
UPSTREAM = 'a: "1"\nb: "2"\n'


class CheckRestated(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.chart, self.upstream = root / "chart", root / "26.10.0"
        (self.chart / "restated").mkdir(parents=True)
        (self.upstream / "up").mkdir(parents=True)
        (self.upstream / THEIRS).write_text(UPSTREAM)
        self._restated = kustomize_check.RESTATED
        kustomize_check.RESTATED = {OURS: THEIRS}

    def tearDown(self):
        kustomize_check.RESTATED = self._restated
        self.tmp.cleanup()

    def check(self, ours):
        (self.chart / OURS).write_text(ours)
        return kustomize_check.check_restated(self.chart, self.upstream)

    def test_equal_passes_with_comments_and_order(self):
        self.assertEqual(self.check('# purpose: x\nb: "2"\na: "1"\n'), [])

    def test_changed_value_fails(self):
        self.assertIn("drift", self.check('a: "1"\nb: "3"\n')[0])

    def test_label_added_upstream_fails(self):
        self.assertIn("drift", self.check('a: "1"\n')[0])

    def test_label_removed_upstream_fails(self):
        self.assertIn("drift", self.check('a: "1"\nb: "2"\nc: "3"\n')[0])

    def test_upstream_file_missing_fails(self):
        (self.upstream / THEIRS).unlink()
        self.assertIn("missing", self.check(UPSTREAM)[0])


if __name__ == "__main__":
    unittest.main()
