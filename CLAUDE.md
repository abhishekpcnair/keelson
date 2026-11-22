# CLAUDE.md: project contract for Claude Code sessions

Keelson is a GitOps-first Kubeflow distribution: one Helm chart that renders ArgoCD Applications pointing at **pinned upstream** Kubeflow manifests. Read `docs/design/0001-architecture.md` before any change, and follow `docs/development-factory.md` for process.

## Hard rules (never break these)
1. **Wrap, don't copy.** Never vendor or re-template upstream manifests into this repo. Workloads come only from `github.com/kubeflow/manifests` at a pinned tag, or from upstream Helm charts at pinned versions.
2. **No forked images.** Never change an image to a non-upstream registry or repository.
3. **Pin everything.** No `HEAD`, `master`, `main` or `latest` in any source or image reference.
4. **Every patch starts with a header**: `# purpose:`, `# upstream:` (issue link or `none`), `# remove-when:`.
5. **One issue per PR.** Don't fix unrelated things while you're there. Open an issue instead.
6. **No inline secrets** in values or templates. Use `secretRef` only.
7. Don't implement anything without an issue labelled `plan-approved`.

## Layout
- `charts/keelson/`: the chart (`values.yaml`, `values.schema.json`, `modules/*.yaml` registry, `templates/`)
- `templates/_translate_*.tpl`: intent → patches (the only real logic, so test it)
- `tests/golden/<scenario>/values.yaml` + `expected.yaml`: render snapshots
- `tests/e2e/`: Kind + ArgoCD smoke tests
- `hack/check_rules.py`: machine-checks the hard rules
- `docs/`: design, ADRs, factory, user docs
- `.cache/upstream/<tag>/`: local upstream checkout (gitignored). Search it with grep; never paste it into chat.

## Commands
- `make verify`: lint, schema, golden diff, kubeconform, rules (must pass before any PR)
- `make golden`: regenerate golden snapshots (review the diff; never regenerate blindly to make a test pass)
- `make e2e [MODULES=core]`: Kind + ArgoCD + smoke tests
- `make upstream-cache TAG=26.10.0`: fetch upstream manifests into `.cache/upstream/`

## Upstream facts (verify against `.cache/upstream/<tag>`; paths move between releases)
- Current target: Kubeflow Community Distribution `26.10.0`
- The upstream Helm charts in `applications/*/helm` and `common/*/helm` are **drafts** generated from Kustomize. Don't switch a module to them without an ADR.

## Style
- Helm templates: `include` helpers, `nindent`, no logic in module YAML files.
- Commits: conventional (`feat:`, `fix:`, `chore(upstream):`, `docs:`), signed off with `git commit -s` (DCO). Don't add a `Co-Authored-By: Claude` trailer to every commit; this is an open-source repo and plain commits are preferred.
- Open source: Apache-2.0. Attribute any borrowed code in `NOTICE` and the file header. Never commit personal emails, tokens or internal hostnames.
- Docs: plain English, short sentences, one example per concept.

## Lessons (add one when a mistake repeats)
- _(empty)_
