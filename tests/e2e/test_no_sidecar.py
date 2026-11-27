"""Offline tests for tests/e2e/lib/no_sidecar.py (issue #12)."""
import importlib.util
import pathlib
import unittest

_spec = importlib.util.spec_from_file_location(
    "no_sidecar", pathlib.Path(__file__).parent / "lib" / "no_sidecar.py")
no_sidecar = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(no_sidecar)


def pod(rs, containers, init=(), phase="Running", owner_kind="ReplicaSet"):
    return {
        "metadata": {"ownerReferences": [{"kind": owner_kind, "name": rs}]},
        "spec": {"containers": [{"name": c} for c in containers],
                 "initContainers": [{"name": c} for c in init]},
        "status": {"phase": phase},
    }


class NoSidecar(unittest.TestCase):
    def test_finds_only_pods_without_sidecar(self):
        pods = {"items": [
            pod("ml-pipeline-ui-7f7c744bc7", ["ml-pipeline-ui"]),
            pod("ml-pipeline-6d5f8b9c4d", ["ml-pipeline-api-server", "istio-proxy"]),
            pod("metadata-grpc-deployment-5c8b", ["container"], init=["istio-proxy"]),  # native sidecar
        ]}
        self.assertEqual(no_sidecar.deployments_without_sidecar(pods), ["ml-pipeline-ui"])

    def test_skips_jobs_and_pods_not_running(self):
        pods = {"items": [
            pod("some-job", ["main"], owner_kind="Job"),
            pod("seaweedfs-5b6c7d", ["seaweedfs"], phase="Pending"),
            {"metadata": {}, "spec": {"containers": [{"name": "bare"}]}, "status": {"phase": "Running"}},
        ]}
        self.assertEqual(no_sidecar.deployments_without_sidecar(pods), [])

    def test_names_are_unique_and_sorted(self):
        pods = {"items": [pod("b-1", ["x"]), pod("a-2", ["x"]), pod("b-1", ["x"])]}
        self.assertEqual(no_sidecar.deployments_without_sidecar(pods), ["a", "b"])


if __name__ == "__main__":
    unittest.main()
