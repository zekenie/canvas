# Type prompts: quick evals

Whether the two prompts that keep a type's words (a note's text) and its JSON Schema in step, and the
one that links the description's words to the schema's parts (Highlights, below), basically do the
job. Not a framework: a script, a CSV of cases, a CSV of results, read by eye.

- `evals.py` runs the cases and appends a row per case to `results.csv` (`pass`, what failed, latency,
  tokens, the output on one line); `results.jsonl` gets everything, and isn't committed.
- `cases.csv` holds the cases (74: 47 prompt → schema, 27 schema → prompt), written by
  `gen_cases.py`, where they're readable. Edit `gen_cases.py`, then run it. Four chains (a hand edit
  surviving a prompt edit, a round trip, two both-ways edits) are in `evals.py` itself.
- Ten of the cases (`s_ref_…`, `p_ref_…`) name other types, as the app shows them to the
  model: each `@` and a word (`@Address`), listed in `<schemas>` (the case's `schemas`), a mention
  that word in the prompt and a `$ref` to the type that word in the schema. For those, and only
  those, the system prompt has what it says of other schemas after it (`toSchemaReferences`,
  `toPromptReferences`), as `SchemaPrompts.system` sends it; every `$ref` to an `@` word must be
  to one `<schemas>` lists, as the app reads them back. Added to every request, the same words
  cost three of the other cases (a snake_case name, a `$ref`'d field marked required, a round
  trip's `required`), which is why they go only where there are other schemas.

Nothing the app sends is copied here: `evals.py` reads the system prompts, each direction's
`max_tokens`, what each says of other schemas, the model and its effort out of `Sources/Types/SchemaPrompts.swift`, and `gen_cases.py` a new type's schema out of
`Sources/Types/TypeSchema.swift`, so the evals send exactly what the app does (a schema written
from nothing is sent with the new type's schema as `previous_schema`, as `TypeSync` sends it). Its
user message and parse rule copy `SchemaPrompts.toSchema`, `toPrompt` and `parse`; when to call and
what's written is `TypeSync`.

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
script never prints or writes it. It calls `https://api.anthropic.com/v1/messages` (Claude Haiku 5.5 at `medium` effort, or
`EVAL_EFFORT`), six at a time; if a sandbox blocks the network, run it outside it.

Meta-validating the schemas that come back needs `jsonschema` in `_pylib` here; without it that
check is skipped, and `evals.py` says so when it starts:

```sh
cd scripts/schema-prompts
python3 -m pip install --target _pylib jsonschema==4.23.0
```

## Highlights

The third request links a description's words to the parts of its schema they say. The highlights
are a prose map (Sources/ProseMaps, asked for by `ProseMapService`), so the request is every
target's frame (`ProseMapPrompt.frame`) with the schema's guide in it (`SchemaPrompts.highlightsGuide`,
`SchemaTarget`), and `highlightsReferences` after it for a description that names other schema
types. `highlight_evals.py` puts it together as the app does, the frame, the model (Haiku 5.5),
effort and `max_tokens` read out of `ProseMapPrompt.swift` and the guide out of
`SchemaPrompts.swift`, sends each of `highlight_cases.py`'s cases (28: the owner's Jira ticket,
terse lists, sentences, nested objects, a shared definition, either-ors and conditions, other
languages, typos, words the schema doesn't say, injection, twenty fields, and two that name other
types, each `@` word linked to what points to it), and scores the answer as the app reads it:
each link's words found in the description in order, its address (a JSON Pointer) followed in the
schema. A link is right (or right, wider or narrower), misattributed (its words are a listed link's,
its pointer another's: the popover would show the wrong part), an extra (words no case lists,
printed to be read), or invalid (words not in the description, a pointer to nothing). The guide's
own examples are none of the cases'.

```sh
python3 highlight_evals.py --check                    # reads the prompt and settings; no call
python3 highlight_evals.py --runs 2 --out r.json
python3 highlight_evals.py --model claude-sonnet-5-5   # to compare
EVAL_EFFORT=high python3 highlight_evals.py --model claude-haiku-5-5   # another effort than the app's
```

What it found, 28 cases four times each (2026-10-06), as the highlights became a prose map:
Sonnet 5.5 at 753 of 760 links with the frame and the guide, none misattributed or invalid, some
1.8 s an answer and 1,500 tokens in, 155 out; the prompt it replaced at 749 of 760, none
misattributed. Both miss the same few ("who has it" for an employee's id every time; "each cell" of a
list of lists and "must have" for `required` now and then), and both sometimes link "shipped to" and
"billed to" to the properties that point at another type as well as its `@` word (an extra). A rule
telling the model to leave out words it can't place was tried in the frame and taken out: it found
none misattributed either way and missed "each cell" more often. Before (26 cases, twice each),
Sonnet 5.5 was at 356 of 358 and Haiku 4.5 at 91%, some linked to the wrong field, which is why the
highlights asked Sonnet 5.5 while the sync asked Haiku 4.5, until Haiku 5.5 for both.

Haiku 5.5 (2026-10-08), the same 28 cases four times each, one round per effort (`EVAL_EFFORT`), so
evidence and not a verdict: `low` 745 of 760 links, 2 misattributed (`required` linked to the
customer's rather than the root's, in two runs of the invoice case) and 2 words the description
doesn't have ("what it's called"); `medium` 748 and `high` 750, 4 misattributed each, all four the
`matrix` case, where it links "cells" to the number a cell is rather than to the row of cells the
case lists, a reading the description allows; Sonnet 5.5 the same hour, 751, none misattributed. Haiku
5.5 thinks (some 540 tokens an answer at `medium`, against Sonnet's 155; the largest 1,243, under the
2,048 `max_tokens`), and its `medium` and `high` rounds ran beside each other, so their 3.3 s median
is not a clean one (`low` 1.5 s, Sonnet 2.2 s). The highlights ask Haiku 5.5 at `medium` effort,
some a tenth of Sonnet's cost an answer.

## The live smoke test

`SCHEMA_LIVE=1 build/debug/SchemasTests/SchemasTests` (after `./test.sh` has built it) runs three
cases, and a type that mentions another both ways, through the app's own path, `AnthropicModel` and `TypeSync`, and prints what came back.
`./test.sh` never sets it.
