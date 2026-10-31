# Language rules: the prototype's boards and lite evals

These scripts were the feature's prototype, before it was built, and are its lite evals: real boards drawn in a test copy of the app, the prompt the feature sends for each shape a rule checks (read from the board through `canvas query`), and real answers from Jev (TypeSafe's decision model) and Haiku 5.5, scored against labels. Never run by `./test.sh`; they need the app, the network and both keys. Each is a mise task, `eval:rules` and the `eval:rules:` tasks (`mise tasks`), which runs it as below and asks before Jev or Claude is called.

## Running it

```bash
# a test copy of the app, on a socket of its own (the path must be 103 bytes at most)
./build.sh && open --env CANVAS_SOCKET=${TMPDIR}ic-rules-proto.sock -a "$PWD/build/InfiniteCanvas.app"
export CANVAS_SOCKET=${TMPDIR}ic-rules-proto.sock

python3 -I scripts/language-rules/fetch.py DATA          # Census Reporter, Wikipedia, CRS summaries (Voteview and the EPA's file beforehand)
python3 -I scripts/language-rules/prepare.py DATA BOARDS # cars.json, votes.json: the boards' contents and the labels
python3 scripts/language-rules/boards.py BOARDS build/canvas   # draws Cars and Votes with canvas draw
python3 scripts/language-rules/evals.py --board 2 --labels BOARDS/cars.json --out RUN --haiku 36
python3 scripts/language-rules/evals.py --board 3 --labels BOARDS/votes.json --out RUN2 --haiku 60 --haiku-budget large
python3 scripts/language-rules/score.py RUN > RUN/summary.md
```

