"""Unit test of dashboard.get_env_info (#139). Run: python3 -m unittest tests/e2e/test_dashboard_retry.py"""
import importlib.util
import pathlib
import sys
import types
import unittest

# dashboard.py imports requests at the top; the `verify` job has only pyyaml, and this test never calls it.
sys.modules.setdefault("requests", types.ModuleType("requests"))

spec = importlib.util.spec_from_file_location("dashboard", pathlib.Path(__file__).with_name("dashboard.py"))
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)

DENY = "RBAC: access denied"


class Resp:
    def __init__(self, status, text=""):
        self.status_code, self.text, self.headers = status, text, {}


def run(*responses):
    it = iter(responses)
    sleeps = []
    r, n = dashboard.get_env_info(lambda: next(it), sleep=sleeps.append)
    return r, n, sleeps


class GetEnvInfo(unittest.TestCase):
    def test_ok_first_try(self):
        r, n, sleeps = run(Resp(200))
        self.assertEqual((r.status_code, n, sleeps), (200, 1, []))

    def test_403_then_200_retries_and_warns(self):
        r, n, sleeps = run(Resp(403, DENY), Resp(200))
        self.assertEqual((r.status_code, n, sleeps), (200, 2, [5]))

    def test_403_five_times_fails(self):
        r, n, sleeps = run(*[Resp(403, DENY)] * 5)
        self.assertEqual((r.status_code, n, len(sleeps)), (403, 5, 4))

    def test_401_fails_at_once(self):
        r, n, sleeps = run(Resp(401))
        self.assertEqual((r.status_code, n, sleeps), (401, 1, []))

    def test_403_other_body_fails_at_once(self):
        r, n, sleeps = run(Resp(403, '{"error":"forbidden"}'))
        self.assertEqual((r.status_code, n, sleeps), (403, 1, []))


if __name__ == "__main__":
    unittest.main()
