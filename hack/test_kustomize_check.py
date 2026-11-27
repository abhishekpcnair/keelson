import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import kustomize_check as kc  # noqa: E402

BUILT = """
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: kubeflow-admin}
aggregationRule: {clusterRoleSelectors: [{matchLabels: {a: b}}]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: fixed-role}
rules: []
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: istio-validator-istio-system}
"""
ROLE = {"group": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "kubeflow-admin"}


def run(entries):
    errors = []
    kc.check_ignore_differences("m.yaml:app", BUILT, entries, errors, "common/x")
    return errors


class IgnoreDifferences(unittest.TestCase):
    def test_existing_resource_passes(self):
        self.assertEqual(run([{**ROLE, "jsonPointers": ["/rules"]}]), [])

    def test_renamed_resource_fails_with_index(self):
        errors = run([ROLE, {**ROLE, "name": "kubeflow-admin-v2"}])
        self.assertEqual(len(errors), 1)
        self.assertIn("ignoreDifferences[1]", errors[0])
        self.assertIn("rbac.authorization.k8s.io/ClusterRole kubeflow-admin-v2", errors[0])
        self.assertIn("not in common/x", errors[0])

    def test_wrong_group_fails(self):
        self.assertEqual(len(run([{**ROLE, "group": "example.com"}])), 1)

    def test_entry_without_name_needs_group_and_kind(self):
        self.assertEqual(run([{"group": "admissionregistration.k8s.io", "kind": "ValidatingWebhookConfiguration"}]), [])
        self.assertEqual(len(run([{"group": "admissionregistration.k8s.io", "kind": "MutatingWebhookConfiguration"}])), 1)

    def test_rules_on_aggregated_role_passes(self):
        self.assertEqual(run([{**ROLE, "jsonPointers": ["/rules"]}]), [])

    def test_rules_on_fixed_role_fails(self):
        errors = run([{**ROLE, "name": "fixed-role", "jsonPointers": ["/rules"]}])
        self.assertEqual(len(errors), 1)
        self.assertIn("no aggregationRule", errors[0])

    def test_non_rules_pointer_on_fixed_role_passes(self):
        self.assertEqual(run([{**ROLE, "name": "fixed-role", "jsonPointers": ["/metadata/labels"]}]), [])

    def test_namespace_mismatch_fails_and_unset_namespace_passes(self):
        built = "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c, namespace: other}\n"
        errors = []
        kc.check_ignore_differences("w", built, [{"kind": "ConfigMap", "name": "c", "namespace": "kubeflow"}], errors)
        self.assertEqual(len(errors), 1)
        errors = []
        kc.check_ignore_differences("w", "apiVersion: v1\nkind: ConfigMap\nmetadata: {name: c}\n",
                                    [{"kind": "ConfigMap", "name": "c", "namespace": "kubeflow"}], errors)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()


class ExternalDb(unittest.TestCase):
    CLEAN = """
apiVersion: apps/v1
kind: Deployment
metadata: {name: cache-server}
spec: {template: {spec: {containers: [{name: server, env: [{name: DBCONFIG_USER, valueFrom: {secretKeyRef: {name: kfp-db, key: username}}}]}]}}}
"""

    def test_clean_build_passes(self):
        errors = []
        kc.check_external_db("pipelines", self.CLEAN, errors)
        self.assertEqual(errors, [])

    def test_bundled_object_left_fails(self):
        errors = []
        kc.check_external_db("pipelines", self.CLEAN + "---\napiVersion: v1\nkind: Service\nmetadata: {name: mysql}\n", errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("Service/mysql", errors[0])

    def test_new_consumer_of_mysql_secret_fails(self):
        errors = []
        kc.check_external_db("pipelines", self.CLEAN.replace("kfp-db", "mysql-secret"), errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("still reads mysql-secret", errors[0])

    def test_only_with_the_external_patch(self):
        self.assertTrue(kc.external_db([{"target": {"name": "pipeline-install-config"}}]))
        self.assertFalse(kc.external_db([{"target": {"name": "ml-pipeline"}}, {"patch": "x"}]))
