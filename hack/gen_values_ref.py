#!/usr/bin/env python3
"""Generate docs/reference/values.md from charts/keelson/values.schema.json.

Usage:
  hack/gen_values_ref.py --write   write docs/reference/values.md
  hack/gen_values_ref.py --check   fail if the file on disk is stale

The script fails when:
  - a property has no `description`;
  - the schema uses a keyword the script does not know (extend CONTEXTS when the schema needs it);
  - a `$ref` is not a local `#/$defs/<name>` reference.
Standard library only. The output is sorted, so it is the same on each run.
"""
import argparse
import difflib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "charts/keelson/values.schema.json"
OUT = ROOT / "docs/reference/values.md"
# Keywords per schema context. Nodes nested in anyOf, not, propertyNames and if/then are
# rendered by allowed() and facts() only for the keywords below. Any other keyword there would
# be dropped from the doc without a message, so validate() rejects it.
ANNOTATIONS = {"$schema", "$comment"}
CONTEXTS = {
    "schema": {
        "$defs", "$ref", "type", "properties", "additionalProperties", "required", "items", "enum", "const",
        "default", "description", "format", "pattern", "minLength", "maxLength", "minItems", "allOf",
        "anyOf", "not", "propertyNames",
    },
    "branch": {"type", "enum", "const", "maxLength", "minLength", "minItems", "format", "pattern", "not", "propertyNames", "anyOf"},
    "not": {"pattern"},
    "pnames": {"pattern", "not"},
    "pnames_not": {"pattern", "enum"},
    "fact": {"required", "const", "minLength", "minItems", "propertyNames", "properties"},
    "fact_pnames": {"not"},
    "fact_pnames_not": {"enum"},
}


def fail(msg):
    sys.exit(f"gen_values_ref: {msg}")


def validate(node, where, ctx="schema"):
    """Fail on a keyword that the generator does not render, in the whole schema tree."""
    if not isinstance(node, dict):
        fail(f"{where}: expected a schema object")
    for k in node:
        if k not in CONTEXTS[ctx] and k not in ANNOTATIONS:
            fail(f"{where}: unknown keyword '{k}' in {ctx} context (extend hack/gen_values_ref.py)")
    sub = lambda name, child, c: validate(child, f"{where}.{name}", c)  # noqa: E731
    if ctx == "schema":
        for n, d in node.get("$defs", {}).items():
            sub(f"$defs.{n}", d, "schema")
        for n, p in node.get("properties", {}).items():
            sub(n, p, "schema")
        for key in ("items", "additionalProperties"):
            if isinstance(node.get(key), dict):
                sub(key, node[key], "schema")
        for i, b in enumerate(node.get("allOf", [])):
            if not isinstance(b, dict) or set(b) - {"if", "then", "$comment"} or not {"if", "then"} <= set(b):
                fail(f"{where}.allOf[{i}]: only if/then branches are supported")
            sub(f"allOf[{i}].if", b["if"], "fact")
            sub(f"allOf[{i}].then", b["then"], "fact")
        for i, b in enumerate(node.get("anyOf", [])):
            sub(f"anyOf[{i}]", b, "branch")
    elif ctx == "branch":
        for i, b in enumerate(node.get("anyOf", [])):
            sub(f"anyOf[{i}]", b, "branch")
    elif ctx == "fact":
        for n, p in node.get("properties", {}).items():
            sub(n, p, "fact")
    if "not" in node and ctx in ("schema", "branch"):
        sub("not", node["not"], "not")
    if "propertyNames" in node:
        pn_ctx = "fact_pnames" if ctx == "fact" else "pnames"
        sub("propertyNames", node["propertyNames"], pn_ctx)
    if ctx in ("pnames", "fact_pnames") and "not" in node:
        sub("not", node["not"], ctx + "_not")


def resolve(schema, node, where):
    """Follow a local $ref. Return the target schema."""
    seen = 0
    while isinstance(node, dict) and "$ref" in node:
        ref = node["$ref"]
        if not ref.startswith("#/$defs/") or ref[8:] not in schema.get("$defs", {}):
            fail(f"{where}: unsupported $ref '{ref}'")
        node = schema["$defs"][ref[8:]]
        seen += 1
        if seen > 10:
            fail(f"{where}: $ref loop")
    return node


