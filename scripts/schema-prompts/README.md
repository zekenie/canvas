# Type prompts: quick evals

Whether the two prompts that keep a type's words (a note's text) and its JSON Schema in step, the
one that links the description's words to the schema's parts (Highlights, below), and the one that
fills a note's fields from its words (Filling fields, below) basically do the job. Not a framework: a
script, a CSV of cases, a CSV of results, read by eye.

`evalkit.py` is what the three scripts share, one copy: the key (read from the app's Settings file,
else `$ANTHROPIC_API_KEY`, never printed), reading a prompt's literal and a setting out of the Swift,
the call with its retries, and taking an answer out of a fence or a lone tag's line. Each script keeps
its own request layout, parse rule and scoring, copied from the call it tests.

- `evals.py` runs the cases and appends a row per case to `results.csv` (`pass`, what failed, latency,
  tokens, the output on one line); `results.jsonl` gets everything, and isn't committed.
- `cases.csv` holds the cases (113: 77 prompt → schema, 36 schema → prompt), written by
  `gen_cases.py`, where they're readable. Edit `gen_cases.py`, then run it. Five chains (a hand edit
  surviving a prompt edit, a round trip, two both-ways edits, a rename round trip) are in `evals.py` itself.
- Ten of the cases (`s_ref_…`, `p_ref_…`) name other types, as the app shows them to the
  model: each `@` and a word (`@Address`), listed in `<schemas>` (the case's `schemas`), a mention
  that word in the prompt and a `$ref` to the type that word in the schema. For those, and only
  those, the system prompt has what it says of other schemas after it (`toSchemaReferences`,
  `toPromptReferences`), as `SchemaPrompts.system(_:schemas:)` sends it; every `$ref` to an `@` word must be
  to one `<schemas>` lists, as the app reads them back. Added to every request, the same words
  cost three of the other cases (a snake_case name, a `$ref`'d field marked required, a round
  trip's `required`), which is why they go only where there are other schemas. What the two prompts say
  of a title from a field (`toSchemaTitle`, `toSchemaNewTitle`, `toPromptTitle`) goes after each on
  every request, the plan's "every existing case runs again", so the round below says what that cost.

Nothing the app sends is copied here: `evals.py` reads the system prompts, each direction's
`max_tokens`, what each says of other schemas, the model and its effort out of `Sources/Types/Sync/SchemaPrompts.swift`, and `gen_cases.py` a new type's schema out of
`Sources/Types/Type/TypeSchema.swift`, so the evals send exactly what the app does (a schema written
from nothing is sent with the new type's schema as `previous_schema`, as `TypeSync` sends it). Its
user message and parse rule copy `SchemaPrompts.toSchema`, `toPrompt` and `parse`; when to call and
what's written is `TypeSync`.

A type's name is its note's title, so `cases.csv` has a `name` column and stores each schema without a
root `"title"`, as a type holds it. `evals.py` does what `TypeSync.start` does (`TypeNaming.titled`,
ported in `evals.py`): the name goes in as the root `"title"`, first, in `schema` and `previous_schema`
(unless the stored schema has a title the person typed, which is kept as typed), and what `apply` does
with the answer (`TypeNaming.untitled`): the title comes out of the schema that would be written, and an
untitled note (an empty `name`) is named by it. A case fails when the stripped text isn't a JSON object
without a title, or an untitled note gets no name; a model title that isn't the name sent is a warning
(`title-changed`), since the app takes it out anyway.

## Running it

Run it from this directory:

```sh
cd scripts/schema-prompts
python3 evals.py --check            # reads the prompts and settings out of the Swift, self-tests the checks; no call
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
`SchemaPrompts.swift`, sends each of `highlight_cases.py`'s cases (31, 28 when this was measured: the owner's Jira ticket,
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

`SCHEMA_LIVE=1 build/debug/TypesTests/TypesTests` (after `./test.sh` has built it) runs three
cases, and a type that mentions another both ways, through the app's own path, `AnthropicModel` and `TypeSync`, and prints what came back.
`./test.sh` never sets it.

## Lite round for "Types and new shapes" (2026-10-09)

Haiku 5.5 (`claude-haiku-5-5`) at `medium` effort, the app's own settings. The sync moved from the
schema card to the type note: the note's title goes in as the schema's root `"title"`, the model's comes
out of the answer, an untitled note takes the model's as its name, and mentions of type notes reach the
model as `@Word` with `<schemas>`. The prompts' text didn't change in that build; what's sent did, so
the harness above was changed to send it, and 7 cases were added (`s_untitled_fields`, `s_typed_title`,
`s_injection_in_name`, `s_name_quotes`, `s_name_in_mentions_only`, `p_injection_in_name`,
`p_name_not_in_prompt`).

- Round 20: 32 cases (both directions, the `@` cases, an untitled note, a title typed in the JSON,
  injection in the words, in the schema and in the note's name, Japanese and Spanish) twice each. to_schema
  35/42, to_prompt 22/22. Failures: `s_untitled_fields` and `s_injection_in_name` were script bugs
  (`titlehas` took no `a|b` alternatives; the name itself, which the model rightly kept as the title,
  tripped `title` and `lacks_text`); `s_non_latin` (English property names for a Japanese prompt, twice)
  and `indent` (a one-line schema, `s_ref_new` and `s_name_in_mentions_only`, once each) were the model:
  eight more runs of each with the note untitled, as before the build, failed about a quarter of the
  time too, so not the title's doing, but real prompt slack.
- Prompt fixes: the names rule says "a prompt in Japanese gets Japanese names, never English ones", and
  the format rule says "one member per line, always, however small the schema". 40 runs of the four
  cases after: 40/40.
- Round 22 (all 81 cases twice, and the four chains): to_schema 104/104, to_prompt 56/58, chains 3/4.
  Failures: `chain_roundtrip` step 1 and `p_write_vague_pet` were NO_CHANGE for a prompt written from
  nothing (about 1 in 5 for the vague pet, already failing before the build in rounds 1, 2, 5 and 9);
  `p_write_snake` a prompt of 99 characters against 90 (noise, 10/10 on rerun).
- Prompt fix: the NO_CHANGE option now ends "Never when there is no <prompt>: write one." Sixty runs of
  six cases (the three that write from nothing, and the NO_CHANGE ones) after: all as expected.
- Round 23 (all 81 cases twice, the four chains) with both fixes: to_schema 104/104, to_prompt 58/58,
  chains 4/4.

## Words that read like a preamble (2026-10-09)

`SchemaPrompts.parse` takes the words it replaces (`words:`): a rewrite that begins "Here are", `prompt:` and so
on, or holds a fence or `NO_CHANGE`, is unusable unless those words read so themselves. `evals.py`'s `parse` and
`auto_prompt_checks` mirror it. No prompt text changed, so no live round was run for it.

## The checks, and the self-test

A case's `checks` are lines, `name:argument`, run on the answer once the app's own parse rules have read it.
Listing checks (`props`, `propsexact`, `anyprop`, `count`, `order`) leave out the `$`-keys of a `properties`
object, as `SchemaDocument.fields` does: `$title` is a setting, not a field. `same:` does not, so one that
looks at `/properties` fails on a `$title` added to a type that had none. Added for the types cut:

- `titleis:/ptr=a|b|`: the member's `title` is one of the alternatives (case-insensitive, trimmed); an empty one accepts no title.
- `noprop:/ptr=a|b|c`: none of the keys is a property at `/ptr` (the negation of `anyprop`; a `$`-key is no property).
- `plainref:@Word=n`: n schemas that are exactly `{"$ref": "@Word"}`, not a `contentSchema`'s (`refs:` counts both).
- `titlefrom:key`, `notitle`: `/properties/$title` is `{"x-canvas-from": key}`; there is none.
- `lastkey:/ptr=key`: the last member of the object at `/ptr`, as the answer orders it, is `key`.
- `onlydiff:/p1,/p2`: the answer is the input (its root `title` aside) except at and under the listed pointers.
- `condtests`: every `if` has a non-empty `properties`; `condthen:key=a|b`: some `then` beside an `if` that tests `key` requires one of `a|b`.

Every to-schema answer also gets one check no case names, `pointer-like`: an answer that holds the old link media type
(`text/x-canvas-link`) or a `contentSchema` with a `$ref` fails, whatever the case asks. Nothing in the prompts says a word of
a field that names a note any more, so a model that writes one is writing it unasked.

`python3 evals.py --check` also runs `selftest()`: for each new check, hand-written answers it passes and answers it
fails, so every check is shown able to fail before a model is asked; and reads `cases.csv` to see that every check
named in it is one `run_check` has (an unknown one used to be found only when its case ran). It also reads
hand-written to-prompt answers with `parse` (the ones `SyncTests`' `promptTests` reads with `SchemaPrompts.parse`,
so the two readers are held to the same answers), and scores a remark before a prompt with and without the tags (below).
`highlight_evals.py --check` finds every case's words in its prompt.

## Relationships in the words (2026-10-12, the pointer goes)

A field that named another note (a pointer, `text/x-canvas-link`) is gone from the app, and so from the prompts. The three
references literals (`SchemaPrompts.swift`: `toSchemaReferences`, `toPromptReferences`, `highlightsReferences`) and the
always-sent `toSchemaTitle` changed; nothing else did. What they say now: a word the prompt gives as a part of the thing ("its
@Address", "shipped to a @Address") is a `$ref`, and so is a bare `@` word with nothing said of how the thing relates to it
(the owner's pick, Q2 (b): it embeds as it did); a phrase that relates the thing to the word instead ("is in a @Layer", "belongs
to a @Team", "assigned to a @Person", "works at a @Company", "links to", "points to", "refers to") writes no property at all, and
the words stay word for word through every rewrite; an unclear phrase is a part (as it was), so the lite round below is what says
whether the relationship cases hold. The pointer's cases are gone (`s_link_a`, `s_points_to`, `s_refers_to`, `s_link_list`,
`s_link_and_part`, `s_link_no_pill`, `s_link_dropped`, `p_link_words`, `h_link_pointer`, the `pointer:` and `textcount:` checks);
`s_bare_type` and `s_title_not_plain` are aimed at the `$ref`.

New cases: to-schema `s_rel_in`, `s_rel_belongs`, `s_rel_assigned`, `s_rel_works_at`, `s_rel_links_to`, `s_rel_list`,
`s_rel_and_part`, `s_rel_kept_edit`, `s_rel_ref_stays`, `s_rel_self`, `s_rel_no_pill`, and for a relationship type's own words
`s_reltype_ends`, `s_reltype_vague`, `s_reltype_vague_friend` (its ends are arrows, never properties); to-prompt
`p_rel_words_kept`, `p_rel_no_previous`, `p_rel_nochange`; the chain `chain_relate_stays` (five edits around a standing "is in a
@Layer": after every schema no property for Layer, no `$ref` to it, nothing pointer-like; after the two to-prompt steps the words
still say "is in a @Layer"); highlights `h_rel_no_link`, `h_rel_part_and_rel` (an `@` word nothing points to gets no link).

The round to run is the lite one (a few dozen calls, no more: the 490-call round is not asked for), with the key in the
environment or in Settings, never printed:

    python3 evals.py --check && python3 highlight_evals.py --check          # offline, no key
    python3 evals.py --round 34 --runs 3 --only s_rel_in,s_rel_belongs,s_rel_assigned,s_rel_works_at,s_rel_links_to,s_rel_list,s_rel_and_part,s_rel_kept_edit,s_rel_ref_stays,s_rel_self,s_rel_no_pill,s_reltype_ends,s_reltype_vague,s_reltype_vague_friend,p_rel_words_kept,p_rel_no_previous,p_rel_nochange,s_bare_type,s_ref_new,s_ref_added,s_ref_kept,s_ref_removed,s_ref_roles,s_ref_unlisted_at,s_title_not_plain,s_title_called,s_vague_pet,p_ref_from_nothing,p_ref_added,p_ref_removed,p_ref_kept,p_bare_words
    python3 evals.py --round 34 --runs 3 --chains-only
    python3 highlight_evals.py --runs 2 --only h_rel_no_link,h_rel_part_and_rel,order_roles

Gates: the relation cases (`s_rel_*` except `s_rel_no_pill`, `s_reltype_*`, `p_rel_*`) 3 of 3 runs, and at most one miss in thirty
runs overall, any miss a field the person can delete and never a broken note; `chain_relate_stays` 3 of 3 with no violation in
fifteen steps; `s_ref_*`, `p_ref_*`, `s_bare_type` 3 of 3; every other case in the set as often as in the last round. If a relation
case fails: reword the three literals and run again; then tell the request which types the type is related to (a `<related>`
block); then, for a relationship type's own words only, one more literal; the ladder is built only on a failed gate.

Run on 2026-10-12 (Haiku 5.5 at `medium`, rounds 34 and 35 in `results.csv`): to-schema 65 of 72 runs, to-prompt 24 of 24, the
three highlights 6 of 6 (recall 18 of 18). What missed, and what was done:

- `s_rel_ref_stays` 0 of 3 in round 34, all three `NO_CHANGE`: the case asked for a change, and none is right (a relationship added
  beside a part writes nothing, so the schema is as it was). Its first check is now `nochange_or_same`; 3 of 3 in round 35.
- `s_rel_assigned` 2 of 3 in round 34, the miss an `indent` (formatting, the fields right; `indent` has missed one to three runs a
  round since round 20); 3 of 3 in round 35.
- `s_reltype_vague` 0 of 3: for the one word "employment" the model writes an `employer` field. Nothing tells it that Employment is a
  relationship type, so no rewording of the three literals can fix it: this is the ladder's last rung (one more literal, sent for a
  relationship type's own words only), which needs the type's mark and is built with it. Until then a type called Employment written
  from one vague word gets a field for its other party, which the person can delete. `s_reltype_ends` and `s_reltype_vague_friend` 3 of 3.
- Every other relation case 3 of 3 (`s_rel_in`, `_belongs`, `_works_at`, `_links_to`, `_list`, `_and_part`, `_kept_edit`, `_self`,
  `_no_pill`, `p_rel_*`), `s_ref_*`, `p_ref_*` and `s_bare_type` 3 of 3, `chain_relate_stays` passed twice with no violation.
- `chain_roundtrip` failed at its first step in both rounds: asked for the words of the Order schema from nothing, the model answers
  `NO_CHANGE` (five of five asks). That request is the to-prompt base and titles alone, which did not change here (it failed the same
  way in round 22 and passed in 23 and 33), so it is not this change's; it is open.

## The relationship type's literal (2026-10-12, the ladder's last rung)

`s_reltype_vague` failed 0 of 3 in rounds 34 and 35: for the one word "employment" the model writes an `employer` field, and nothing
in the request said that Employment is a relationship type. The to-schema system prompt now gets one more literal, sent for the words
of a relationship type alone (the shape holds the mark), after the titles and before the references: `toSchemaRelationshipType`
(`SchemaPrompts.swift`). It says the type describes a relationship between two things; that who or what it relates is drawn as arrows,
never a property, however the prompt names them (`@` words, plain words, or one word that implies them); and that its properties are
only what the relationship itself holds (a role, a start date), 2 to 5 for a vague prompt. `gen_cases.py` takes `relationship=True`
and writes a `relationship` column; the `s_reltype_*` cases say so, and `evals.py` sends the literal for them and for no other case
(`--check` holds the order and the cases). The to-prompt direction is told nothing.

The round, with the key in the environment or in Settings, never printed:

    python3 evals.py --check && python3 highlight_evals.py --check          # offline, no key
    python3 evals.py --round 36 --runs 3 --only s_reltype_ends,s_reltype_vague,s_reltype_vague_friend
    python3 evals.py --round 36 --runs 3 --only s_rel_in,s_rel_belongs,s_rel_assigned,s_rel_works_at,s_rel_links_to,s_rel_list,s_rel_and_part,s_rel_kept_edit,s_rel_ref_stays,s_rel_self,s_rel_no_pill,p_rel_words_kept,p_rel_no_previous,p_rel_nochange,s_bare_type,s_ref_new,s_ref_added,s_ref_kept,s_ref_removed,s_ref_roles,s_ref_unlisted_at,s_title_not_plain,s_title_called,s_vague_pet,p_ref_from_nothing,p_ref_added,p_ref_removed,p_ref_kept,p_bare_words
    python3 evals.py --round 36 --runs 3 --chains-only

Gates: the three `s_reltype_*` cases 3 of 3 runs, and every other case of the "Relationships in the words" set as often as in round 35 (the
literal is sent to no other case, so they should not move). If `s_reltype_vague` still fails: reword the literal's second bullet; the
ladder has no rung after this one.

Run on 2026-10-12 (Haiku 5.5 at `medium`, round 36 in `results.csv`): the three `s_reltype_*` cases, three runs each, 9 of 9, so
`s_reltype_vague` is 3 of 3 where it was 0 of 3 (no `employer`, no field for either party). The other two lines were not run again:
the literal is sent for those three cases alone, so every other case's request is byte for byte what rounds 34 and 35 asked.

## The prompts of "Types and new shapes", slice 17 (run 2026-10-12, a lite round; its pointer has since gone, see above)

The prompts: a rename keeps the field's key and puts the
new name in its `"title"` (and the words are written by that title); a pointer (`text/x-canvas-link`) is written for
"a link to", "points to" and "refers to" a `@` word, and a bare `@` word stays the type; a `$title` (`{"x-canvas-from":
key}`, last in `properties`) is written for "called by" and for a new type whose first field is plainly its name; an
`if` names its field under its own `properties`; the highlights' guide knows a field's title and that a `$` property
is no field. Words that are JSON never reach any of these (`TypeSync`).

New cases (32): renames (`s_rename` and `p_rename` changed on purpose: the key stays; `s_rename_titled`, `_nested`,
`_vs_new`, `_required`, `p_rename_key` (the old `p_rename`), `p_titles_from_nothing`), pointers (`s_link_a`,
`s_points_to`, `s_refers_to`, `s_bare_type`, `s_link_list`, `s_link_and_part`, `s_link_no_pill`, `s_link_dropped`,
`p_link_words`, `p_bare_words`), a title from a field (`s_title_*`, `p_title_said`, `p_title_silent`), a customer
profile of 60 fields in three levels (`s_big_*`, `p_big_one_change`, `BIG60` in `gen_cases.py`), two conditions
(`s_if_names_field`, `s_if_edit_value`), the chain `chain_rename_roundtrip`, and three highlight cases
(`h_link_pointer`, `h_renamed_title`, `h_title_directive`).

The round to run, which counts as one before the new cases count: all 113 cases and the five chains, three runs
(`--runs 3`); all 31 highlight cases, two runs. The cases most likely to move: `s_vague_pet`, `s_vague_recipe`,
`s_vague_plant` (a `$title` appears; the listing checks skip it), `s_precise_two`, `s_precise_contact` (a precise
prompt must get no extra field), `s_defs`, `s_ref_added`, `s_ref_kept`, `s_ref_roles` (the pointer text beside the
plain `$ref`), `s_conditional`, `s_big_add`, `s_huge_add`, `s_non_english`, `s_non_latin`, `s_title_rename`,
`s_make_required` (`same:/properties` breaks on a field `title` or a `$title` added unasked), `s_change_type`.
If the always-sent titles cost old cases, as the references did, the fallback is to send `toSchemaNewTitle` only for a
schema with no properties and the others only when the words or the schema say `$title` or "called"; that needs the
owner's word, as the plan says "every request". Prompt fixes go in `SchemaPrompts.swift`, and this section gets
the rounds, as the earlier ones have.

Run on 2026-10-12 (Haiku 5.5, rounds 24 to 29 in `results.csv`), a lite round: every to-schema case twice
(153 of 154), every to-prompt case three times (103 of 108), the 31 highlight cases twice (recall 390 of 396,
98.5%; misattributed 2, extra 2), no chains. The always-sent titles cost no old case. Failures:
- `s_link_dropped`, 3 runs of 7: the answer is right (the pointer is gone) but written on one line, so `indent`
  fails. A one-line schema from the model is an old miss (`s_ref_new`, `s_name_in_mentions_only`); the app does
  not re-indent an answer.
- `p_write_simple` (3 of 6 passes on the base commit a79fe105 too), `p_bare_words` and `p_link_words`: when the
  prompt is written from nothing the model sometimes opens with a remark ("There is no <prompt>, so I write one.
  Fields: ...") that becomes the type's words. This is not from the titles: the base commit's `p_write_simple`
  fails 4 of 6 the same way, and earlier rounds passed it only by luck at one or two runs. An added "reply is the
  prompt alone" bullet made `p_bare_words` worse (4 of 6 failed), so none is kept. Words that are JSON now reach
  this path (they become the schema and the words are written from it), so it is more often met than before.
- `p_long_small_change` (keeps 0.89, once) and `p_write_refs` (content, once): single misses.

## The words answered in tags (2026-10-12; run)

The remark that opens a prompt written from nothing is no longer asked away, which the round above showed makes it
worse. The words are answered in tags, and the app reads only what is inside them.

- The prompt. `toPromptSystem`'s first answer was "The updated prompt: the text alone. No quotes around it, no
  preamble, no explanation, no markdown." It is now "The updated prompt, inside <answer> and </answer>. What is
  inside the tags becomes the user's prompt as it is: the text alone. No quotes around it, no preamble, no
  explanation, no markdown." Nothing else in either prompt changed; the schema is answered bare, as before, and the
  highlights are untouched.
- The tag is `<answer>` (`SchemaPrompts.answerTag`), not `<prompt>`: `<prompt>` is the request's own block, the
  system prompt says "no <prompt>" of a request without one, and the remark says it after it ("There is no <prompt>,
  so I write one"), which a reader of `<prompt>` tags would take for the answer's opening tag.
- The reader (`SchemaPrompts.parse`, `tagged`; `parse` and `tagged` here): the words are the text inside the last
  complete pair, trimmed and unwrapped as an answer always was; an opening tag never closed takes what follows the
  last one; an answer with no opening tag is read whole, as before, so an untagged answer is no worse off than it
  was; `NO_CHANGE` is judged outside the tags by the old rule (the first word or the last line of what is around
  them) and inside them (the model may tag its second answer as it does its first); tags with nothing in them are an
  unusable answer, whatever is around them. A remark that only mentions `NO_CHANGE`, before a tagged prompt, is
  neither `NO_CHANGE` nor part of the words.
- The script. It reads the tag's name out of the Swift and stops if `toPromptSystem`, and it alone, doesn't ask for
  it. A case's checks run on the prompt as the app would write it, so a tagged answer with a remark passes `maxlen`
  and `lacks`, and the same answer untagged still fails them: `selftest()` shows both. No case changed. An answer
  read as a prompt gets a warning when it had no tags (`untagged`) or said something around them (`remark`): in
  `results.csv`'s `failed` as `warn:untagged` or `warn:remark`, never a failure, and counted in the line under the
  to_prompt summary, which is how often the model uses the tags and how often they kept a remark out.

No model has been asked with this prompt: the round is the lead's to run, and the next is 30. The cases that write
from nothing, six runs each (the three that failed about half the time, and the seven others that take the same
path):

```sh
python3 evals.py --round 30 --only p_write_simple,p_bare_words,p_link_words,p_write_nested,p_write_vague_pet,p_write_snake,p_write_opened,p_write_refs,p_ref_from_nothing,p_titles_from_nothing --runs 6
```

Then every to-prompt case, since the reply's format changed for all of them: the five that must answer `NO_CHANGE`
(`p_vague_remove`, `p_formatting_only`, `p_description_only`, `p_name_not_in_prompt`, `p_title_silent`) are the ones
to watch, for a `NO_CHANGE` the tags turn into a rewrite, and the edits for the user's words kept (`keeps`,
`growmax`). The chains go through the same reader:

```sh
python3 evals.py --round 31 --only p_add_field,p_remove_field,p_make_required,p_made_optional,p_change_type,p_add_pattern,p_add_enum,p_either_or,p_rename,p_vague_add_detail,p_vague_remove,p_formatting_only,p_description_only,p_nonenglish,p_injection_in_schema,p_long_small_change,p_big_add,p_injection_in_name,p_name_not_in_prompt,p_ref_added,p_ref_removed,p_ref_kept,p_rename_key,p_title_said,p_title_silent,p_big_one_change --runs 3
python3 evals.py --round 32 --chains-only
```

What to read in them: the pass rate of `p_write_simple`, `p_bare_words` and `p_link_words` against about half
before; the `untagged` count (an untagged answer with a remark is the old failure, unchanged); and whether any
answer puts `NO_CHANGE` beside a tagged prompt.

Run on 2026-10-12 (rounds 30 to 33, Haiku 5.5): the ten cases that write from nothing, six runs each, 59 of 60
(`p_write_refs` once, on its content); the other 26 to-prompt cases, three runs each, 78 of 78, the five NO_CHANGE
cases among them; the chains 4 of 5 then 5 of 5 (`chain_roundtrip`, which has failed in rounds 5, 6 and 22 too).
Of 126 prompts read, none came without `<answer>` tags and none had a remark around them: asked for tags, the
model stopped writing the remark at all. `p_write_simple`, `p_bare_words` and `p_link_words` were 18 of 18, against
about half before.

## A schema sent alone (2026-10-12; run)

`chain_roundtrip` failed at its first step ("step1 no prompt") in rounds 5, 6, 22 and 32, and five times in a row
on 2026-10-12: the whole answer was `NO_CHANGE`, which leaves a type's words empty. Two things were wrong, and the
first hid the second.

- The chain. Its first step sent the schema alone, no `<prompt>` and no `<previous_schema>`, for words that are JSON
  made a type. The app doesn't send that for them: `TypeSync` says the pair was those words over `{}` (`adopt`,
  `changed`), so the request has `<previous_schema>` with `{}` in it (`{ "title": "Pet" }` for a note with a name).
  The step sends that now, `JSON_WORDS_OVER`, read out of `TypeSync.swift` (the script stops if `TypeSync` no longer
  gives a `TypeSyncSides` one such schema as a literal). Asked eight times a form, with the prompt as it was: the
  schema alone, 0 of 8 prompts for the order and for the pet (`PET`), 8 of 8 for the contact, which is the prompt's
  own example; with `{}`, with the name alone and with a new type's schema as `<previous_schema>`, 8 of 8 each.
  Round 40 is the chains with the step fixed and the prompt as it was: 5 of 5 (no round was numbered 34 to 39).
- The prompt. The app can still send a schema alone: for a type it first saw (a file opened, an agent's write) with
  no words and a blank schema, once its JSON is typed in the panel, since a blank block is left out of the message.
  `toPromptSystem` said "Never when there is no <prompt>: write one." and Haiku answered `NO_CHANGE` all the same.
  It now says it in two places. The `<prompt>` line ends "When it's missing there is no prompt yet: you write the
  first one, whatever else you get." and the `NO_CHANGE` option ends "Never when there is no <prompt>: there are no
  words yet, so the answer is a prompt, never NO_CHANGE." Nothing else changed. On the schema alone, order and pet:
  the first sentence only (worded "there are no words to keep, so you write the first prompt, and the answer is
  never NO_CHANGE"), 2 of 8 and 4 of 8; the second only (worded "so write them, with or without a
  <previous_schema>"), 6 of 8 and 0 of 8, two of the pet's a `NO_CHANGE` and then a tagged prompt, which is read as
  `NO_CHANGE`; both, 20 of 20 and 20 of 20 (the contact 8 of 8); both, with the second begun "With no <prompt> there
  are no words yet" in place of "Never when there is no <prompt>:", 12 of 12 and 8 of 12, so the "Never when" stays.
  `promptTests` pin the two sentences.
- `chain_roundtrip` also asks for the words of the order's schema and the pet's sent alone, and fails if either
  answer is no prompt.

Run on 2026-10-12 with the prompt as it is now (Haiku 5.5, `claude-haiku-5-5`, at `medium` effort; rounds 41 to 45):
every to-prompt case three times, 108 of 108 (96 prompts read, none without `<answer>` tags, one with a remark
around them, `p_ref_kept`; the other 12 answers the `NO_CHANGE` of `p_description_only`, `p_formatting_only`,
`p_name_not_in_prompt` and `p_title_silent`, three each); the five chains three times
(rounds 42 to 44), 15 of 15, the schema alone 6 of 6 in them; a sample of thirteen to-schema cases three times
(round 45: `s_vague_pet`, `s_precise_contact`, `s_nested_object`, `s_conditional`, `s_rename`, `s_remove`,
`s_make_required`, `s_non_latin`, `s_ref_new`, `s_link_a`, `s_title_called`, `s_already_matches`, `s_garbage`),
38 of 39, `s_link_a` once on `indent` (a schema on one line, the old miss; the to-schema prompts did not change).
The schemas that came back were not meta-validated (no `_pylib`).

## Filling fields (2026-10-21; run)

`fill_evals.py` evaluates `FieldFill`'s one call: a note of a type has its fields filled from its words. It
reads the system prompt, `maxTokens`, the model and its effort out of `Sources/Types/Sync/FillPrompts.swift`,
lays the user message out as `FillPrompts.request` does (`<fields>`, `<values>`, `<today>`,
`<previous_words>` when there are some, `<words>`), and reads and writes the answer as `FillPrompts.parse` and
`FieldFill.apply` do: a JSON object of the changes, a member no field names passed over, a group set member by
member, a list whole, `null` taking a value away, empties not kept. Each case in `fill_cases.py` says, for the
fields it is about, what the note may hold after (text compared loosely, or none); every other field must hold
what it held. `--check` reads the Swift and self-tests the scoring, with no call.

```sh
python3 fill_evals.py --check
python3 fill_evals.py                     # 24 cases, three runs each
EVAL_EFFORT=low python3 fill_evals.py     # another effort than the app's
```

The cases: the owner's own note ("purpose is to be a foobar really good foob"); a task's purpose, status from
"already started" and an estimate from "about 3 days"; words that say nothing; a contact with no phone given; a
date from "due Friday" and one with no year, a time stamp, a yes or no from "not urgent"; a choice the field
doesn't list, words for a number, a field called by its title; a group, a list, Spanish, a mention read as its
name, two of eight fields; an injection; and seven edits with words before: a value added beside one typed by
hand, one taken away, one taken away that was typed by hand since (it stays), one changed, words read whole over
a value they contradict, values already held, and an edit that says nothing new.

Round 1, Haiku 5.5 (`claude-haiku-5-5`), 24 cases × 3 runs:

| effort | right | p50 | max |
|---|---|---|---|
| `low` | 71/72 | 977 ms | 7,676 ms |
| `medium` | 72/72 | 914 ms | 2,090 ms |
| `medium`, again | 72/72 | 922 ms | 1,975 ms |

`low`'s one miss left an owner the edit took out of the words (`edit_removes`, answered `{}`). `medium` was right
every time, no slower at the median and with a shorter tail, so the fill ships at `medium`, as the sync does.
