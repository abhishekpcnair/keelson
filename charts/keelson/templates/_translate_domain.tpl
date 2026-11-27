{{/*
Translation: `domain` + `tls` (design 0001 §5.2). Turns intent into inline
Kustomize patches. The Dex issuer stays the upstream in-cluster URL (#5).
*/}}

{{/*
keelson.domain.url: the external base URL, `https://<domain>`, or `http://`
when tls.issuer is none. Empty when domain is empty. Shared with #6.
*/}}
{{- define "keelson.domain.url" -}}
{{- with .Values.domain -}}
{{- printf "%s://%s" (ternary "http" "https" (eq (($.Values.tls).issuer | default "none") "none")) . -}}
{{- end -}}
{{- end -}}

{{/*
keelson.tls.issued: the tls.issuer values for which the keelson-tls component
(#23, ADR 0004) issues the certificate into the Secret keelson-tls.
*/}}
{{- define "keelson.tls.issued" -}}
{{- toYaml (list "selfsigned" "letsencrypt") -}}
{{- end -}}

{{/*
keelson.translate.domain: patches for one module. Call with (dict "root" $
"module" $m). Returns YAML `{patches: [...], skip: bool}`; no patches when
domain is empty. skip is true only for keelson-tls when there is nothing to issue.
*/}}
{{- define "keelson.translate.domain" -}}
{{- $v := .root.Values -}}
{{- $issuer := ($v.tls).issuer | default "none" -}}
{{- $issued := has $issuer (include "keelson.tls.issued" . | fromYamlArray) -}}
{{- $patches := list -}}
{{- $skip := false -}}
{{- if eq .module.name "keelson-tls" -}}
{{- /* A component, not a Kustomize module: no patches. No Application without a certificate to issue. */ -}}
{{- $skip = not (and $v.domain $issued) -}}
{{- else if $v.domain -}}
{{- if eq .module.name "kubeflow-istio-resources" -}}
{{- $p := "" -}}
{{- if eq $issuer "existing" -}}
{{- $p = include "keelson.translate.domain.gatewayTLS" (dict "domain" $v.domain "secret" $v.tls.secretRef.name "issuer" $issuer) -}}
{{- else if $issued -}}
{{- /* Without keelson-tls the Gateway would point at a Secret that nothing issues. */ -}}
{{- $tlsMod := get ($v.modules | default dict) "keelson-tls" | default dict -}}
{{- if and (hasKey $tlsMod "enabled") (not $tlsMod.enabled) -}}
{{- fail (printf "tls.issuer=%s needs module keelson-tls; use tls.issuer=existing to bring your own Secret" $issuer) -}}
{{- end -}}
{{- $p = include "keelson.translate.domain.gatewayTLS" (dict "domain" $v.domain "secret" "keelson-tls" "issuer" $issuer) -}}
{{- else -}}
{{- $p = include "keelson.translate.domain.gatewayHosts" (dict "domain" $v.domain) -}}
{{- end -}}
{{- $patches = append $patches (dict "patch" $p "target" (dict "group" "networking.istio.io" "version" "v1alpha3" "kind" "Gateway" "name" "kubeflow-gateway")) -}}
{{- else if and (eq .module.name "oauth2-proxy") (ne $issuer "none") -}}
{{- $patches = append $patches (dict "patch" (include "keelson.translate.domain.forceHttps" (dict "issued" $issued)) "target" (dict "version" "v1" "kind" "ConfigMap" "name" "oauth2-proxy-parameters")) -}}
{{- end -}}
{{- end -}}
{{- dict "patches" $patches "skip" $skip | toYaml -}}
{{- end -}}

{{- define "keelson.translate.domain.gatewayHosts" -}}
# purpose: serve the Kubeflow Gateway only on `domain`
# upstream: none
# remove-when: never (Keelson intent: domain)
- op: replace
  path: /spec/servers/0/hosts
  value:
    - {{ .domain | quote }}
{{- end -}}

{{- define "keelson.translate.domain.gatewayTLS" -}}
# purpose: serve `domain` over HTTPS with {{ ternary "the user's TLS Secret" "the keelson-tls certificate" (eq .issuer "existing") }}, redirect HTTP
# upstream: none
# remove-when: never (Keelson intent: tls.issuer={{ .issuer }})
- op: replace
  path: /spec/servers
  value:
    - port: { number: 80, name: http, protocol: HTTP }
      hosts:
        - {{ .domain | quote }}
      tls:
        httpsRedirect: true
    - port: { number: 443, name: https, protocol: HTTPS }
      hosts:
        - {{ .domain | quote }}
      tls:
        mode: SIMPLE
        credentialName: {{ .secret | quote }}
{{- end -}}

{{- define "keelson.translate.domain.forceHttps" -}}
# purpose: secure cookies when users reach Kubeflow over HTTPS
# upstream: none
# remove-when: never (Keelson intent: tls.issuer={{ ternary "selfsigned|letsencrypt" "existing|external" .issued }})
- op: replace
  path: /data/FORCE_HTTPS
  value: "true"
{{- end -}}