def md(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def lit(v):
    """A schema value as written in YAML or JSON: strings plain, others as JSON."""
    return v if isinstance(v, str) else json.dumps(v)


def code(text):
    return f"`{md(lit(text))}`"


def items(n):
    return f"{n} item" + ("" if n == 1 else "s")


def allowed(n):
    """The constraints of one schema node, as short text."""
    parts = []
    if "anyOf" in n:
        parts.append(" or ".join(allowed(x) or "any" for x in n["anyOf"]))
    if "enum" in n:
        parts.append("one of " + ", ".join(code(v) for v in n["enum"]))
    if "const" in n:
        parts.append("must be " + code(n["const"]))
    if n.get("maxLength") == 0:
        parts.append("empty")
    elif "maxLength" in n:
        parts.append(f"max length {n['maxLength']}")
    if "minLength" in n:
        parts.append(f"min length {n['minLength']}")
    if "minItems" in n:
        parts.append(f"min {items(n['minItems'])}")
    if "format" in n:
        parts.append("format " + code(n["format"]))
    if "pattern" in n:
        parts.append("pattern " + code(n["pattern"]))
    if "not" in n and "pattern" in n["not"]:
        parts.append("not matching " + code(n["not"]["pattern"]))
    if "propertyNames" in n:
        pn = n["propertyNames"]
        if "pattern" in pn:
            parts.append("names match " + code(pn["pattern"]))
        if "not" in pn and "pattern" in pn["not"]:
            parts.append("names not matching " + code(pn["not"]["pattern"]))
        if "not" in pn and "enum" in pn["not"]:
            parts.append("names not in " + ", ".join(code(v) for v in pn["not"]["enum"]))
    return "; ".join(parts)


def rows(schema, node, path, out, missing):
    """Collect one row per property. Walks properties, items and additionalProperties."""
    node = resolve(schema, node, path or "<root>")
    required = set(node.get("required", []))
    for name, sub in node.get("properties", {}).items():
        p = f"{path}.{name}" if path else name
        target = resolve(schema, sub, p)
        if not sub.get("description") and not target.get("description"):
            missing.append(p)
        typ = target.get("type", "")
        if name in required:
            typ += ", required"
        default = json.dumps(target["default"]) if "default" in target else "—"
        out.append((p, typ, default, allowed(target) or "—", sub.get("description") or target.get("description") or ""))
        rows(schema, target, p, out, missing)
    if isinstance(node.get("items"), dict):
        rows(schema, node["items"], path + "[]", out, missing)
    ap = node.get("additionalProperties")
    if isinstance(ap, dict):
        rows(schema, ap, f"{path}.<name>", out, missing)


def facts(schema, node, path, acc):
    """Flatten an if/then schema into {path: [fact, ...]}."""
    node = resolve(schema, node, path)
    for k in node.get("required", []):
        acc.setdefault(f"{path}.{k}" if path else k, []).append("is set")
    if "const" in node:
        acc.setdefault(path, []).append(f"is {code(node['const'])}")
    if "minLength" in node:
        acc.setdefault(path, []).append("is not empty")
    if "minItems" in node:
        acc.setdefault(path, []).append(f"has at least {items(node['minItems'])}")
    pn = node.get("propertyNames", {})
    if "not" in pn and "enum" in pn["not"]:
        acc.setdefault(path, []).append("has none of the keys " + ", ".join(code(k) for k in pn["not"]["enum"]))
    for name, sub in node.get("properties", {}).items():
        facts(schema, sub, f"{path}.{name}" if path else name, acc)


def render_facts(acc):
    """One sentence part per path. Drop 'is set' when a more specific fact exists."""
    parts = []
    for p in sorted(acc):
        fs = list(acc[p])
        if "is set" in fs and (len(fs) > 1 or any(q.startswith(p + ".") for q in acc)):
            fs.remove("is set")
        if fs:
            parts.append(f"{code(p) if p else 'the object'} " + " and ".join(fs))
    return "; ".join(parts)


def rules(schema, node, prefix, out):
    for i, branch in enumerate(node.get("allOf", [])):
        cond, then = {}, {}
        facts(schema, branch["if"], prefix.rstrip("."), cond)
        facts(schema, branch["then"], prefix.rstrip("."), then)
        out.append(f"If {render_facts(cond)}, then {render_facts(then)}.")


def build(schema):
    validate(schema, "<root>")
    out, missing = [], []
    rows(schema, schema, "", out, missing)
    if missing:
        fail("properties without a description:\n  " + "\n  ".join(sorted(missing)))
    rl = []
    rules(schema, schema, "", rl)
    for name, d in sorted(schema.get("$defs", {}).items()):
        if name == "connector":
            rules(schema, d, "auth.dex.connectors[].", rl)
        elif d.get("allOf"):
            fail(f"$defs.{name}: no path known for its rules (extend hack/gen_values_ref.py)")
    lines = [
        "# Values reference",
        "",
        "<!-- Generated by hack/gen_values_ref.py from charts/keelson/values.schema.json. Do not edit. Run `make values-ref`. -->",
        "",
        "This page lists every values key in the schema. The default column shows the schema default.",
        "For the full default values, see `charts/keelson/values.yaml`.",
        "",
    ]
    tops = sorted({r[0].split(".")[0].split("[")[0] for r in out})
    for top in tops:
        lines += [f"## `{top}`", "", "| Key | Type | Default | Allowed | Description |", "|---|---|---|---|---|"]
        for p, typ, default, allow, desc in sorted(r for r in out if r[0].split(".")[0].split("[")[0] == top):
            lines.append(f"| {code(p)} | {md(typ)} | {md(default)} | {allow} | {md(desc)} |")
        lines.append("")
    if rl:
        lines += ["## Rules", "", "The chart fails to render when one of these rules is broken.", ""]
        lines += [f"- {r}" for r in rl]
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text = build(json.loads(SCHEMA.read_text()))
    if a.write:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(text)
        print(f"gen_values_ref: wrote {OUT.relative_to(ROOT)}")
        return
    have = OUT.read_text() if OUT.exists() else ""
    if have != text:
        sys.stdout.writelines(difflib.unified_diff(have.splitlines(True), text.splitlines(True), "docs/reference/values.md", "generated"))
        fail("docs/reference/values.md is stale (run 'make values-ref' and commit it)")
    print("gen_values_ref: docs/reference/values.md is up to date")


if __name__ == "__main__":
    main()
