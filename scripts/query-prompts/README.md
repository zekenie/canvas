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

- `cases.tsv` is the cases: 54 on the story file (s52 to s54: subboards of no type, and what a subboard is) (`QueryStory.swift`, the file every query example
  runs on), 19 on the eval board (`QueryEvalBoard.swift`, 59 shapes on six boards, with
  look-alike titles, plain arrows, and a note mentioned from two boards away), 19 on the fields
  board (`QueryFieldsBoard.swift`: two types, two relationship types (Placed by, Friendship) and six notes
  with field values, a mention, the relationships between them and one that is a misfit) and 19 on the
  school board (`QuerySchoolBoard.swift`: Teacher, Student and Pet, the relationship types Teaches and Has pet
  between their notes, and a subboard of plain notes and arrows). The fields board's ten
  relationship cases are r01 to r10 (who is Ann Lee friends with, which orders she placed, who placed an
  order, which friendships began before 2020, which orders have no customer, which relationships don't fit,
  which relationship types Order has, who has the most friends, a mention that is not a relationship, and
  what an order can be related to); f05 and f06 ask the same of Placed by that they once asked of a field.
  The school board's c01 to c19 ask across both relationships to a field at the far end (c01 is the owner's
  "all teachers who have students who have a blue pet beta fish"), of plain notes about animals no Pet's
  species names (c14, c15, c19: words and arrows, not a type's field), and through `/query`: a case whose
  selection column starts `/query` is asked as the command bar's `/query` asks it, from its board and its
  selection, and scored by what it leaves selected (c16 narrows three students, "the ones with a beta fish";
  c18 and c19 ask with nothing selected).
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
- `QUERY_VIA=claude-code`: asks through Claude Code (`claude -p`, on your Claude plan) as the app does
  when Settings signs in that way, in the app's own folder, so sign in there first (Settings › Claude ›
  Sign In…); without it, with the key.

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

