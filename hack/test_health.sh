#!/usr/bin/env bash
# Check the argocd-cm health scripts offline against tests/health/*.yaml.
# Each fixture's first line is `# expected: <Healthy|Progressing|Degraded|Suspended|Missing|Unknown>`.
# Needs the argocd CLI at the version pinned for CI (ARGOCD env var, else `argocd` on PATH, else .cache/bin/argocd).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CM="$ROOT/hack/argocd/argocd-cm-health.yaml"
ARGOCD="${ARGOCD:-$(command -v argocd || echo "$ROOT/.cache/bin/argocd")}"
[[ -x "$ARGOCD" ]] || { echo "argocd CLI not found; set ARGOCD=/path/to/argocd (see docs/argocd.md)"; exit 1; }

fail=0 n=0
for f in "$ROOT"/tests/health/*.yaml; do
  want="$(sed -n '1s/^# expected: *//p' "$f")"
  [[ -n "$want" ]] || { echo "FAIL $(basename "$f"): missing '# expected:' first line"; fail=1; continue; }
  got="$(KUBECONFIG=/dev/null "$ARGOCD" admin settings resource-overrides health "$f" --argocd-cm-path "$CM" 2>/dev/null \
    | sed -n 's/^STATUS: *//p')"
  n=$((n + 1))
  if [[ "$got" == "$want" ]]; then
    echo "ok   $(basename "$f"): $got"
  else
    echo "FAIL $(basename "$f"): want $want, got ${got:-<nothing>}"; fail=1
  fi
done
echo "health-check: $n fixture(s), $([[ $fail == 0 ]] && echo 'all passed' || echo 'FAILURES')"
exit $fail
