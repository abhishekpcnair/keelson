#!/usr/bin/env python3
"""Print the CHANGELOG.md section for one release, for `gh release create --notes-file`.

A section starts at a `## v<version>` heading (optionally followed by a date) and runs to the
next `## ` heading. The heading itself is not printed. Fails when the section is missing or empty.

Usage: hack/release_notes.py v0.1.0-alpha.1 [CHANGELOG.md]
"""
import pathlib
import re
import sys


def section(changelog: str, tag: str) -> str:
    version = tag[1:] if tag.startswith("v") else tag
    heading = re.compile(r"^## v?" + re.escape(version) + r"(\s.*)?$")
    lines, body, inside = changelog.splitlines(), [], False
    for line in lines:
        if line.startswith("## "):
            if inside:
                break
            inside = bool(heading.match(line))
            continue
        if inside:
            body.append(line)
    text = "\n".join(body).strip()
    if not inside and not text:
        raise ValueError(f"no '## v{version}' section in the changelog")
    if not text:
        raise ValueError(f"the '## v{version}' section is empty")
    return text + "\n"


def main(argv):
    if not 2 <= len(argv) <= 3:
        sys.exit(__doc__)
    path = pathlib.Path(argv[2] if len(argv) == 3 else "CHANGELOG.md")
    if not path.is_file():
        sys.exit(f"release_notes: {path} not found")
    try:
        sys.stdout.write(section(path.read_text(), argv[1]))
    except ValueError as e:
        sys.exit(f"release_notes: {e}")


if __name__ == "__main__":
    main(sys.argv)
