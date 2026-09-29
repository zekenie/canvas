#!/usr/bin/env python3
"""Copies `QueryPrompt.system` into the canvas skill's query-prompt.md, between its marks.

The prompt's one source is the raw string literal in Sources/Composition/QueryPrompt.swift; the
skill carries a copy, which CompositionTests' "Query prompt" suite holds equal to it byte for byte.
After changing the prompt, run this (from anywhere) and commit both files.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/Composition/QueryPrompt.swift"
COPY = ROOT / ".claude/skills/canvas/query-prompt.md"
BEGIN = "<!-- QueryPrompt.system: begin -->"
END = "<!-- QueryPrompt.system: end -->"


def prompt() -> str:
    """The literal's text: what's between `#\"\"\"` and `\"\"\"#`, which leaves out the line break
    before the closing delimiter's line (the literal ends with a blank line, so the text ends with
    one line break)."""
    swift = SOURCE.read_text()
    start = swift.index('#"""\n') + len('#"""\n')
    end = swift.index('\n"""#', start)
    text = swift[start:end]
    if "\\(" in text or "\\#(" in text:
        raise SystemExit("the prompt interpolates: it must be the text as sent")
    return text


def main() -> None:
    copy = COPY.read_text()
    before, rest = copy.split(BEGIN + "\n", 1)
    _, after = rest.split(END, 1)
    COPY.write_text(before + BEGIN + "\n````text\n" + prompt() + "````\n" + END + after)
    print(f"copied QueryPrompt.system into {COPY.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
