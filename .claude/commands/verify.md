---
description: Run all local gates and summarise the results
---
Run `make verify`. If the change touches modules, auth, profiles or the upstream ref, also run `make e2e MODULES=core`.

Report a table: gate → pass/fail → a one-line cause for each failure. For each failure, say whether it's in this change or something that was already broken. Don't fix anything unless asked.
