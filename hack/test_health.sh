#!/usr/bin/env bash
# Check the argocd-cm health scripts offline against tests/health/*.yaml.
# Each fixture's first line is `# expected: <Healthy|Progressing|Degraded|Suspended|Missing|Unknown>`.
# Needs the argocd CLI v3.6.2, the ARGOCD_VERSION pin in hack/kind-up.sh (ARGOCD env var, else `argocd` on PATH,
# else .cache/bin/argocd). See CONTRIBUTING.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CM="$ROOT/hack/argocd/argocd-cm-health.yaml"
ARGOCD="${ARGOCD:-$(command -v argocd || echo "$ROOT/.cache/bin/argocd")}"
[[ -x "$ARGOCD" ]] || { echo "argocd CLI v3.6.2 not found; see CONTRIBUTING.md"; exit 1; }

err="$(mktemp)"; out="$(mktemp)"
trap 'rm -f "$err" "$out"' EXIT
show_err() { grep -v '"level":"info"' "$err" | sed 's/^/     /' || true; }

fail=0 n=0
for f in "$ROOT"/tests/health/*.yaml; do
  want="$(sed -n '1s/^# expected: *//p' "$f")"
  [[ -n "$want" ]] || { echo "FAIL $(basename "$f"): missing '# expected:' first line"; fail=1; continue; }
  : >"$err"
  rc=0
  KUBECONFIG=/dev/null "$ARGOCD" admin settings resource-overrides health "$f" --argocd-cm-path "$CM" >"$out" 2>"$err" || rc=$?
  got="$(sed -n 's/^STATUS: *//p' "$out")"
  n=$((n + 1))
  if (( rc != 0 )); then
    # A non-zero exit fails the fixture even when a STATUS line matches.
    echo "FAIL $(basename "$f"): argocd exited $rc"; fail=1; show_err
  elif [[ "$got" == "$want" ]]; then
    echo "ok   $(basename "$f"): $got"
  else
    echo "FAIL $(basename "$f"): want $want, got ${got:-<nothing>}"; fail=1
    # Show the CLI's own errors (for example a Lua error), without its info-level log lines.
    show_err
  fi
done
echo "health-check: $n fixture(s), $([[ $fail == 0 ]] && echo 'all passed' || echo 'FAILURES')"
exit $fail
