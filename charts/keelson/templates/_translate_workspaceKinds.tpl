{{/*
Translation: `workspaces.kinds` (#14). The workspace-kinds module wraps upstream's
applications/workspaces/upstream/controller/samples, which has no installable
overlay. These delete patches keep only the selected WorkspaceKinds.
*/}}

{{/* Sample objects in that path that are never part of an install: [apiVersion, kind, name]. */}}
{{- define "keelson.workspaceKinds.sampleObjects" -}}
- [v1, PersistentVolumeClaim, workspace-home-pvc]
- [v1, PersistentVolumeClaim, workspace-data-pvc]
- [v1, Secret, workspace-secret]
- [v1, ConfigMap, workspacekind-image-source]
- [kubeflow.org/v1beta1, Workspace, jupyterlab-workspace]
{{- end -}}

{{/* The WorkspaceKinds that path ships. values.schema.json enumerates the same names. */}}
{{- define "keelson.workspaceKinds.all" -}}
- codeserver
- jupyterlab
- rstudio
{{- end -}}

{{/*
keelson.translate.workspaceKinds: delete patches for one module. Call with
(dict "root" $ "module" $m). Returns YAML `{patches: [...]}`, or `{skip: true}`
when workspaces.kinds is empty, so the engine renders no Application.
*/}}
{{- define "keelson.translate.workspaceKinds" -}}
{{- $kinds := ((.root.Values.workspaces).kinds) | default list -}}
{{- if not $kinds -}}
{{- dict "skip" true | toYaml -}}
{{- else -}}
{{- $del := include "keelson.workspaceKinds.sampleObjects" . | fromYamlArray -}}
{{- range $k := include "keelson.workspaceKinds.all" . | fromYamlArray -}}
{{- if not (has $k $kinds) -}}{{- $del = append $del (list "kubeflow.org/v1beta1" "WorkspaceKind" $k) -}}{{- end -}}
{{- end -}}
{{- $patches := list -}}
{{- range $del -}}
{{- $gv := splitList "/" (index . 0) -}}
{{- $target := dict "version" (last $gv) "kind" (index . 1) "name" (index . 2) -}}
{{- if gt (len $gv) 1 -}}{{- $_ := set $target "group" (first $gv) -}}{{- end -}}
{{- $patches = append $patches (dict "target" $target "patch" (include "keelson.translate.workspaceKinds.delete" .)) -}}
{{- end -}}
{{- dict "patches" $patches | toYaml -}}
{{- end -}}
{{- end -}}

{{- define "keelson.translate.workspaceKinds.delete" -}}
# purpose: drop upstream sample {{ index . 1 }}/{{ index . 2 }}; it is not part of a Keelson install
# upstream: none
# remove-when: upstream ships an installable WorkspaceKinds overlay (then point workspace-kinds at it)
$patch: delete
apiVersion: {{ index . 0 }}
kind: {{ index . 1 }}
metadata:
  name: {{ index . 2 }}
{{- end -}}
