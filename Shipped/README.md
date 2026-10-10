# Shipped

What the product says in a file, not in a module: text that names the shipped kinds, edge types and
words, which no one module knows all of.

`build.sh` puts every `*.txt` here in each executable that is the product (the app, its Quick Look
extension, and the tests of what ships), as a section of the binary, and the core reads one back by
its name: `ShippedText.named("ask-prompt")`. Nothing looks for a file at run time. A file's name is
lowercase letters, digits and hyphens, at most 14 characters, since it names a section.

| File | What it is | Read by |
|---|---|---|
| `ask-prompt.txt` | `canvas query --ask`'s system prompt, byte for byte: no comments, and it ends with its last line's one line break. | `QueryTranslationPlugin()` |
| `ask-rule.txt` | The one line added to that prompt when the query is stored and run later (a reference's). The translator takes it without its line break. | `QueryTranslationPlugin()` |

## Changing the prompt

1. Edit `ask-prompt.txt`.
2. List each query-like example it writes in one of the two lists in
   `Tests/CompositionTests/QueryPrompt.swift` (`runnableExamples`, `illustrativeExamples`):
   QueryPromptTests hold every one to the language on the story file.
3. Run `python3 scripts/query-prompts/copy_prompt.py`, which copies it into the canvas skill
   (`.claude/skills/canvas/query-prompt.md`); QueryPromptTests hold the two equal.
4. Evaluate it against the model: `scripts/query-prompts/README.md`.
