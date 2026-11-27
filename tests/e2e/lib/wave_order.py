#!/usr/bin/env python3
# Reads `kubectl get applications.argoproj.io -o json` on stdin. Prints a table of sync waves and deploy times,
# then exits 1 if any Application in a higher wave started its first deploy before every
# Application in a lower wave had finished its first deploy (#22).
# The first deploy is the history entry with the lowest id, so a later self-heal sync cannot
# cause a false failure. History order in ArgoCD is not relied on.
import json
import sys
from datetime import datetime


def ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def fmt(t):
    return t.strftime("%H:%M:%S") if t else "-"


rows = []
for app in json.load(sys.stdin)["items"]:
    ann = app["metadata"].get("annotations") or {}
    hist = app.get("status", {}).get("history") or []
    first = min(hist, key=lambda h: h.get("id", 0)) if hist else {}
    rows.append({
        "app": app["metadata"]["name"],
        "wave": int(ann.get("argocd.argoproj.io/sync-wave", "0")),
        "start": ts(first.get("deployStartedAt")),
        "end": ts(first.get("deployedAt")),
    })
rows.sort(key=lambda r: (r["wave"], r["app"]))

print(f"{'wave':>5}  {'application':<28} {'deploy started':<15} {'deployed':<15}")
for r in rows:
    print(f"{r['wave']:>5}  {r['app']:<28} {fmt(r['start']):<15} {fmt(r['end']):<15}")

bad = []
for a in rows:
    for b in rows:
        if a["wave"] >= b["wave"]:
            continue
        if not a["end"] or not b["start"]:
            bad.append(f"no deploy history for {a['app']} or {b['app']}")
        elif b["start"] < a["end"]:
            bad.append(f"{b['app']} (wave {b['wave']}) started before {a['app']} (wave {a['wave']}) finished")
for m in bad:
    print("ORDER FAIL:", m)
sys.exit(1 if bad else 0)
