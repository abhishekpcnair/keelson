"""Unit tests for hack/list_images.py. Run: python3 -m unittest hack/test_list_images.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import list_images  # noqa: E402

DEPLOYMENT = """
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      initContainers:
        - {name: init, image: quay.io/a/init:1}
      containers:
        - {name: app, image: "ghcr.io/b/app:2"}
        - {name: side, image: ghcr.io/b/app:2}
---
apiVersion: batch/v1
kind: CronJob
spec:
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - {name: job, image: docker.io/c/job:3}
"""


WORKSPACEKIND = """
apiVersion: kubeflow.org/v1beta1
kind: WorkspaceKind
spec:
  podTemplate:
    options:
      imageConfig:
        spawner: {default: jupyter-scipy}
        values:
          - id: jupyter-scipy
            spec: {image: "ghcr.io/kubeflow/kubeflow/notebook-servers/jupyter-scipy:v1.9.2", imagePullPolicy: IfNotPresent}
          - id: broken
            spec: {imagePullPolicy: Always}
"""


class ImagesIn(unittest.TestCase):
    def test_collects_workspacekind_image_options(self):
        self.assertEqual(
            list_images.images_in(WORKSPACEKIND),
            {"ghcr.io/kubeflow/kubeflow/notebook-servers/jupyter-scipy:v1.9.2"},
        )

    def test_workspacekind_without_image_config_has_no_images(self):
        self.assertEqual(list_images.images_in("kind: WorkspaceKind\nspec: {podTemplate: {}}\n"), set())

    def test_collects_containers_and_init_containers_once_each(self):
        self.assertEqual(
            list_images.images_in(DEPLOYMENT),
            {"quay.io/a/init:1", "ghcr.io/b/app:2", "docker.io/c/job:3"},
        )

    def test_ignores_image_keys_outside_container_lists(self):
        manifests = "kind: Notebook\nspec:\n  image: ghcr.io/not/listed:1\n  template: {image: also-not}\n"
        self.assertEqual(list_images.images_in(manifests), set())

    def test_ignores_containers_without_a_string_image(self):
        manifests = "kind: Pod\nspec:\n  containers:\n    - {name: a}\n    - {name: b, image: 5}\n"
        self.assertEqual(list_images.images_in(manifests), set())


if __name__ == "__main__":
    unittest.main()
