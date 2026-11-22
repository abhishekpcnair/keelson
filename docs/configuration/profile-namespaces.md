# Profile namespaces: Pod Security and labels

## Pod Security
Every profile namespace enforces the Kubernetes **baseline** Pod Security Standard.
- Upstream sets it. The dashboard module's profile controller adds `pod-security.kubernetes.io/enforce: baseline` to every profile namespace.
- Kubernetes Pod Security Admission enforces it. Keelson adds no policy engine for this.
- You can't lower it through values. `profileNamespaceLabels` rejects every `pod-security.kubernetes.io/` key, because a lower level is a silent security change.

## Add labels
```yaml
profileNamespaceLabels:
  cost-center: ml
  example.com/team: vision
```
- The profile controller adds these labels to every profile namespace, next to upstream's labels.
- Keys and values use Kubernetes label syntax.
- Upstream's label keys can't be set here: `app.kubernetes.io/part-of`, `katib.kubeflow.org/metrics-collector-injection`, `pipelines.kubeflow.org/enabled`, `serving.kubeflow.org/inferenceservice`, `pod-security.kubernetes.io/enforce`.

## Change or remove a label
The profile controller adds a label only when the namespace doesn't have it. It never changes an existing value, and it doesn't remove a label whose key you delete.
These rules are upstream's own. They are in the header of `namespace-labels-kubeflow-pss.yaml` at `26.10.0` (lines 4 and 5: add with `key: "value"`, remove with `key: ""`; line 8: "The controller will NOT overwrite a label if one with same key already exists"; lines 9 to 13: remove the label, apply, add it again, apply).
- **To remove a label:** set its value to `""`. The controller removes it.
- **To change a value:**
  1. Set the value to `""` and sync.
  2. Set the new value and sync.

## How it works
The profile controller reads its labels from the ConfigMap `profiles-namespace-labels-data`. Keelson replaces that file with upstream's labels plus yours. `make verify` fails if Keelson's copy of upstream's labels drifts from the pinned tag.
