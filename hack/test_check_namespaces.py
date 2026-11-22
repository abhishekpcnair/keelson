"""Unit tests for hack/check_namespaces.py with a stub kubectl. Run: python3 -m unittest hack/test_check_namespaces.py"""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import check_namespaces  # noqa: E402

# The stub prints the file <path>/out.yaml, so each fake upstream path holds its own kustomize output.
STUB = '#!/bin/sh\n[ "$1" = kustomize ] && exec cat "$2/out.yaml"\nexit 1\n'


class CheckModule(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        stub = self.root / "kubectl"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self._kubectl = check_namespaces.KUBECTL
        check_namespaces.KUBECTL = str(stub)

    def tearDown(self):
        check_namespaces.KUBECTL = self._kubectl
        self.tmp.cleanup()

    def path(self, name, out):
        d = self.root / "up" / name
        d.mkdir(parents=True)
        (d / "out.yaml").write_text(out)
        return name

    def mod(self, ns, nss, path, platform=None):
        src = {"type": "kustomize", "path": path}
        if platform:
            src["platformPaths"] = {"kind": platform}
        return {"name": "m", "namespace": ns, "namespaces": nss, "source": src}

    def test_match(self):
        p = self.path("a", "kind: Namespace\nmetadata: {name: x}\n---\nkind: Service\nmetadata: {name: s, namespace: y}\n")
        self.assertEqual(check_namespaces.check_module(self.mod("x", ["x", "y"], p), self.root / "up"), ([], []))

    def test_missing_namespace_fails(self):
        p = self.path("a", "kind: Service\nmetadata: {name: s, namespace: kube-system}\n")
        fails, _ = check_namespaces.check_module(self.mod("x", ["x"], p), self.root / "up")
        self.assertEqual(len(fails), 1)
        self.assertIn("kube-system", fails[0])

    def test_extra_namespace_warns(self):
        p = self.path("a", "kind: Service\nmetadata: {name: s, namespace: x}\n")
        fails, warns = check_namespaces.check_module(self.mod("x", ["x", "spare"], p), self.root / "up")
        self.assertEqual(fails, [])
        self.assertIn("spare", warns[0])

    def test_platform_only_namespace_does_not_warn(self):
        base = self.path("base", "kind: Service\nmetadata: {name: s, namespace: x}\n")
        kind = self.path("kind", "kind: Service\nmetadata: {name: s, namespace: kind-only}\n")
        self.assertEqual(
            check_namespaces.check_module(self.mod("x", ["x", "kind-only"], base, kind), self.root / "up"), ([], []))

    def test_non_kustomize_skipped(self):
        m = {"name": "m", "namespace": "x", "source": {"type": "helm", "path": "nowhere"}}
        self.assertEqual(check_namespaces.check_module(m, self.root / "up"), ([], []))

    def test_missing_kubectl(self):
        check_namespaces.KUBECTL = str(self.root / "no-such-kubectl")
        p = self.path("a", "")
        with self.assertRaises(check_namespaces.MissingTool):
            check_namespaces.check_module(self.mod("x", ["x"], p), self.root / "up")


class MainCli(unittest.TestCase):
    """Run the script on a temp chart: exit codes, FAIL lines, stderr."""
    SCRIPT = pathlib.Path(__file__).resolve().parent / "check_namespaces.py"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        (self.root / "chart/modules").mkdir(parents=True)
        (self.root / "chart/values.yaml").write_text("upstream: {manifestsRef: '1.0'}\n")
        (self.root / "cache/1.0").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, module_text, kubectl=None):
        (self.root / "chart/modules/m.yaml").write_text(module_text)
        env = dict(os.environ)
        if kubectl:
            env["KUBECTL"] = kubectl
        return subprocess.run(
            [sys.executable, str(self.SCRIPT), "--chart", str(self.root / "chart"), "--cache", str(self.root / "cache")],
            capture_output=True, text=True, env=env)

    def test_empty_module_file(self):
        r = self.run_cli("")
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL N0", r.stdout)
        self.assertIn("missing required field name", r.stdout)
        self.assertNotIn("Traceback", r.stderr)

    def test_missing_source_path(self):
        r = self.run_cli("name: m\nsource: {type: kustomize}\n")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout.count("FAIL N0"), 1)
        self.assertIn("missing required field source.path", r.stdout)

    def test_tool_cannot_run(self):
        tool = self.root / "kubectl"
        tool.write_text("#!/bin/sh\n")
        tool.chmod(0o644)
        r = self.run_cli("name: m\nnamespace: x\nsource: {type: kustomize, path: p}\n", kubectl=str(tool))
        self.assertEqual(r.returncode, 2)
        self.assertIn("cannot run", r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertNotIn("cannot run", r.stdout)


if __name__ == "__main__":
    unittest.main()
