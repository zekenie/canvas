#!/usr/bin/env python3
"""Copies `--ask`'s prompt into the canvas skill's query-prompt.md, between its marks.

The prompt's one source is Shipped/ask-prompt.txt, the text byte for byte, which the build puts in
the product's executables; the skill carries a copy, which CompositionTests' "Query prompt" suite
holds equal to it byte for byte. After changing the prompt, run this (from anywhere) and commit
both files.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Shipped/ask-prompt.txt"
COPY = ROOT / ".claude/skills/canvas/query-prompt.md"
BEGIN = "<!-- QueryPrompt.system: begin -->"
END = "<!-- QueryPrompt.system: end -->"


def prompt() -> str:
    """The file's text, which ends with its last line's one line break."""
    text = SOURCE.read_text()
    if not text.endswith("\n") or text.endswith("\n\n"):
        raise SystemExit(f"{SOURCE.name} ends with its last line and one line break")
    return text


def main() -> None:
    copy = COPY.read_text()
    before, rest = copy.split(BEGIN + "\n", 1)
    _, after = rest.split(END, 1)
    COPY.write_text(before + BEGIN + "\n````text\n" + prompt() + "````\n" + END + after)
    print(f"copied {SOURCE.relative_to(ROOT)} into {COPY.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
