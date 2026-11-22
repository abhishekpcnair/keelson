---
description: Write an implementation plan for an issue and post it for approval
argument-hint: <issue-number>
---
Write an implementation plan for issue #$ARGUMENTS. Don't change any files.

Read: the issue, `CLAUDE.md`, the design doc, and the relevant `charts/keelson/modules/*.yaml`. If upstream is involved, grep `.cache/upstream/<tag>` (run `make upstream-cache` if it's missing).

Post the plan as an issue comment (`gh issue comment`), in exactly these sections:
- **Goal**: one sentence
- **Files to change**: path → what changes
- **Values / schema changes**: new keys, defaults, validation
- **Translation changes**: which `_translate_*.tpl` helpers change
- **Golden scenarios**: which are added or updated, and the expected diff in words
- **Tests**: golden, rules, e2e smoke (and whether `needs-e2e` applies)
- **Docs**: pages to add or update
- **Risks / open questions**
- **Size check**: estimated changed lines (excluding golden output). If over 400, propose a split.

End with: "Awaiting `plan-approved`."