- `bills.py`: the 16 House roll calls the votes board draws (118th Congress, final passage).
- `context.py`: what a rule sees: the shape, one step around it (its types and their words, where it is, the shapes beside it, its edges, an arrow's ends and the other arrows of its type at each), shrunk to a budget (`small`: counts by type; `medium`: names; `large`: in full), and each chip's query run through the query engine with `:scope`, `:scope-start` and `:scope-end` written as the shape's id until the language has those words.
- `evals.py`: one variable at a time: `mode` (a question a rule, or the rules read together with a question a rule for which flags it, in one call), `polarity` (the rule worded as what to flag, as stored, or as what should be true), `budget`. Every request and answer goes to `prompts.jsonl`, every verdict to `results.tsv`.
- `score.py`: at the feature's cutoffs (flag at p ≥ 0.7, pass at p ≤ 0.3, unsure between), what each variant caught, missed and falsely flagged, how often it was unsure, and AUC.

Keys: `TYPESAFE_API_KEY` (else its export line in `~/.zshrc`) and the Anthropic key the app's Settings saved (else `$ANTHROPIC_API_KEY`); neither is printed. A test copy of the app reads the same Anthropic key, so it may ask Haiku for a type's highlights as the boards are drawn.

## The boards

- **Cars** (the cascade): Car (year, make, model, mileage; "The mileage is implausible for the car's age."), Toyota built on Car ("This model wasn't made in this year, per [the Toyota lineup]", a chip on a subboard of the 40 Toyota models and their years from the EPA's fuel-economy data), Vintage built on Car ("Mileage doesn't matter for a vintage car." and "It's less than 25 years old."). 36 cars: real model names and years, made-up mileage, 13 planted to break a rule (labels by construction).
- **Votes**: Pennsylvania's 17 House members, 16 bills with CRS or Wikipedia summaries (6 have none: congress.gov's demo key was rate-limited), 262 real votes (Voteview) as arrows of the relationship type Vote, each member pointing to a district subboard of 13 cards (Wikipedia's description; Census figures for 2024 from the American Community Survey, via Census Reporter). Vote carries "Unusual for the member's record." and "Unusual for someone representing [the member's district]" (a chip: `subboard:edge-from(:scope-start) *`). The label for "unusual for the record" is Voteview's own: its spatial model of each member rated the vote under 50% likely (28 of 262). The district rule has no label.

## Round 1, 2026-10-27 (jev-1.14.0 as `jev-latest`; Haiku 5.5 at `medium` effort)

- **Cars, rules a model can check from the board**: Haiku 5.5 caught every planted car with no false alarm in every variant but one. Jev separates well (AUC 0.93–1.00) but leaves many answers between 0.3 and 0.7: the mileage rule caught 3–6 of 5–6, the lineup rule 4–5 of 6, with 0–2 false alarms. Jev missed where the board and the world disagree (a 2023 Grand Highlander: the lineup says its first model year is 2024) and where the check is arithmetic (188,000 miles on a 2024 Camry).
- **Composition** (Vintage's "mileage doesn't matter"): read together, Haiku stopped flagging all six vintage cars (Car's rule alone flagged a 1990 300D with 2.9 million miles). Jev's overall answer respected it (0.18) while its answer for Car's rule alone did not (0.87).
- **A qualifier is no check**: asked alone, "Mileage doesn't matter for a vintage car." flagged 8 of 18 vintage questions on Jev. Read together but worded as "what to flag", Haiku took it as a flag (5 false alarms); worded as "what should be true", it read it right. Rules that qualify other rules need composing and the "should be true" wording.
- **Votes, "unusual for the member's record"**: the lookup "voted against their own party's majority" catches 24 of Voteview's 28 with 22 false alarms of 234. Jev at its best caught 13 of 28 with 23 false alarms (cutoff 0.5); Haiku caught 14 of 28 with no false alarm in a sample of 60. Neither beats the lookup. With the member's other votes shrunk to counts (`small`), Jev can't judge it at all (AUC 0.69).
- **Votes, "unusual for the district"**: neither model commits: Jev's highest answer was 0.55; Haiku flagged 1 of 60 (Brendan Boyle, a Philadelphia Democrat, for the Protecting American Energy Production Act).
- **Prompt bugs found**: Haiku's per-rule answer read "yes" as "meets" while asked "does it fail"; answering in words (`flags`/`clear`, `meets`/`fails`) fixed it. The superseded rows are kept beside the results.
- **Time and cost**: Jev 0.17 s a call (median, 3,000–3,500 input tokens); Haiku 1.8–4.1 s (4,400–11,800). 3,598 Jev calls, 16.1M input tokens (about $0.68 at $0.042 per million); 492 Haiku calls, 3.66M input and 0.25M output tokens (about $5 at Haiku 4.5's list price).

## Round 2, 2026-10-28: the listings (the plan's running example)

`listings.py`: 12 car listings (real years and models; the sellers' words and the mileage written for the example), on a board of their own: Listing built on Car ("The description agrees with the car's year, model and mileage." and "The description mentions no damage or wear."), Vintage built on Car ("Wear and patina are expected on a vintage car."), three listings for vintage cars being both.

- **Words against values is the judgment these models do best**: "agrees with the car's year, model and mileage" caught all 4 listings that contradict their own values ("barely driven" on 412,000 miles, a 2022 Tacoma sold as a 2019, 47,000 miles against 74,000, 2,600 against 26,000) with no false alarm, on Jev (every variant) and on Haiku read together.
- **"Mentions no damage" caught all 3 damaged cars** on both, with one doubtful listing ("the hybrid battery was replaced": Haiku flagged it, Jev unsure).
- **The vintage qualifier did not hold**: read together, both models still flagged the 1967 Mustang ("surface rust") and the 1985 911 ("stone chips"), Jev at 0.89–0.91, Haiku at 1.0. Rewording it ("don't count as damage", "may mention wear and patina") moved Jev to 0.68–0.77 and Haiku not at all. A qualifier shifted a judgment ("implausible mileage", round 1) but not a literal rule ("mentions no damage").
- **Asked again in the right order** (2026-10-28): `lineage` walked a listing's types depth first in their written order, so a Listing and Vintage sent Vintage's rule first, telling the model the more specific rule was Listing's. It now orders them as Types does (C3, the list read latest first). Jev, read together, with Vintage's rule last: the Mustang still breaks one at 0.74 (Listing's "no damage" 0.87, Vintage's 0.07), the 911 at 0.87 (0.95, 0.18), and the Beetle now rings at 0.74, failing the qualifier itself ("wear and patina are expected", 0.71: it was restored, no rust). The finding stands, and grows: a qualifier written as a sentence is checked as a rule. (Three calls by hand with `context.py` and `evals.py`'s Jev request; evals.py's next run orders them so too.)

## Round 3, 2026-10-29: words that find

`chips_eval.py`: ten phrases a person might write as a chip in a rule (on Votes, Cars and Listings), turned into queries by Haiku 5.5 as `translate` would ask (the shipped prompt and its stored-query line read from `Shipped/`, the model and effort from `AskStyle.haiku55`), with a draft line for a query bound to the shape checked (`:scope`, `:scope-start`, `:scope-end`); each answer is run for two sample shapes, `:scope` written as their ids, two runs a phrase. `OUT=DIR VARIANT=connections python3 scripts/language-rules/chips_eval.py 2`.

- **Given the rule's sentence as its subject**, the model tried to write the rule itself and gave up ("a query can't compare…"): 10 of 20 right.
- **Asked for the shapes the words name** (`VARIANT=framed`): 14 of 20.
- **Told how arrows join types too** (a `<connections>` block, `VARIANT=connections`): 16 of 20. Phrases a query can say: 13 of 14 ("the member's district" went from 0 of 4 to 4 of 4). Phrases it can't: 3 of 6 said so, and the other 3 wrote a query that finds nothing. 2 to 10 s a call, 6 s typical, about 11,800 input tokens.
- **Misreads**: "the member's district" read as the member's `district` field (`:scope-start[fieldValues.district]`), and "listings for vintage cars" as a test on the listing checked (`:scope:is-a("Vintage")`). Both are plain once what a chip found is named for two samples.

## Round 4, 2026-10-29: the decision models' Haiku adapter

`decide_eval.py`: the app's `LanguageDecisionModel` (Sources/DecisionModels), its system prompt, model and effort read from the Swift and its message written as `message(for:)` writes it (the state, the rules once as the preface, then the questions numbered, each answered in its own words), asked Haiku 5.5 at `medium` over round 1's and round 2's own Jev requests (the rules read together, worded as what should hold, the `medium` budget), scored beside those rounds' Haiku answers in the prototype's framing. `python3 scripts/language-rules/decide_eval.py RUN OUT`.

- **The same verdicts as the prototype's framing, every one**: cars, 12 of 12 flagged cars caught read together with no false alarm, the mileage rule 5 of 5, the lineup 6 of 6, Vintage's age 1 of 1, none falsely; listings, 7 of 7 read together with the same 3 false alarms (the vintage listings, round 2's finding), "agrees" 4 of 4, "no damage" 3 of 3 with the same 3. Every answer was read (an object, each question in its words). 48 calls, 1.8–2.7 s typical, 1,100–4,100 input tokens.

## Round 5, 2026-10-29: the rules' words as shipped

`rules_eval.py`: the product's `Shipped/rule-prompt.txt`, read as `RulePrompts` reads it, building each request as `request(state:rules:noun:)` does from round 1's and round 2's Jev states (read together, worded as what should hold, `medium`), checked word for word against the round's own request, then asked of Jev and scored beside the round's answers. `python3 scripts/language-rules/rules_eval.py RUN OUT`.

- **Word for word the prototype's**: 12 of 12 listings' requests and 36 of 36 cars' are the round's, preface, questions and answers' words alike.
- **Jev answers as it did**: a question's answer moved a median 0.01 (at most 0.19) from the round's. Listings: the same verdicts on every rule (7 of 7 read together, 2 false alarms; "agrees" 4 of 4; "no damage" 3 of 3, 2 false alarms). Cars: read together 8 of 12 caught where the round caught 7, 4 unsure, no false alarm; the mileage and lineup rules as before but for one unsure each way. 48 calls, 0.18 s typical.

## Round 6, 2026-10-29: the chips' words as shipped

`chips_eval.py` with `VARIANT=shipped` (the default now): the line and the `:scope` words a bound request adds read from `Shipped/ask-bound.txt` and filled in as `BoundWords` fills them in the Swift, the request otherwise as round 3's `connections` variant (`<connections>` sent with every request, as `--ask`'s and a pill's are since landing 4). `OUT=DIR python3 scripts/language-rules/chips_eval.py 2`, against the test app's Cars, Votes and Listings.

- **17 of 20 right** (round 3: 16). Phrases a query can say: 13 of 14; the one miss read "the member's district" as the member itself (`:scope-start`), and its other run was right. Phrases it can't: 4 of 6 said so (the member's party, listings of the same make); "this car's model in the Toyota lineup" wrote a query both times (`"Toyota lineup" sticky-note:is-a("Model")…`), as in round 3. 2.4 to 9 s a call.
- The line under a rule names what a chip found for a sample shape, ‹ › between samples, which is what shows such a misread.

## Round 7, 2026-10-29: the whole House, in the app

`house.py`: every member of the 118th House (Voteview) and how each voted on round 1's 16 bills, a board per state, each member's district a subboard holding its Wikipedia description and 12 Census figures, the bills on the root (public) and each state's votes going into one pill a bill. Census Reporter serves only ACS 2024, drawn on the 119th Congress's lines, so the figures for AL, GA, LA, NC and NY describe their districts as redrawn for 2024, which each of those districts' descriptions says. Vote carries round 1's two rules in its "hold" wording, the district's phrase a chip (`subboard:edge-from(:scope-start, arrow)`). Cars and Listings are files beside it, their rules stored in the shipped form. Everything is drawn with `canvas draw` into this worktree's app and checked by Jev through the app. `python3 house.py fetch DATA`, then `prepare`, `draw`, `rules` and `score`.

- **The board**: 50 states, 443 members, 435 districts, 16 bills and 6,702 votes, 14,547 shapes in all, 13.6 MB on disk. `canvas draw` drew it in 17 s over 486 runs; California's 53 members and 848 votes took 0.52 s.
- **The checks**: every vote was checked 130 s after the rules were written, one Jev call each, none failed. A query took 20–30 ms throughout. Read together, Jev's answers on the votes were 4,100 unsure, 2,584 holding and 49 flagging. 38 votes were warned, all by the record rule; 24 of them are among Voteview's 632 unlikely votes (its model rated them under 50% likely). The district rule warned of none (its own answer flagged 9). Neither rule is one Jev judges from the board, since what they ask is in no shape's words: round 1's finding, at 25 times the size.
- **Cars and Listings**: 7 of 13 planted cars caught, no false alarm. 6 of 7 listings caught, the F-150's 2,600 miles against 26,000 missed, and the 911's stone chips the one false alarm (round 2's).
- **Edits**: changing a vote asked 16 questions (it and the member's other votes, which list it) and settled in 6 s. Changing it back asked nothing, from the day's answers. Changing a district's words asked about its member's 14 votes, through the chip. Moving a member asked nothing. Each write asked all 6,702 chips again in its pass, and Jev about none whose finds were the same.
- **`canvas decide`, live for the first time**: the 12 listings asked "Does the seller mention any damage or wear?" in 0.34 s (the five that do at 0.97–0.98, the replaced hybrid battery at 0.72). Pennsylvania's 262 votes asked "Did the member vote against a bill that passed?" in 4.5 s: 251 right at 0.5, 11 false yes.
- **Found and fixed**: opening the file again asked Jev 6,693 questions it had asked that day. What a rule saw of an arrow listed the arrows beside it in the order Topology filed them, which is the order they came (a commit's in any order, an edited arrow last, an opened file in its boards' order). A state built in another session differed, so the answers kept by the request's hash weren't found. The arrows are now listed by their far end's title, then their id. Opened twice since: the first asked once more for the new order, the second asked nothing and settled in 28 s from the day's answers.
- **Pictures**: `canvas capture`, like Quick Look and Copy as Image, draws from a copy of the file that checks nothing, so a picture carries no rule's warning even with the day's answers on disk.
- **Cost**: about 20,500 Jev calls over the round (three full passes of the votes, `decide`, Cars and Listings).
