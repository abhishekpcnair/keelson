PROJECT_NAME ?= keelson
CHART        := charts/$(PROJECT_NAME)
GOLDEN_DIR   := tests/golden
RENDER_DIR   := .cache/render
TAG          ?= $(shell python3 -c "import yaml;print(yaml.safe_load(open('$(CHART)/values.yaml'))['upstream']['manifestsRef'])")
MODULES      ?= all
KUBECONFORM_SCHEMAS := -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

.PHONY: help verify lint schema golden golden-check kubeconform rules kustomize-check namespaces health-check e2e kind-up kind-down upstream-cache upstream-watch clean

help: ## Show targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

verify: lint schema golden-check kubeconform rules kustomize-check namespaces health-check ## All local gates (required before a PR)

lint: ## helm lint
	helm lint $(CHART)

# Each tests/schema/reject/<name>.yaml must fail to render, with its "# expect: <text>" in the error.
schema: ## Check that the schema rejects bad values
	@fail=0; for f in tests/schema/reject/*.yaml; do \
	  want=$$(sed -n 's/^# expect: //p' $$f | head -n1); \
	  if [ -z "$$want" ]; then echo "schema: $$f has no '# expect:' line"; fail=1; \
	  elif out=$$(helm template keelson $(CHART) -f $$f 2>&1); then echo "schema: $$f rendered but should fail"; fail=1; \
	  elif echo "$$out" | grep -qF -- "$$want"; then echo "schema: $$f rejected"; \
	  else echo "schema: $$f failed without '$$want':"; echo "$$out"; fail=1; fi; \
	done; exit $$fail

# Each scenario: tests/golden/<name>/values.yaml → expected.yaml
golden: ## Regenerate golden snapshots (review the diff!)
	@for d in $(GOLDEN_DIR)/*/; do [ -f $$d/values.yaml ] || continue; \
	  echo "render $$d"; helm template keelson $(CHART) -f $$d/values.yaml > $$d/expected.yaml; done

golden-check: ## Fail if rendered output differs from snapshots
	@mkdir -p $(RENDER_DIR); fail=0; \
	for d in $(GOLDEN_DIR)/*/; do [ -f $$d/values.yaml ] || continue; n=$$(basename $$d); \
	  helm template keelson $(CHART) -f $$d/values.yaml > $(RENDER_DIR)/$$n.yaml || fail=1; \
	  diff -u $$d/expected.yaml $(RENDER_DIR)/$$n.yaml || { echo "golden mismatch: $$n (run 'make golden' and review)"; fail=1; }; \
	done; exit $$fail

kubeconform: ## Validate rendered manifests
	@ls $(RENDER_DIR)/*.yaml >/dev/null 2>&1 || { echo "no rendered scenarios yet"; exit 0; }; \
	kubeconform -strict -summary $(KUBECONFORM_SCHEMAS) $(RENDER_DIR)/*.yaml

rules: ## Check design rules on rendered output and patches
	python3 -m unittest hack/test_check_rules.py
	python3 hack/check_rules.py --rendered $(RENDER_DIR) --patches $(CHART)/patches --repo .

namespaces: upstream-cache ## Check module namespaces: lists against upstream kubectl kustomize output
	python3 -m unittest hack/test_check_namespaces.py
	python3 hack/check_namespaces.py

kustomize-check: upstream-cache ## Build patched modules against .cache/upstream (needs pinned kustomize)
	python3 hack/kustomize_check.py --rendered $(RENDER_DIR)

health-check: ## Test the argocd-cm health scripts offline against tests/health fixtures
	hack/test_health.sh

e2e: ## Kind + ArgoCD + smoke tests (MODULES=core|all)
	tests/e2e/run.sh $(MODULES)

kind-up: upstream-cache ## Create Kind cluster 'keelson' (upstream CI shape) and install pinned ArgoCD
	UPSTREAM_TAG=$(TAG) hack/kind-up.sh

kind-down: ## Delete Kind cluster 'keelson'
	hack/kind-down.sh

upstream-cache: ## Shallow-clone kubeflow/manifests at TAG into .cache/upstream/TAG
	@test -d .cache/upstream/$(TAG) || git clone -q --depth 1 --branch $(TAG) https://github.com/kubeflow/manifests.git .cache/upstream/$(TAG)
	@echo ".cache/upstream/$(TAG)"

upstream-watch: ## Is there a newer upstream release?
	python3 hack/upstream_watch.py

clean:
	rm -rf $(RENDER_DIR)
