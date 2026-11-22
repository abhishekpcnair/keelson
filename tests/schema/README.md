# Schema tests

`make schema` renders the chart with each `reject/*.yaml` file. Each render must **fail**.

To add a case:
1. Make `reject/<name>.yaml` with the bad values.
2. Add one `# expect: <text>` line. The first `# expect:` line in the file is used.
3. Put the exact error reason in `<text>`. Example: `# expect: additional properties 'platfrom' not allowed`.
