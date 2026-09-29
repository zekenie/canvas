# Schema card prompts: quick evals

Whether the two prompts that keep a schema card's description and its JSON Schema in step, and the
one that links the description's words to the schema's parts (Highlights, below), basically do the
job. Not a framework: a script, a CSV of cases, a CSV of results, read by eye.

- `evals.py` runs the cases and appends a row per case to `results.csv` (`pass`, what failed, latency,
  tokens, the output on one line); `results.jsonl` gets everything, and isn't committed.
- `cases.csv` holds the cases (64: 41 prompt → schema, 23 schema → prompt), written by
  `gen_cases.py`, where they're readable. Edit `gen_cases.py`, then run it. Four chains (a hand edit
  surviving a prompt edit, a round trip, two both-ways edits) are in `evals.py` itself.

Nothing the app sends is copied here: `evals.py` reads the system prompts, each direction's
`max_tokens` and the temperature out of `Sources/Schemas/SchemaPrompts.swift`, the model's id out of
`Sources/LanguageModels/AnthropicModel.swift`, and `gen_cases.py` a new card's schema out of
`Sources/Schemas/SchemaCard.swift`, so the evals send exactly what the app does (a schema written
from nothing is sent with the new card's schema as `previous_schema`, as `SchemaSync` sends it). Its
user message and parse rule copy `SchemaPrompts.toSchema`, `toPrompt` and `parse`; when to call and
what's written is `SchemaSync`.

## Running it

Run it from this directory:

```sh
cd scripts/schema-prompts
python3 evals.py --check            # reads the prompts and settings out of the Swift; no call
python3 evals.py --round 1          # every case, and the chains
python3 evals.py --round 2 --only s_vague_pet,p_add_field --runs 3
```

The key is the one the app's Settings saves (Infinite Canvas › Settings…, ⌘,):
`~/Library/Application Support/InfiniteCanvas/anthropic-api-key`, else `$ANTHROPIC_API_KEY`. The
script never prints or writes it. It calls `https://api.anthropic.com/v1/messages` (Claude Haiku 4.5,
temperature 0), six at a time; if a sandbox blocks the network, run it outside it.

Meta-validating the schemas that come back needs `jsonschema` in `_pylib` here; without it that
check is skipped, and `evals.py` says so when it starts:

```sh
cd scripts/schema-prompts
python3 -m pip install --target _pylib jsonschema==4.23.0
```

## Highlights

The third prompt links a description's words to the parts of its schema they say
(`SchemaPrompts.highlightsSystem`, asked by `SchemaHighlighter`). `highlight_evals.py` reads it, its
model (Sonnet 5.5), effort and `max_tokens` out of `SchemaPrompts.swift`, sends each of
`highlight_cases.py`'s cases (26: the owner's Jira ticket, terse lists, sentences, nested objects, a
shared definition, either-ors and conditions, other languages, typos, words the schema doesn't say,
injection, twenty fields), and scores the answer as the app reads it: each link's words found in the
description in order, its pointer followed in the schema. A link is right (or right, wider or
narrower), misattributed (its words are a listed link's, its pointer another's: the popover would
show the wrong part), an extra (words no case lists, printed to be read), or invalid (words not in
the description, a pointer to nothing). The prompt's own examples are none of the cases'.

```sh
python3 highlight_evals.py --check                    # reads the prompt and settings; no call
python3 highlight_evals.py --runs 2 --out r.json
python3 highlight_evals.py --model claude-haiku-4-5   # to compare
```

What it found (26 cases, twice each): Sonnet 5.5 at 356 of 358 links, none misattributed or
invalid, some 2 s an answer and 1,500 tokens in, 190 out; Haiku 4.5 at 91%, some linked to the wrong
field, which is why the highlights ask Sonnet 5.5 while the sync asks Haiku 4.5.

## The live smoke test

`SCHEMA_LIVE=1 build/debug/SchemasTests/SchemasTests` (after `./test.sh` has built it) runs three
cases through the app's own path, `AnthropicModel` and `SchemaSync`, and prints what came back.
`./test.sh` never sets it.
