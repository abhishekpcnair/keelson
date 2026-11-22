"""Unit tests for hack/check_rules.py (no new dependencies: unittest plus the PyYAML that check_rules.py uses). Run: python3 -m unittest hack/test_check_rules.py"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import contextlib  # noqa: E402
import io  # noqa: E402
import os  # noqa: E402
import tempfile  # noqa: E402
from unittest import mock  # noqa: E402

from check_rules import check_symlinks, check_templates, patch_sets_image  # noqa: E402

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


class CheckSymlinks(unittest.TestCase):
    def test_not_a_git_repo_fails(self):
        errors = []
        with tempfile.TemporaryDirectory() as d:
            # No GIT_* variables, and git must not look above the temp dir for a repo.
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            env["GIT_CEILING_DIRECTORIES"] = str(pathlib.Path(d).parent)
            with mock.patch.dict(os.environ, env, clear=True):
                check_symlinks(pathlib.Path(d), errors)
        self.assertEqual(len(errors), 1)
        # Keelson's own prefix: it doesn't depend on git's locale.
        self.assertTrue(errors[0].startswith("R6 "))
        self.assertIn("git ls-files failed", errors[0])

    def test_git_cannot_run_fails(self):
        errors, out = [], io.StringIO()
        with mock.patch("check_rules.subprocess.run", side_effect=PermissionError("git")), \
                contextlib.redirect_stdout(out):
            check_symlinks(pathlib.Path("."), errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("git cannot run", errors[0])
        self.assertNotIn("NOTE", out.getvalue())

    def test_git_missing_skips_with_note(self):
        errors, out = [], io.StringIO()
        with mock.patch("check_rules.subprocess.run", side_effect=FileNotFoundError("git")), \
                contextlib.redirect_stdout(out):
            check_symlinks(pathlib.Path("."), errors)
        self.assertEqual(errors, [])
        self.assertIn("NOTE R6 skipped", out.getvalue())


class CheckTemplates(unittest.TestCase):
    def run_t1(self, text):
        errors = []
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "_x.tpl").write_text(text)
            check_templates(pathlib.Path(d), errors)
        return errors

    def test_comment_above_own_define(self):
        text = '{{/*\nkeelson.a: first helper.\n*/}}\n{{- define "keelson.a" -}}\n{{- end -}}\n'
        self.assertEqual(self.run_t1(text), [])

    def test_other_define_between_fails(self):
        # The #77/#78 mistake: a new helper between a doc comment and its define.
        text = ('{{/*\nkeelson.a: first helper.\n*/}}\n'
                '{{- define "keelson.b" -}}\n{{- end -}}\n\n'
                '{{- define "keelson.a" -}}\n{{- end -}}\n')
        errors = self.run_t1(text)
        self.assertEqual(len(errors), 1)
        self.assertIn("T1", errors[0])
        self.assertIn("keelson.a", errors[0])

    def test_both_comment_forms_checked(self):
        one_line = '{{/* keelson.a: one line. */}}\n{{- define "keelson.wrong" -}}\n{{- end -}}\n'
        next_line = '{{- /*\nkeelson.a: next line.\n*/}}\n{{- define "keelson.wrong" -}}\n{{- end -}}\n'
        self.assertEqual(len(self.run_t1(one_line)), 1)
        self.assertEqual(len(self.run_t1(next_line)), 1)
        self.assertEqual(self.run_t1(one_line.replace("keelson.wrong", "keelson.a")), [])


    def test_indented_comment_above_other_define_fails(self):
        text = ('  {{/*\n  keelson.a: indented doc.\n  */}}\n'
                '  {{- define "keelson.b" -}}\n  {{- end -}}\n')
        errors = self.run_t1(text)
        self.assertEqual(len(errors), 1)
        self.assertIn("keelson.a", errors[0])

    def test_indented_comment_above_own_indented_define(self):
        text = '  {{/* keelson.a: indented. */}}\n  {{- define "keelson.a" -}}\n  {{- end -}}\n'
        self.assertEqual(self.run_t1(text), [])

    def test_missing_folder_fails(self):
        errors = []
        with tempfile.TemporaryDirectory() as d:
            check_templates(pathlib.Path(d) / "no-such-dir", errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("not a directory", errors[0])

    def test_folder_without_tpl_files_fails(self):
        errors = []
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(check_templates(pathlib.Path(d), errors), (0, 0))
        self.assertEqual(len(errors), 1)
        self.assertIn("no *.tpl files", errors[0])

    def test_returns_count(self):
        errors = []
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "_x.tpl").write_text(
                '{{/* keelson.a: one. */}}\n{{- define "keelson.a" -}}\n{{- end -}}\n'
                '{{/* keelson.b: two. */}}\n{{- define "keelson.b" -}}\n{{- end -}}\n')
            self.assertEqual(check_templates(pathlib.Path(d), errors), (2, 1))
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
