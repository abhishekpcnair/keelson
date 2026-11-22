"""Unit tests for the tool-pin check in hack/upstream_watch.py. Run: python3 -m unittest hack/test_upstream_watch.py"""
import contextlib
import io
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import upstream_watch  # noqa: E402

TAGS = {
    "https://github.com/argoproj/argo-cd": {"v3.6.2", "v3.7.0", "v3.8.0-rc1", "stable"},
    "https://github.com/kubernetes-sigs/metrics-server": {"v0.9.1", "metrics-server-helm-chart-3.14.0"},
}


class CheckPins(unittest.TestCase):
    def run_check(self, text):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d) / "kind-up.sh"
            f.write_text(text)
            out = io.StringIO()
            with mock.patch.object(upstream_watch, "remote_tags", side_effect=lambda r: TAGS[r]), \
                    contextlib.redirect_stdout(out):
                rows, newer = upstream_watch.check_pins(f)
        return {r[0]: r for r in rows}, newer, out.getvalue()

    def test_newer_release_ignores_rc(self):
        rows, newer, _ = self.run_check('ARGOCD_VERSION="v3.6.2"\nMETRICS_SERVER_VERSION="v0.9.1"\n')
        self.assertEqual(rows["ARGOCD_VERSION"][2], "v3.7.0")
        self.assertTrue(rows["ARGOCD_VERSION"][3])
        self.assertTrue(newer)

    def test_pin_is_latest(self):
        rows, newer, _ = self.run_check('METRICS_SERVER_VERSION="v0.9.1"\nARGOCD_VERSION="v3.7.0"\n')
        self.assertEqual(rows["METRICS_SERVER_VERSION"][2], "v0.9.1")
        self.assertFalse(newer)

    def test_pin_not_in_file(self):
        rows, newer, out = self.run_check('ARGOCD_VERSION="v3.7.0"\n')
        self.assertNotIn("METRICS_SERVER_VERSION", rows)
        self.assertIn("NOTE pin METRICS_SERVER_VERSION not found", out)
        self.assertFalse(newer)


if __name__ == "__main__":
    unittest.main()
