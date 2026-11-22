"""Unit tests for hack/check_namespaces.py with a stub kubectl. Run: python3 -m unittest hack/test_check_namespaces.py"""
import pathlib
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


if __name__ == "__main__":
    unittest.main()
