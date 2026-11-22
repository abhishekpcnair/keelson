---
description: Independent review of a PR by the reviewer subagent
argument-hint: <pr-number>
---
Use the `reviewer` subagent to review PR #$ARGUMENTS. Give it only the PR number. Don't pass on your own opinion of the change.

When it returns, post its findings as one PR comment with `gh pr comment $ARGUMENTS`, grouped as **Blocking / Should fix / Nits**. Don't fix anything in this session.
