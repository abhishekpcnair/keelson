# Development factory

This is how work moves from an idea to a release in this repo. Two kinds of worker take part: **the maintainer**, who owns decisions and approvals, and **Claude Code sessions**, which do the building. Every stage has a slash command, an output, and a gate it has to pass.

```
 intake ─▶ triage ─▶ plan ─▶ [approve] ─▶ implement ─▶ verify ─▶ review ─▶ [approve] ─▶ merge ─▶ release
   ▲                                                                                         │
   └──────────── upstream-watch (weekly bot) ◀── learn (CLAUDE.md lessons, ADRs) ◀───────────┘
```

## Roles

| Role | Who | Owns |
|---|---|---|
| Maintainer | Abhishek | Scope, approving plans, final review, releases |
| Builder | A Claude Code session | Plans, code, tests, docs, PR description |
| Reviewer | The `reviewer` subagent (fresh context) | An independent check against the design rules and the PR checklist |
| Scout | The `upstream-scout` subagent | Reading upstream changes and summarising their impact |
| Gatekeeper | GitHub Actions | Lint, schema, golden, rules, e2e |
| Intake bot | `upstream-watch.yaml` | Opening `upstream-bump` issues |

## Stages

### 0. Intake
- Every piece of work starts as a GitHub issue, opened from a template: `feature`, `bug` or `upstream-bump`.
- `upstream-watch.yaml` opens `upstream-bump` issues automatically when `kubeflow/manifests` gets a new release tag.

### 1. Triage: `/triage <issue>`
- Classifies the issue (`type/*`, `module/*`, `size/S|M|L`), checks it against the goals and non-goals in the design doc, and proposes a milestone.
- **Gate:** an issue that conflicts with the design principles is labelled `needs-adr` and goes no further until an ADR has been accepted.

### 2. Plan: `/plan <issue>`
- The builder posts a plan as an issue comment, following `.claude/commands/plan.md`: files touched, values/schema changes, translation changes, golden scenarios affected, tests, docs, and risks.
- **Gate (human):** the maintainer adds the `plan-approved` label. No implementation starts without it.

### 3. Implement: `/implement <issue>`
- Branch: `<type>/<issue>-<slug>` (e.g. `feat/12-dex-entra-connector`).
- Rules: one issue per PR, roughly 400 changed lines at most (rendered golden output doesn't count), conventional commits.
- The change must include: code, a schema update, a golden scenario or an update to one, docs, and a `changes/<issue>.md` fragment.

### 4. Verify: `/verify`
- Runs `make verify`: `lint` (`helm lint`), `schema` (reject cases), `golden-check` (the golden diff), `kubeconform`, `rules` (`hack/check_rules.py`), `kustomize-check`, `namespaces` (`hack/check_namespaces.py`) and `health-check`.
- Optionally runs `make e2e`: Kind plus ArgoCD sync plus smoke tests. This is required for module, auth or upstream-bump changes.
- **Gate:** every check is green locally before a PR is opened.

### 5. Review
- The `reviewer` subagent reviews the diff in a **fresh context** (it never sees the builder's reasoning) against `.claude/agents/reviewer.md`. Its findings go into the PR as a comment.
- CI must pass: the `verify` job is required; `e2e` is required on PRs labelled `needs-e2e`.
- **Gate (human):** the maintainer approves.

### 6. Merge
- Squash-merge. The PR title becomes the commit message (conventional commit).

### 7. Release: `/release <version>`
- Collects the `changes/*.md` fragments into `CHANGELOG.md`, bumps `Chart.yaml` (`version`, and `appVersion` if upstream changed), and tags `v<version>`.
- `release.yaml` packages the chart, pushes it to GHCR as OCI, signs it with cosign and creates the GitHub release.
- **Gate (human):** the AKS manual checklist (`docs/release-checklist.md`) has been completed for minor releases.

### 8. Learn
- When a reviewer finding or a CI failure happens twice, add a rule to `CLAUDE.md` → "Lessons", or a check to `hack/check_rules.py`.
- Decisions that bend a design principle become ADRs in `docs/adr/`.

## The upstream-bump loop (the reason this project exists)

1. The weekly bot finds a new `kubeflow/manifests` tag and opens an `upstream-bump` issue with the component table and the changed `example/kustomization.yaml` entries.
2. `/upstream-bump <tag>`:
   - The `upstream-scout` subagent reads the upstream release notes and the diff and produces an impact summary (renamed paths, removed overlays, new components, newly available upstream Helm charts).
   - The builder bumps `upstream.manifestsRef` and fixes module paths, then re-renders the golden scenarios and checks every patch (reapply, rewrite, or delete if it was fixed upstream).
   - Runs `make e2e`.
3. A PR is opened with the impact summary, the golden diff and the e2e result.
4. **Target:** merged and released within four weeks of the upstream release.

## WIP limits and cadence
- At most **one feature PR and one bump PR** in flight at a time.
- Suggested cadence: a weekend block for implement/verify; weeknights for triage, plan and review.
- Releases: a patch release whenever needed; a minor release per upstream release or per roadmap milestone.

## Using Claude Code well (Max plan)
- **One stage per session.** Start a new session (or `/clear`) between plan, implement and review, so each stage has a clean context and the reviewer stays independent.
- Upstream checkouts live in `.cache/upstream/<tag>` (gitignored, `make upstream-cache`). Search them with grep; don't paste them into the conversation.
- `CLAUDE.md` is the contract. Keep it short and current.
- Running Kind locally takes about 16 GB of RAM for a full install. Use `make e2e MODULES=core` to test a subset.

## Labels
`type/feature` `type/bug` `type/upstream-bump` `type/docs` · `module/<name>` · `size/S|M|L` · `plan-approved` · `needs-adr` · `needs-e2e` · `good-first-issue`

## Definition of done
- [ ] Linked issue with an approved plan
- [ ] `make verify` green; e2e green if required
- [ ] Schema, golden scenario, docs and change fragment updated
- [ ] Values reference regenerated (`make values-ref`) after any schema change
- [ ] Reviewer subagent findings addressed or answered
- [ ] No unpinned sources, no copied upstream templates, no forked images
- [ ] Maintainer approved
