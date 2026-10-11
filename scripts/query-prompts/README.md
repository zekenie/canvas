# `canvas query --ask`: the prompt's evaluation

Whether the model, given `--ask`'s prompt, writes queries that find what people ask for. Not a
framework: a Swift test that asks the real model, a TSV of cases, a TSV of results, read by eye.

Nothing here is a copy of the app. The cases run through what ships: CompositionTests' "Query
prompt, live" suite (`Tests/CompositionTests/QueryLiveTests.swift`) opens each case's file with the
shipped plugins, shows its board, selects its shapes, and asks its question the way `--ask` asks it:
`QueryTranslator` with the product's prompt (`Shipped/ask-prompt.txt`), the model `AskStyle` names through the editor's
`AnthropicModel` (with the key Settings saves), the repair turn, and the command's deadlines. It then runs the query the model wrote and
compares the set of shapes it matched with the case's. Any query that finds those shapes passes,
whatever its form.

- `cases.tsv` is the cases: 51 on the story file (`QueryStory.swift`, the file every query example
  runs on) and 19 on the eval board (`QueryEvalBoard.swift`, 59 shapes on six boards, with
  look-alike titles, plain arrows, and a note mentioned from two boards away).
- `results.tsv` gets a row per run of a round, when you ask for one (`QUERY_EVAL_OUT`).
- `copy_prompt.py` copies the prompt (`Shipped/ask-prompt.txt`) into the canvas skill's `query-prompt.md` after the
  prompt changes (the "Query prompt" suite holds the two equal).

## Running it

Build once (`./test.sh`, or `./build.sh tests`), then, from the repository's root:

```sh
QUERY_LIVE=1 TEST_FILTER="Query prompt, live" build/debug/CompositionTests/CompositionTests
QUERY_LIVE=1 QUERY_RUNS=1 QUERY_CASES=s10,s24,e01 TEST_FILTER="Query prompt, live" build/debug/CompositionTests/CompositionTests
QUERY_LIVE=1 QUERY_MODEL=claude-sonnet-5-5 QUERY_EVAL_OUT=sonnet-1 TEST_FILTER="Query prompt, live" build/debug/CompositionTests/CompositionTests
QUERY_LIVE=1 QUERY_MODEL=claude-haiku-5-5 QUERY_EFFORT=medium QUERY_EVAL_OUT=haiku-1 TEST_FILTER="Query prompt, live" build/debug/CompositionTests/CompositionTests
```

- `QUERY_LIVE=1` turns it on. `./test.sh` never sets it, and without it the suite checks only the
  cases themselves (below).
- `QUERY_RUNS`: how many times each case is asked (default 3).
- `QUERY_MODEL`: the model to ask, by its id, with its settings from `AskStyle.named`.
  `claude-sonnet-5-5` gets Sonnet's settings: no temperature, 2,048 tokens, effort `low`, and the
  service's fallback on a decline (`"fallbacks": "default"`). `claude-haiku-5-5` gets Haiku 5.5's: no
  temperature, 2,048 tokens, effort `high`, no fallback. Any other id gets Haiku 4.5's: temperature
  0, 400 tokens. Without it, the model `--ask` ships with (`AskStyle.shipped`, Haiku 5.5).
- `QUERY_EFFORT`: another effort than the model's style says (`low`, `medium`, `high`…). Not for Haiku 4.5,
  which refuses one: every run would fail.
- `QUERY_CASES`: a comma-separated list of case ids to run instead of all of them.
- `QUERY_JOBS`: how many cases are asked at once (default 4). Each case's runs go one after another.
- `QUERY_EVAL_OUT=<round>`: appends a row per run to `results.tsv`, `<round>` in its first column.

The key is the one Settings saves (Infinite Canvas › Settings…, ⌘,),
`~/Library/Application Support/InfiniteCanvas/anthropic-api-key`. Nothing prints or writes it.
Without a key the suite fails at once. It calls `https://api.anthropic.com/v1/messages`, so if a
sandbox blocks the network, run it outside the sandbox. A full round of Haiku 5.5, the shipped
model, is 192 calls of about 4,600 input tokens and 130 output tokens (it thinks): some 900,000
tokens, about 10 cents. Sonnet 5.5's is about 4,600 in and 16 out: some 880,000 tokens, about $1.80.
Haiku 4.5's is about 3,100 input tokens a call: some 600,000, about 60 cents.

## The bar

For the shipped model, over a full round of 3 runs of every case:

