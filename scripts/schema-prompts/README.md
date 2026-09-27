# Schema card prompts: quick evals

Whether the two prompts that keep a schema card's description and its JSON Schema in step basically
do the job. Not a framework: a script, a CSV of cases, a CSV of results, read by eye.

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

## The live smoke test

`SCHEMA_LIVE=1 build/debug/SchemasTests/SchemasTests` (after `./test.sh` has built it) runs three
cases through the app's own path, `AnthropicModel` and `SchemaSync`, and prints what came back.
`./test.sh` never sets it.
