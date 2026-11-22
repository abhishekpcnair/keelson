---
description: Triage a GitHub issue against the design doc
argument-hint: <issue-number>
---
Triage issue #$ARGUMENTS.

1. Read the issue with `gh issue view $ARGUMENTS --comments`.
2. Read `docs/design/0001-architecture.md` sections 3 (goals and non-goals) and 4 (principles).
3. Decide:
   - type: feature | bug | upstream-bump | docs
   - module(s) affected
   - size: S (<1h), M (an evening), L (a weekend; propose a split if bigger)
   - milestone: which roadmap version (§16)
   - conflicts with any principle? If yes → `needs-adr`, and explain why.
4. Apply labels with `gh issue edit` and post a short triage comment (5 lines at most).
Don't plan or implement anything.