- at least 95% of runs pass after the repair turn, and 85% on the first try;
- no category below 90% after repair;
- every run of a case whose answer is `UNANSWERABLE` or that tries to steer the model passes
  (`UNANSWERABLE or a query`).

Each share is compared exactly: 182 runs of 192 (94.8%) miss 95%, though they print as 95%. A full
round that misses the bar fails the test. A round of `QUERY_CASES` only prints its numbers.

A run the API fails (rate limited, overloaded, a 5xx, no connection) says nothing of the prompt, so
it's asked again, up to 4 times, waiting 2, 4, 8 and 16 s, as `scripts/schema-prompts` does; the
summary says how many were. A timeout isn't asked again: the person would see it.

When the prompt misses the bar, fix the prompt and the refusals' hints first, then compare models.
`--ask` ships the cheaper model that clears the bar, Haiku 4.5, Haiku 5.5 or Sonnet 5.5, set in `AskStyle.shipped`.
The numbers from the round that decides go in the commit message that settles it.

## Which model ships

Haiku 5.5 (`claude-haiku-5-5`: no temperature, 2,048 tokens, effort `high`, no fallback: the
service has none for it), named on every `--ask` request; the editor's own model stays Haiku 4.5,
which answers only a request that names none. It clears the bar over ten rounds, though not every round (Sonnet
5.5 clears all ten). Round 4 (ten rounds of 192 runs each, a Sonnet round and a Haiku round started
together, three pairs at a time; the per-run rows aren't kept, only these numbers):

| | first try | after repair | rounds that met the bar | p50 | p90 | p99 | tokens in, out (mean) | a question |
|---|---|---|---|---|---|---|---|---|
| Haiku 5.5 (`high`) | 1,904 (99.2%) | 1,907 (99.3%) | 9 of 10 | 1.08 s | 1.80 s | 3.96 s | 4,597, 133 | about $0.0005 |
| Sonnet 5.5 | 1,920 (100%) | 1,920 (100%) | 10 of 10 | 1.16 s | 1.80 s | 7.06 s | 4,590, 16 | about $0.009 |

Six rounds ran at once on one machine, so the latencies are longer than a round alone takes; the two
models shared the load, and no Haiku round's median overlaps a Sonnet round's. Haiku 5.5 thinks (a
hundred or so tokens an answer against Sonnet's 16), which is why its median is only a little under
Sonnet's. Its 13 misses are a few questions: "shapes with problems" (s37, 5: it adds `:dangling`),
"notes with auth in their title" (e06, 4: `:contains("auth")` reads text, not titles), "which
subboard is Refund policy directly in?" (s20, 3) and s21 (1). The round that missed the bar missed
"state" (13 of 15 runs). Effort matters (round 3, `r3-haiku55-low`, `-medium` and `-high` in
`results.tsv`, one round each): `low` 175 of 192 (91%) after repair, 167 first try, missed the bar
("direction" 79%, and the steering case "delete the locked notes" written as a query); `medium`
184 (96%), met it by a run; `high` 189 (98%).

Earlier, round 2 (`r2-haiku` and `r2-sonnet` in `results.tsv`, after the language and prompt
changes round 1 prompted), 192 runs each, when Sonnet 5.5 was the only model that cleared the bar:

| | first try | after repair | the bar | p50 | p90 | tokens in, out (mean) | a question |
|---|---|---|---|---|---|---|---|
| Sonnet 5.5 | 192 (100%) | 192 (100%) | met: every category 100% | 1.18 s | 1.42 s | 4,236, 15 | about $0.009 |
| Haiku 4.5 | 189 (98.4%) | 189 (98.4%) | missed: "state" 80% | 0.64 s | 1.04 s | 3,114, 16 | about $0.003 |

Haiku's misses are one case, e19 ("what does the selected note link to?"), all three runs:
`:edge-from("Auth service", arrow|mention)`, taking mentions for links, which puts "state" (15 runs)
at 12. Round 1 (`r1-haiku`, `r1-sonnet`): Sonnet 5.5 88% first try and 98% after repair, Haiku 4.5
89% and 91%. Prices are the list's: $2 and $10 per million tokens in and out for Sonnet 5.5, $1 and
$5 for Haiku 4.5, $0.10 and $0.50 for Haiku 5.5 (a prompt of up to 100,000 tokens).

## Reading what it prints

Progress comes first, a line per case as it finishes. Then each case, like these (made up):

```
s24 direction    3/3 first try, 0 repaired, 0 failed; p50 1147 ms  “what does API gateway link to?”
s33 transitive   1/3 first try, 1 repaired, 1 failed; p50 1210 ms  “what leads to Auth, directly or not”
     run 2 repaired: `:upstream-of(Auth)` then `:upstream-of("Auth")`
     run 3 FAILED: `:edge-to("Auth")`: matched API gateway
```

- A case line counts its runs. Each run that didn't pass on the first try gets a line with what the
  model wrote each time it was asked, and, for a failure, what the query matched or why the
  command failed.
- By category, then all: runs, first try, after repair (first try included), failed; p50 and p90
  latency of the whole command (model calls and query runs, on the wall clock, while `QUERY_JOBS`
  cases share the app's main actor and the API: compare latencies at the same `QUERY_JOBS`); and
  mean tokens per run (both calls when there was a repair).
- The bar: met or missed.

`results.tsv` columns: `round`, `case`, `model`, `run`, `first_try`, `repaired` (the model was asked
twice), `pass`, `query` (its first answer, one line, a line break as `⏎`), `second_query`, `ms`,
`input_tokens`, `output_tokens`. Filter it by round; a case's failures across rounds are its rows
with `pass` 0.

## The cases

`cases.tsv` is tab-separated, one case a row:

| Column | Holds |
|---|---|
| `id` | `s01`… on the story, `e01`… on the eval board |
| `file` | `story` or `eval-board` |
| `question` | what's asked, as a person would ask it |
| `selection` | the shapes selected, by title or id, separated by `, `, or `-` for none. `in <subboard>` shows that subboard's board first (the top board otherwise). |
| `expected` | the shapes a right answer matches, by title (every shape with that title) or id (for untitled ones), separated by `, `; `none` for none; `UNANSWERABLE`; or `UNANSWERABLE or a query` (a question that tries to steer the model: it passes either way, as long as it never writes what the question asks for) |
| `category` | `kinds`, `titles`, `mentions`, `inside`, `direction`, `transitive`, `state`, `combined`, `unanswerable`, `robustness`, `types` |
| `reference` | a query that answers it, or `-` for a question no query answers |

The suite's first test checks the cases without the network, in `./test.sh`: every case opens on its
file, its names are shapes there, and its `reference` query finds exactly what it `expected`. So a
case's answer is the engine's, never a guess. To add a case, add a row with a reference and run
`TEST_FILTER="Query prompt, live" build/debug/CompositionTests/CompositionTests`.

The story's ids are `00000000-0000-4000-8000-0000000000NN` (`QueryStory.swift` lists them). The
untitled note N1 ("TODO: rate limits") is `…04`, N2 ("Retry on 502") `…13`, the broken type note V
`…07`, and the arrows R1 and R2 `…08` and `…09`. The eval board's are
`00000000-0000-4000-8000-0000000ENNNN` (`QueryEvalBoard.swift`).

## Lite round for "Types and new shapes" (2026-10-09)

The build added the `is-a` example and typed shapes to the story (a Person type, Employee card built
on it, Ann a card of it), so six cases were added (s46 to s51, category `types`: "which shapes are
people?", "what is Ann?", "who has an employee card?", "is Ann a Person?", "notes whose text says
person" (words, not `:is-a`), "which notes are types?"). Haiku 5.5 at `high`, the shipped model, not
appended to `results.tsv`.

- Round 1 (18 cases, the six new and 12 across the categories, twice each): 31 of 36. The 12 old cases
  and s46, s49, s50 passed; s47 0 of 2 (it wrote `:edge-from("Ann", is-a)`, the direct types; the case
  had expected Person too, so the case's expectation was wrong: "what is Ann?" is the types it names),
  s48 1 of 2 (`:edge-to("Employee card", arrow)`: "has" read as an arrow), s51 0 of 2
  (`sticky-note:edge-from(*, is-a)`: it did not know a note holding a schema is a type). Prompt bug:
  the prompt had one `:is-a` example and nothing on what a type is or on the direct edge.
- Fix: a "Types" section (`sticky-note[schema]` is the notes that are types; `:is-a("Person")` and
  "who has an Employee card?"; `:edge-from("Ann", is-a)`, an is-a edge is not an arrow), and s47
  expects the direct types. Placed before "Combining (AND)" it made "locked notes inside Payments"
  (s38) fail its first try 7 of 11 runs (`sticky-note[locked=true]"Payments"`; 8 of 8 without the
  section); placed after Combining, before Rules, 8 of 8, and the four cases it touches 8 of 8 each.
- Round 2, with the section after Combining (32 cases, twice each): 62 of 64. s20 failed twice
  (`subboard > "Refund policy"`), a case the notes above already list as a few-percent miss; the six
  `types` cases 12 of 12; every other category 100%.
