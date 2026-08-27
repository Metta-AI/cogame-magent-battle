#!/usr/bin/env python3
"""Embed the repo's docs into coworld_manifest_template.json as inline text.

The acceptance checklist (coworld-builder prompts/30-review-loop.md, item 10)
spells `game.docs` as

    {"readme":  {"type": "text", "value": …},
     "pages":  [{"id", "title", "content": {"type": "text", "value": …}}]}

i.e. inline TEXT, not a `uri`. The platform validator accepts either, and other
coworlds ship both shapes, but the checklist is what a release is gated on, so
this repo ships `text`.

Inlining duplicates files that also live in the tree, so this script is the
single writer of that block and `tests/test_magent_manifest.nim` asserts the
manifest's copy equals the file byte for byte. Re-run it after editing
README.md or docs/*.md:

    python3 tools/embed_manifest_docs.py

Only the `game.docs` block is rewritten -- the rest of the manifest is spliced
back verbatim, so the diff is the docs and nothing else.
"""

import json
import pathlib
import sys

README = "README.md"
PAGES = [
    ("rules.md", "Rules", "docs/RULES.md"),
    ("porting.md", "Porting MAgent battle", "docs/PORTING-MAGENT.md"),
]

DOCS_OPEN = '    "docs": {\n'
DOCS_NEXT = '    "config_schema": {\n'


def block(root: pathlib.Path) -> str:
    def value(path: str) -> str:
        return json.dumps((root / path).read_text(encoding="utf-8"),
                          ensure_ascii=False)

    lines = [DOCS_OPEN.rstrip("\n")]
    lines.append('      "readme": {')
    lines.append('        "type": "text",')
    lines.append(f'        "value": {value(README)}')
    lines.append('      },')
    lines.append('      "pages": [')
    for index, (page_id, title, path) in enumerate(PAGES):
        tail = "" if index == len(PAGES) - 1 else ","
        lines.append('        {')
        lines.append(f'          "id": {json.dumps(page_id)},')
        lines.append(f'          "title": {json.dumps(title)},')
        lines.append('          "content": {')
        lines.append('            "type": "text",')
        lines.append(f'            "value": {value(path)}')
        lines.append('          }')
        lines.append(f'        }}{tail}')
    lines.append('      ]')
    lines.append('    },')
    return "\n".join(lines) + "\n"


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    manifest_path = root / "coworld_manifest_template.json"
    text = manifest_path.read_text(encoding="utf-8")
    if DOCS_OPEN not in text or DOCS_NEXT not in text:
        print("error: could not find the docs block anchors in "
              f"{manifest_path}", file=sys.stderr)
        return 1
    start = text.index(DOCS_OPEN)
    end = text.index(DOCS_NEXT, start)
    rewritten = text[:start] + block(root) + text[end:]
    json.loads(rewritten)          # never write a manifest that does not parse
    manifest_path.write_text(rewritten, encoding="utf-8")
    print(f"embedded {README} and {len(PAGES)} pages "
          f"({len(rewritten)} bytes total)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
