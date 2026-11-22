---
description: Implement an approved plan on a new branch and open a PR
argument-hint: <issue-number>
---
Implement issue #$ARGUMENTS.

1. Check that the issue has the `plan-approved` label (`gh issue view $ARGUMENTS --json labels`). If it doesn't, stop and say so.
2. Read the approved plan comment. Follow it. If you need to deviate, stop and explain why, rather than improvising.
3. Create a branch `<type>/$ARGUMENTS-<slug>` from an up-to-date `main`.
4. Make the change, following every hard rule in `CLAUDE.md`. Include: the schema update, the golden scenario (`make golden`, then read the diff and confirm it matches the plan), docs, and `changes/$ARGUMENTS.md`.
5. Run `make verify`. Fix failures properly; never edit expected output just to make a test pass.
6. If the plan says `needs-e2e`, run `make e2e` (or note in the PR that it must run in CI).
7. Commit with conventional commits, push, and open the PR with `gh pr create`, filling in `.github/pull_request_template.md`. Link it with "Closes #$ARGUMENTS".
8. Say in one line that the next step is `/review <pr>` in a **new session**.
