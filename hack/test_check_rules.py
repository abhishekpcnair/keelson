"""Unit tests for hack/check_rules.py (no new dependencies: unittest plus the PyYAML that check_rules.py uses). Run: python3 -m unittest hack/test_check_rules.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from check_rules import patch_sets_image  # noqa: E402

FAILS = {
    "json6902 replace image (issue #24)":
        '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"evil.io/dex:latest"}]',
    "json strategic-merge (issue #24)":
        '{"spec":{"template":{"spec":{"containers":[{"name":"dex","image":"evil.io/dex:1"}]}}}}',
    "yaml strategic-merge on initContainers": """\
# purpose: test
spec:
  template:
    spec:
      initContainers:
        - name: init
          image: evil.io/init:1
""",
    "json6902 add container object with image":
        '[{"op":"add","path":"/spec/template/spec/containers/-","value":{"name":"x","image":"evil.io/x:1"}}]',
    "yaml json6902 op list with header": """\
# purpose: test
# upstream: none
# remove-when: never
- op: replace
  path: /spec/template/spec/containers/0/image
  value: evil.io/dex:1
""",
    "string value with image: (chart rejects it too)": 'cfg: "image: x"\n',
    "unparseable text with image:": "spec: [unclosed\n  image: evil.io/x:1\n",
}

PASSES = {
    "replicas patch": '[{"op":"replace","path":"/spec/replicas","value":2}]',
    "imagePullPolicy only": """\
spec:
  template:
    spec:
      containers:
        - name: dex
          imagePullPolicy: Always
""",
    "json6902 path on imagePullPolicy":
        '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]',
}


class PatchSetsImage(unittest.TestCase):
    def test_fails(self):
        for name, text in FAILS.items():
            with self.subTest(name):
                self.assertTrue(patch_sets_image(text))

    def test_passes(self):
        for name, text in PASSES.items():
            with self.subTest(name):
                self.assertFalse(patch_sets_image(text))


if __name__ == "__main__":
    unittest.main()
