PROJECT_NAME ?= keelson
CHART        := charts/$(PROJECT_NAME)
GOLDEN_DIR   := tests/golden
RENDER_DIR   := .cache/render
TAG          ?= $(shell python3 -c "import yaml;print(yaml.safe_load(open('$(CHART)/values.yaml'))['upstream']['manifestsRef'])")
MODULES      ?= all
KUBECONFORM_SCHEMAS := -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

.PHONY: help verify lint schema golden golden-check kubeconform rules kustomize-check e2e kind-up kind-down upstream-cache upstream-watch clean

help: ## Show targets
	@grep -E '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

verify: lint golden-check kubeconform rules kustomize-check ## All local gates (required before a PR)

lint: ## helm lint
	helm lint $(CHART)

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

kustomize-check: upstream-cache ## Build patched modules against .cache/upstream (needs pinned kustomize)
	python3 hack/kustomize_check.py --rendered $(RENDER_DIR)

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