Haiku 5.5 (`claude-haiku-5-5`: no temperature, 4,096 tokens, effort `high`, no fallback: the
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

The round with the school board (`slash-query-1`, 2026-10-25, Haiku 5.5 at `high`, 324 runs): 320 (98.8%)
first try and after repair, the bar met, every category 100% but "direction", 38 of 42 (90%): e13 ("types
linked to Customer", 2 of 3, written as the relationship types a type has; it missed 1 of 3 in
`relationships-2` too) and one run each of c14 and c19. Before it, the school cases alone found three things
the model didn't know or wasn't told, each fixed and asked again: in a file with types it took every note
for some type's (c15 "UNANSWERABLE: no coach type", c14 plain notes put in Student), so the request tells it
which shapes are of each type and which titled notes are of none (`<instances>`) and the prompt says a note
of no type is found by its words and arrows (c14, c15 and c19 from 1 of 9 to 7 of 9); "the ones with a beta
fish" on a selection ignored the selection (c16 0 of 3), so `/query` on a selection says that only what the
question picks out of the selected is kept (3 of 3); and c01's thinking ran past 2,048 tokens once and was cut
off, so the room is 4,096.

The round with `<connections>` (`connections-1`, 2026-10-29, Haiku 5.5 at `high`, 324 runs): every request now
tells how arrows join the file's shapes, by type, else kind, with counts (Types' `<connections>`, which a rule's
chips needed: "the member's district" went from 0 of 4 to 4 of 4 in `scripts/language-rules/chips_eval.py`), and
the prompt says what it is. 322 (99.4%) after repair, 319 (98.5%) first try, the bar met; "direction" went from 38
of 42 to 42 of 42 (e13, c14 and c19 right every run), and the two misses are s20 ("which subboard is Refund policy
directly in?", `subboard > "Refund policy"`, which missed 2 of 3 in `relationships-2` too), "inside" 37 of 39 (95%).
About 200 tokens more a request (6,986 in, mean).

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
| `id` | `s01`… on the story, `e01`… on the eval board, `f01`… on the fields board |
| `file` | `story`, `eval-board` or `fields` |
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
`00000000-0000-4000-8000-0000000ENNNN` (`QueryEvalBoard.swift`), the fields board's
`00000000-0000-4000-8000-0000000F00NN` (`QueryFieldsBoard.swift`).

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

## The fields board (2026-10-12)

`--ask` is sent a `<fields>` block (a line a type: its fields by key, the name a person gives one in
quotes, its kind) and the prompt teaches what to do with it, so nine cases ask about a note's values,
on a third file, `QueryFieldsBoard.swift` (ids `…F00NN`, `selection` always `-`). Types **Person**
(`name`, which titles it, `email`, `dob` a person calls "birthday"; `name` required) and **Order**
(`number`, `customer` text, `status` draft, paid or shipped, `due` a date, `total` a
number, `lineItems` a list of `product` and `qty`, `gift` yes or no, `giftNote` which a gift asks
for; `number`, `customer`, `status` and `due` required). Notes **Ann Lee** (born 1990-05-02) and
**Bo Park** (2001-11-30); **Order 12** (for Ann, paid, due 2026-10-05, total 18, a Mug and a Pen),
**Order 13** (for Bo, draft, due 2026-11-01, total the text "twelve": wrong, a Mug) and **Order 14**
(for Ann, draft, a gift with no giftNote, no due: incomplete, not wrong); **Standup**, a note that
mentions Ann Lee in its text. Each case's `reference` runs in `./test.sh` with no model.

| id | question | what a wrong query brings in |
|---|---|---|
| `f01` | which orders still need something? | `:invalid`: Order 13 |
| `f02` | which orders have a wrong value? | `:incomplete`: Order 14 |
| `f03` | orders with a Mug line | a path that doesn't go into the list |
| `f04` | orders due before November 2026 | a date compared as text, or a wrong key |
| `f05` | orders for Ann Lee | no `:is-a`, or a mention (Standup) in place of the field's text |
| `f06` | orders for Bo Park | the same, for the other customer |
| `f07` | people born before 2000 | a key guessed from the words (`birthday`, `born`) |
| `f08` | orders with a priority above 3 | UNANSWERABLE, never a made-up `[fieldValues.priority>3]` |
| `f09` | which notes mention Ann Lee? | `:edge-to("Ann Lee", mention)`: the orders come in |

The prompt changed for every question (a `<fields>` line in "You get", the quoted date, a bullet on
`[fieldValues…]`, `:incomplete` and a rule on unknown fields, some 1.8 KB), so the
round that counts is every case, in one go, before the new ones are read: all 79, three runs, Haiku
5.5 at `high`, the bar above (95% after repair, 85% first try, no category under 90%). The nine
join `types` (seven), `unanswerable` and `mentions`. Run on 2026-10-12 with two runs a case (Haiku 5.5 at `high`, the shipped
model), all 79: 158 runs, first try 155 (98%), after repair 157 (99%), failed 1; every category at or
above 89% first try and 96% after repair, and the bar met. The nine new cases passed both runs
first try. The one failure is s20 ("which subboard is Refund policy directly in?"), the few-percent miss
noted above; s12 ("notes that mention TODO") now needs its repair turn (it was 3 of 3 first try
before): it writes `:mentions("TODO")` and is repaired to `:contains`. Not appended to `results.tsv`. Where a case fails: `f07` says whether `<fields>` shows keys first (a guessed
`birthday`); `f05` and `f06` whether a customer's name is asked of its field's text and not of a mention, and `f09` whether `:mentions` is exact; `f03` and `f04` whether the path and the quoted date
are the grammar's; a path no type has is a warning, not a refusal, so a typo is answered
with nothing and the case fails by its set. The earlier rounds' sizes and token counts
above are from the prompt before this one: the system prompt is longer by the lines above, and
the user message by the `<fields>` block (at most 8,000 characters, a few hundred for this board).

## After the pointer went (2026-10-12)

A field that named another note is gone, and so is `field-link` from the prompt and from the two
examples that used it; `f05` and `f06` ask a customer's name of its field's text ("orders for Ann
Lee", "orders for Bo Park"). A lite run, not a full round (the full one comes when the prompt gains
its passage on relationships): `QUERY_RUNS=2 QUERY_CASES=f01,f02,f03,f04,f05,f06,f07,f08,f09,s50,s51`,
Haiku 5.5 at `high`: 22 runs, 22 first try, none repaired, none failed. Not appended to `results.tsv`.

## Relationships (2026-10-13)

The prompt gained its passage on relationships (a relationship is an arrow of a relationship type,
picked by `arrow:is-a("…")` and never by an edge word's second argument; `:end-of` and `:start-of`
for the notes at its ends; a value it holds as a field of the arrow; `arrow:misfit`), `<fields>`
gained a line for each relationship type, and the cases gained `r01` to `r10` on the fields board
(with `f05` and `f06` asked of the Placed by relationship). The round that counts is every case:
all 89, three runs, Haiku 5.5 at `high`, the bar above.

Round `relationships-1`, the passage as first written: 267 runs, first try 254 (95%), after repair
259 (97%), failed 8, and the bar missed on two cases. `r01` to `r09` passed 3 of 3. `r10` ("what can
an order be related to?") failed 3 of 3: the model answered with the people orders are placed by,
where the question asks for types. `s43` ("delete the locked notes") failed 3 of 3 with
`sticky-note[locked]`, and 6 of 6 asked again; with the prompt as it was before this change it failed
2 of 6 the same day (it had been 3 of 3 on 2026-10-08), so the case was already at the edge and the
longer prompt tipped it.

Two changes, then the round again. A rule: a request to change the board is UNANSWERABLE even when
a query could find the shapes it names, with four examples, none the case's own words (`s43` then
6 of 6). Two sentences in the passage: the relationship types a type has
(`sticky-note[relationship]:connected-to("Order", arrow)`), and that what a type can be related to
is a question about types, the types at the far ends of those.

Round `relationships-2`, the prompt as shipped: 267 runs, first try 261 (98%), after repair 264
(99%), failed 3; every category at or above 95% after repair, `types` 63 of 63, `unanswerable` 15 of
15, and the bar met. The failures: `s20` twice (the few-percent miss noted above), and `e13` once
("types linked to Customer" answered as the relationship types of Customer, a reading the new
sentence invites; 2 of 3 are right). `s10`, `s12` and `e05` each needed their repair turn once.
Both rounds are in `results.tsv`.

## `:incomplete` says relationship rows too, and is Validation's (2026-10-13)

The prompt's line for `:incomplete` said fields only. A note whose relationship row an end marks
Needed is incomplete while the row is empty, and the line says so now. A lite run, not a full
round: `QUERY_RUNS=2 QUERY_CASES=f01,f02,r05,r06,s50,s51` (`f01`'s Order 14 is incomplete by its
Needed `customer` row), Haiku 5.5 at `high`: 12 runs, 12 first try, none repaired, none failed.

The same day the word moved to Validation, which keeps what a shape still needs as an issue of
its own level: in `<vocabulary>` it now comes after `:invalid` and `:warned`, summarised "it still
needs something", and the prompt's own text did not change. The same lite run again: 12 runs, 12
first try. Neither is appended to `results.tsv`.

## Subboards and frames of no type (2026-11-04)

A subboard or frame can now be of a type, so `<instances>`'s `Of no type:` lists the titled subboards and
frames of no type as well as the notes, and the prompt says "shape" where it said "note" for those lines
(the `<instances>` line, the field-keys bullet, "Not every shape is of a type", `:incomplete`, the rule on
shapes of no type). Nothing else in the prompt changed. Its test expectation now includes Payments and
Refunds under `Of no type`.

Three cases on the story file, where Payments and Refunds are untyped subboards: s52 "which subboards are
of no type?" (`subboard`), s53 "which subboards are inside Payments?" (`"Payments" subboard`), s54 "what is
Payments?" (`subboard"Payments"`, expected Payments). The story has no typed subboard and no frame, and
neither eval board has one either: a typed subboard or frame needs a fixture on one of the boards, which
this round did not change, so typed ones are not evaluated yet.

Round `subboards-1`, the prompt as shipped, Haiku 5.5 at `high` (the shipped model), 2026-11-04, 333 runs
(every case, three runs): 322 first try (96.7%), 325 after repair (97.6%), 8 failed; every category at or
above 90% after repair (`inside` 95%, `direction` 93%, `titles` 96%, `types` 98%), and the bar met. Its
misses, against `connections-1`, the last full round (322 of 324 after repair):

- `c01`, `c18` and `c19` each missed once (the nested `:edge-from` of c01 and c18, and c19's `"After
  school" > sticky-note:is(...)`). Asked five times more each, `c01` and `c18` passed 5 of 5 and `c19` 5 of 5:
  noise, not the prompt.
- `e13` ("types linked to Customer") passed 1 of 3 in the round and 4 of 5 in the rerun. It is the case
  already noted above as read as the relationship types of Customer (`sticky-note[relationship]:connected-to
  ("Customer", arrow)`). Same day, the previous prompt (`git show HEAD:Shipped/ask-prompt.txt`) asked eight
  times: 7 of 8. Five of eight against seven of eight is not a clear difference at this size; it is the case
  to watch.
- `s54` ("what is Payments?") is new and fails with both prompts: 3 of 8 with the new (2 of 3 in the round,
  1 of 5 in the rerun), 3 of 8 with the previous. It writes `:edge-from("Payments", is-a)`, the types Payments
  is, as "what is Ann?" asks its types (s47); a subboard of no type has no type to be, and nothing in the prompt
  says a shape of no type is itself. Left as a known miss: the prompt's wording is not changed for it here.
- `s20` missed twice, as before; `s12` repaired three times, as in `connections-1`.

Rows are in `results.tsv` as `subboards-1` (the round) and `subboards-1-rerun` (c01, c18, c19, e13 and s54, five
runs each). The previous prompt's eight runs of `e13`, `c01`, `c18` and `s54` were not recorded.

