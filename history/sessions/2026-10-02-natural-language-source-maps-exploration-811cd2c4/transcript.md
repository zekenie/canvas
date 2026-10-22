# Natural language source maps exploration

Claude Code session `811cd2c4-f739-4115-b60b-76fca163ff38`, 2026-10-02 22:58 to 2026-10-06 21:33 UTC, on `claude/nl-source-maps-exploration-c42408`, `main`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-02 22:58] USER:
I'd like you to study the highlights system we have in types. I think it begs for a larger abstraction of "natural language source maps". Not asking you to do this work, just to ponder it and consider what that might look like.

it could map to more than just json schema. it basically maps NL => something lower level (like source code but not just source code)

[2026-10-02 22:58] ASSISTANT:
Reading the highlights code (SchemaHighlights, SchemaHighlighter, the prompt) and the docs' "Not built yet" before writing up thoughts.

[2026-10-02 23:00] ASSISTANT:
The highlights code already contains most of a general "natural-language source map". The JSON Schema part is only one target language plugged into it.

## What the highlights system is, without the JSON Schema

There are seven pieces:

1. **A pair of texts kept in step.** One is the natural-language description, the other is the lower-level artifact. Highlights are only asked for once `SchemaSync` says the two agree.
2. **Links.** Each link is some words paired with an address: `(words, JSON Pointer)`.
3. **Source-side anchoring by quotation, not position.** `SchemaHighlights.anchor` finds the words again in the text as it is now. It goes in order, never overlaps, and prefers whole words and exact case. That's why highlights survive typing around them.
4. **Target-side anchoring by meaning, not position.** A pointer is resolved against the schema as it is now, so reformatting doesn't break it. If the part is renamed or removed, the link drops.
5. **The target language gives the link its meaning; the model doesn't.** `kind(of: pointer)` decides field vs. rule deterministically, and so the color. The fragment, its dedent and following a `$ref` to another card are also the language's job. The model only supplies the correspondence.
6. **An exact source map is already nested inside.** `SchemaModelText.shownRange` ([SchemaReferences.swift:187](Sources/Schemas/SchemaReferences.swift:187)) is a classic positional map between what the model reads (`@Address`) and what's drawn (a pill). `modelSchema` does the same for `urn:uuid:` ↔ `@Word`. So the system already composes a deterministic map with an inferred one.
7. **Derived and content-keyed.** Answers are kept by the pair's text, process-wide, never saved and never part of undo. Each card's last answer is kept so highlights hold steady while you type.

## Why this isn't a classic source map

A compiler writes its source map alongside its output, at exact positions. Any regeneration replaces the map, and nobody hand-edits the generated code.

Here both sides are edited by people, and the map is inferred after the fact. So positions would go stale the moment someone typed. Both ends have to be re-anchorable instead:

- **Source side:** quotes, like the W3C Web Annotation "text quote" selector.
- **Target side:** a semantic address in the target language.

**That robustness strategy is the actual abstraction.** It's generic on the natural-language side and language-specific on the target side.

## What the general version might look like

```swift
protocol LoweredLanguage {
  associatedtype Artifact                 // schema text, a query, a draw script, a board
  associatedtype Address: Hashable        // JSON Pointer, syntax path, statement title, ShapeID
  associatedtype Role                     // field/rule; kind/filter/relation; shape/edge
  static func resolve(_: Address, in: Artifact) -> Resolved?   // range, role, fragment, follow
  static func forModel(_: Artifact) -> (text: String, back: ExactMap)  // the @Word trick
  static var linkingGuide: String         // the language's half of the prompt, with examples
}
struct Link<A> { var quote: String; var address: A; var provenance: Provenance }
enum Provenance { case authored, emitted, inferred, derived }
```

The four provenances unify things the app already has:

- **Authored:** a mention is a hand-made source map into the board.
- **Emitted:** the model writes the links in the same call as the target, the way a compiler writes its `.map`.
- **Inferred:** today's highlights, made in a separate call after the fact.
- **Derived:** exact transforms, such as `$ref` ↔ mention.

## Other targets in this app

- **`canvas query --ask`:** a question becomes a query. Every node of the parsed query already knows its place in the text (`QuerySpan`). A generated query never gets edited, so plain positions are fine here. **Whether a target gets edited decides whether its addresses must be semantic.**
- **Draw scripts, by composition:** a request's words map to statements, and statements map to the shapes they made (draw already reports rows by line and title). Composing the two lights up which shapes on the canvas came from which words. Composing maps is the classic source-map operation.
- **The board itself:** arrow labels are already listed in "Not built yet" for highlights. Notes and frame titles could map to the shapes they talk about: mentions without the `@`.
- **Extraction ("schemas that type other shapes"):** a note's text becomes a structured instance of a schema, and each extracted value cites its words.
- **Outside the app:** code addressed by symbol or syntax-tree path rather than line numbers, plus SQL, regexes and config.

## What it would buy beyond coloring

- **Coverage is the diff between intent and implementation.**
  - Parts of the schema nothing links to are fine print the description doesn't say.
  - Words that link to nothing either do nothing or are intent that got dropped.
  - For `--ask`, an unl […1920 more chars]

[2026-10-06 17:21] USER:
/compact

[2026-10-06 17:23] COMPACTED:
(the context was summarized here)

[2026-10-06 17:23] USER:
i need this more scoped out and simplified. i believe we will be using this all over the place. like i want to build tools that map natural language to something lower level (code, json schema, data, etc). i want a solid api proposal that i can quickly process

[2026-10-06 17:33] ASSISTANT:
I've cut it down to a three-part core plus one service. A map is a list of (words, address) pairs, and both are found by content in the two texts. Your tool produces the lower-level text however it likes; the map then says which words describe which part of it.

```swift
// ProseMaps: a horizontal on LanguageModels, with no extension point.

protocol ProseTarget {                         // what prose maps into: code, a schema, JSON data, a query
    associatedtype Address: Hashable & Sendable & LosslessStringConvertible = String
    static var name: String { get }            // "code", "schema": the model's word for it
    static var guide: String { get }           // what an address is, what's worth linking, one example
    static func locate(_ addresses: [Address], in target: String) -> [Range<String.Index>?]
    static func role(of address: Address) -> LinkRole
}
// Defaults: an address is a quote of the target, found only where it occurs exactly once; role is .element.

enum LinkRole { case element, rule }           // pale blue, pale amber, the same for every target

struct ProseLink<Address> {                    // what the model answers
    var quote: String                          // the prose's words, exactly
    var address: Address                       // the part of the target they describe
}

struct ProseMap<Target: ProseTarget> {         // links placed on one pair of texts
    let prose: String, target: String
    let links: [Placed]                        // in prose order, never overlapping; links that don't place are dropped
    struct Placed { var link: ProseLink<Target.Address>; var inProse, inTarget: Range<String.Index>; var role: LinkRole }
    init(placing: [ProseLink<Target.Address>], prose: String, target: String)
    func link(at: String.Index) -> Placed?            // hovering the words
    func links(atTarget: String.Index) -> [Placed]    // hovering the target
    func excerpt(of: Placed) -> String                // the target's part, dedented, for a popover
}

extension ProseMaps {
    // This pair's map; else the shape's last answer placed on this pair; else nil.
    // Static and main-actor, so a render can read it. Reading a pair with no answer asks for one.
    static func map<T: ProseTarget>(_: T.Type, of shape: ShapeID, prose: String,
                                    target: String, context: String = "") -> ProseMap<T>?
}

final class ProseMapService {                  // editor.proseMaps
    func hold(_ shape: ShapeID)                // no asks while one side is being rewritten (the schema sync)
    func release(_ shape: ShapeID)
    func revision(of shape: ShapeID) -> Int    // observed; changes when the shape's map lands
    func ask<T: ProseTarget>(_: T.Type, prose: String, target: String, context: String = "")
        async throws(LanguageModelError) -> ProseMap<T>    // ask now, for a command or a test
}
```

A new target is usually just a name and a guide:

```swift
enum SwiftSource: ProseTarget {                // a new tool: quotes as addresses, so nothing more
    static let name = "code"
    static let guide = "…"
}

enum SchemaTarget: ProseTarget {               // Schemas: today's highlights
    typealias Address = JSONPointer            // gains LosslessStringConvertible
    static let name = "schema"
    static let guide = …                       // today's highlightsSystem, minus the shared rules
    static func locate(…)                      // parse with JSONReader once, resolve each pointer
    static func role(of p: JSONPointer) -> LinkRole   // SchemaHighlights.kind: field → .element, else .rule
}
```

**Decisions**
- **Targets are text.** Everything on your list is text. Mapping words to shapes on a board is a different problem, because there's no text to quote.
- **Anchored by content on both sides, never by offsets.**
  - An edit elsewhere keeps a link. An edit that removes the link's words or its part drops it.
  - So a shape's last map can stand in on edited text until the new answer arrives.
  - A misquoted or ambiguous address drops rather than landing in the wrong place.
- **Recovered after the fact, not written by the generating call.**
  - The map comes from its own model call once the target exists, whoever wrote the target.
  - Your tools' prompts stay their own, and the map is an independent check on them.
- **The prompt splits in two.**
  - ProseMaps owns the task, the answer format (`[{"text", "address"}]`) and the rules: copy words exactly, fewest words, no overlaps, in order, `[]` when nothing links, and leave a link out when unsure.
  - Each target owns its `guide`.
  - `context` carries what one pair needs beyond that, such as the cards its `@Word`s name. It's sent only when it isn't empty, so other requests stay exactly as they are today.
- **Derived, never saved.** Maps aren't in the file and aren't undo steps. Answers are cached process-wide by target, text pair and context.
- **Asked lazily, with a cap.** This is today's h […1382 more chars]

[2026-10-06 18:00] USER:
need help understanding

[2026-10-06 18:00] ASSISTANT:
A prose map is a list of pairs: these words go with this part of the lower-level text (a schema, code, a query).

Say a schema card's description reads "A person with a name and a short bio, at least 18." The model reads that and the schema, and answers:

- "name" → `/properties/name`: a field, so blue
- "bio" → `/properties/bio`: a field, so blue
- "short" → `/properties/bio/maxLength`: a rule, so amber
- "at least 18" → `/properties/age/minimum`: a rule, so amber

That list is the map. The app finds the words in the description and the part in the schema, colors the words, and shows that part of the schema when you hover over them. That's today's highlights. The proposal only makes JSON Schema one target among many.

Everything else in the proposal does one of three jobs:

1. **Asking.** It makes one model call per pair of texts, in the background and only for what's on screen. It keeps the answers, so the same pair is never asked twice.
2. **Finding both ends again.** Each link is found by its text, not its position, so edits elsewhere don't break it. A link whose words or part get deleted just disappears. That's also why a card's old map can keep showing while you type.
3. **Supporting different targets.** Each target says what an address looks like. JSON Schema uses JSON Pointers. Code by default uses an exact snippet of the code, so a new target needs no parser.

Building a new tool, say description → Swift, takes two steps:

- **Define the target:** a name (`"code"`) and a paragraph telling the model what to link.
- **Read the map where you draw:** call `ProseMaps.map(...)` with the description and the code. You get the map if one exists. If not, it's requested and the view redraws when it arrives.

One extra rule: while your tool is regenerating one side, `hold` that shape. The two texts don't agree yet, so a map of them would be wrong.

Which part is still unclear?

[2026-10-06 18:02] USER:
i think this makes sense, and it would support the current feature?

[2026-10-06 18:03] ASSISTANT:
Yes. Every part of today's feature has a place in the proposal, and the schema card would behave the same.

| Today | With ProseMaps |
|---|---|
| `SchemaHighlights.anchor` / `place` | the core's placement, same logic |
| `SchemaHighlightAnswers`' cache and each card's latest answer | `ProseMaps.map`'s cache |
| `SchemaHighlighter`: 4 calls at once, failures kept until a new key | `editor.proseMaps` |
| asking only once `SchemaSync.isInStep` | the sync holds a card until it's in step |
| `kind(of:)` sorting links into field or rule | `SchemaTarget.role(of:)` |
| `highlightsSystem` | shared rules + `SchemaTarget.guide` |
| `highlightsReferences`, only for cards that name others | `context` |
| `@Word` text, pills, line rects, popovers, following a `$ref` | stay in Schemas |

The cache key doesn't change in effect. The text the model reads is still built from the stored texts, with each mention as the label it holds, so the same card asks the same questions as today.

The port needs care in three places:

1. **The prompt text moves around.** It gets split into shared rules and the schema guide, and `"pointer"` becomes `"address"`. So the highlight evals have to be rerun, and the port is done when they still hold (356 of 358 links found, none misattributed).
2. **Broken JSON.** While someone is mid-edit in the panel, today's highlights use the schema's last valid reading. Schemas has to pass that last valid text as the target, or the highlights disappear while they type.
3. **Frame cost.** Today each card keeps its placed highlights, so drawing never re-parses the schema. The generic read has to keep the same per-card copy (by shape, texts and answer) to keep frames as cheap.

Want me to start the port?

[2026-10-06 19:17] USER:
yes

[2026-10-06 19:18] GIT:
git status --short | head; git log -1 --format='%h %s' HEAD; git log -1 --format='%h %s' main; git merge-base HEAD main | cut -c1-8; git log --oneline HEAD..main | head -20

[2026-10-06 19:19] ASSISTANT:
Bringing this worktree up to date with main before porting, since main has moved about 30 commits since this branch was cut.

[2026-10-06 19:19] GIT:
git merge --ff-only main 2>&1 | tail -3 && git log -1 --format='%h %s' HEAD && git status --short | head

[2026-10-06 19:19] ASSISTANT:
On the latest main now. I'm reading the new layer rules and the schema-card docs before I write the ProseMaps module.

[2026-10-06 19:19] ASSISTANT:
Still reading. I'm going through the highlight prompt, the code that asks the model and the popovers, to work out exactly where the shared part ends and the schema-only part begins.

[2026-10-06 19:25] ASSISTANT:
I'm reading how editor services and overlays get registered, so the new module plugs in the way LanguageModels does.

[2026-10-06 19:25] ASSISTANT:
I've mapped where highlights touch the render, the description editor, the plugin and the sync. Next I'm reading the `@Word` translation code and the highlight tests that will need porting.

[2026-10-06 19:32] ASSISTANT:
I've checked the test helpers. Now I'm writing the ProseMaps sources: the target protocol, the map, the shared prompt, and the service.

[2026-10-06 19:33] ASSISTANT:
ProseMaps' types and shared prompt are written. Next is the service that asks the model, caches answers and keeps each shape's latest map.

[2026-10-06 19:35] ASSISTANT:
The new module is wired into the module graph. I'm compiling it on its own now to catch errors before porting Schemas.

[2026-10-06 19:37] ASSISTANT:
ProseMaps compiles on its own. Now I'm porting Schemas: schema highlights become a `SchemaTarget` plus a small per-card memo, and the old highlighter goes away.

[2026-10-06 19:38] ASSISTANT:
Shipped list updated. Now porting the schema tests that used the old highlighter.

[2026-10-06 19:40] ASSISTANT:
Schema tests are ported. Next is the shipped plugin report that CompositionTests pins, then a full build.

[2026-10-06 19:41] ASSISTANT:
Everything builds with warnings as errors. Running the schema tests now.

[2026-10-06 19:42] ASSISTANT:
All 234 schema tests pass. Now I'm writing ProseMapsTests: placement and prompt/answer tests, plus service tests driven by real frames on fixture shapes.

[2026-10-06 19:44] ASSISTANT:
I'm writing the service tests now: asking once per pair, readiness, the cases where nothing is asked, the stand-in while typing, failures, the four-call cap, board switches and forgetting.

[2026-10-06 19:45] ASSISTANT:
All 16 new ProseMaps tests pass, along with the 234 schema tests. I've started the full suite in the background and am updating the docs and the eval script meanwhile.

[2026-10-06 19:45] ASSISTANT:
Now updating the eval script so it builds exactly the request the app now sends.

[2026-10-06 19:46] ASSISTANT:
Two failures. One is expected: the guide's copy of the registry report, which I'm about to update. The other is in PortEdgesTests, which this change doesn't touch, so I'm checking whether it's flaky.

[2026-10-06 19:47] ASSISTANT:
Updating the guide now: a Prose maps section after Language models, the layer table, the schema card passages and the report block.

[2026-10-06 19:49] ASSISTANT:
The guide is updated. Next: a ProseMaps topic file, the CLAUDE.md map, and the layer and schema-card topic files.

[2026-10-06 19:49] WRITE .claude/worktrees/nl-source-maps-exploration-c42408/.claude/rules/prose-maps.md:
---
paths:
  - "Sources/ProseMaps/**"
  - "Tests/ProseMapsTests/**"
---

# Prose maps

Prose maps: which words of a text in plain words say which part of a text in a lower language (a JSON Schema, code, a query, data), asked of the model; targets, maps, the service, the request, and their tests.

Related: [language models](language-models.md), [schema cards](schema-cards.md), [drawing](drawing.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Prose maps](../../docs/plugin-system.md#prose-maps).

## Architecture

- ProseMaps (a surface on LanguageModels that declares no extension point; `docs/plugin-system.md`, "Prose maps") says, for any plugin that keeps a text in words beside a text in a lower language, which words say which part, as a source map does: a schema card's highlights are its description mapped into its schema (Schemas' `SchemaTarget`). A map is a list of links, each the words as the prose writes them and an address in the target, both ends found by what they are in the texts as they are now, never by a position (words typed around a link keep it; a link whose words or part are gone drops). The model says the links in a call of its own, once the target exists, whoever wrote it, so a map checks what made the target rather than restating it; nothing is saved, nor an undo step.
- A target (`ProseTarget`) is a type with no value, its language's plugin's: `name` (the model's word for it and its block's tag, "schema") and `guide` (what  […5317 more chars]

[2026-10-06 19:50] ASSISTANT:
The old prompt's baseline just finished: 378 of 380 links found, none pointing at the wrong part. Reading the new prompt's results now.

[2026-10-06 19:51] ASSISTANT:
The new prompt is consistent on all but one link: "each cell" in the matrix case is missed in 3 of 4 runs, against 0 of 2 for the old prompt. I'm looking at why before changing any wording.

[2026-10-06 19:51] ASSISTANT:
The new "leave them out when you can't tell" rule looks like the cause: the model drops "each cell" and links "number" to the inner items instead. I'm taking the rule out and rerunning to confirm.

[2026-10-06 19:54] ASSISTANT:
Both suites pass with the final prompt. Starting the full test run again in the background while I read through the diff.

[2026-10-06 19:54] ASSISTANT:
Staged. I'm reading the service file in full before committing.

[2026-10-06 19:54] ASSISTANT:
Two small fixes from my read: the debug counter `placed` was being tracked by Observation (every other stored property opts out), and the doc comment on `map` reads badly.

[2026-10-06 19:55] ASSISTANT:
Waiting on the full test run before committing. I'm drafting the commit message meanwhile.

[2026-10-06 19:55] COMMIT MESSAGE FILE commit-message.txt:
Prose maps: which words of a text say which part of a lower-level text, and schema card highlights on them

The owner, studying the schema card's highlights, called them a case of something larger,
"natural language source maps": a map from what a person writes in words to something lower level,
"like source code but not just source code", which they expect to use all over the place as they
build tools that turn words into code, JSON Schema and data. They asked for the abstraction scoped
down to an API they could take in quickly, agreed it would carry the current feature unchanged, and
asked for the port.

ProseMaps (a surface on LanguageModels, with no extension point) is that API. A target
(`ProseTarget`) is a language words are mapped into: a type with a name and a guide, the part of the
prompt only it can say. Its addresses are quotes of its own text by default, found where they're
written exactly once (runs of whitespace matching any run), so a tool with no parser gets maps for a
name and a paragraph; a language with an address of its own (Schemas' `SchemaTarget`, a JSON
Pointer) finds it itself and says what it leads to. A map (`ProseMap`) is links placed on one pair
of texts, both ends found by content in the texts as they are, never by position: words typed around
a link keep it, a link whose words or part are gone drops, and a shape's last answer stands in while
its words are typed. One legend for every target, `LinkRole` (`.element`, something the target
has; `.rule`, something it keeps), so a color means one thing wherever words are mapped. The service
(`editor.proseMaps`, `context.proseMaps` in a render) is today's highlighter made generic: a pair read
with no answer is asked about as the frame that read it ends, if the reader says it may be, its
words aren't being typed and it's on the board shown, once per pair process-wide, four calls at a
time, a failure not again until a key is saved. `ProseMapPrompt` is the one request: a frame of
every target's rules with the target's name and guide in it, and a context after it only for a
request that has one (the schema card's word on other schemas), to Sonnet 5.5 at low effort.

Decisions made with the owner: targets are text (code, schemas, data, queries; words to shapes on a
board is another problem); the map is recovered by a call of its own once the target exists,
whoever wrote it, so it checks what made the target rather than restating it, where a map written
by the generating call would only explain it; maps are derived, never saved; the caller owns how its
text looks (its pills, its fills, its popovers) until a second kind draws maps. Two things changed
from the proposal they approved, both simpler: hold/release became the reader's `askingIf` (the
schema card's "while its sync is in step"), with `setNeedsDisplay` where readiness changes without a
commit, since the sync already knows when a card is in step; and the read is the editor's service
rather than a static cache, since renders now reach services. An awaited `ask` for commands was left
out until something calls it.

Schemas keeps its drawing, its popovers and its `@Word` translation (`SchemaHighlightsShown`, a
per-card memo of the texts the model reads and of the map moved onto the drawn text, so a frame
still parses no schema); `SchemaHighlighter`, the answers cache and `SchemaHighlightFrames` go,
and `highlightsSystem` became `highlightsGuide`. One behavior changes: a card being edited isn't
asked about until editing ends (its words aren't done), where an in-step card used to be.

The highlight evals, rebuilt as the app now builds the request (frame and settings from
ProseMapPrompt.swift, the guide from SchemaPrompts.swift), held: 28 cases four times each, the new
prompt 753 of 760 links found and the prompt it replaced 749, none misattributed by either, both
missing the same few. A rule telling the model to leave out words it can't place, from the
proposal, was tried in the frame and taken out: no misattribution either way, and it missed "each
cell" of a list of lists more often.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

===== [2026-10-06 19:55] commit written: Prose maps: which words of a text say which part of a lower-level text, and schema card highlights on them =====

[2026-10-06 19:55] ASSISTANT:
The full run passes apart from the PortEdgesTests failure that comes from main. Rebuilding with the last two edits, rerunning the two affected suites, then committing.

[2026-10-06 19:56] GIT:
git add -A && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-nl-source-maps-exploration-c42408/811cd2c4-f739-4115-b60b-76fca163ff38/scratchpad/commit-message.txt && git log -1 --format='%h %s'

[2026-10-06 19:56] ASSISTANT:
Jev routed the review to Sonnet at high effort. Launching it in the background, read-only.

[2026-10-06 19:57] AGENT Review the ProseMaps commit:
You are doing an independent code review of one commit in a Swift 6 / AppKit macOS app (an infinite canvas built from compiled-in plugins). Work only in this git worktree: /Users/zekenie/code/native-canvas/.claude/worktrees/nl-source-maps-exploration-c42408 . Review commit 3e66cbae (`git show 3e66cbae`, `git show 3e66cbae --stat`). It is READ-ONLY work: do not edit, create, stage or commit any file, and do not run ./build.sh or ./test.sh (another process uses the build directory). You may run the already-built test executables under build/debug/<Target>/<Target> if you want evidence (e.g. build/debug/ProseMapsTests/ProseMapsTests, build/debug/SchemasTests/SchemasTests), and read any file.

Context you need first: read CLAUDE.md, .claude/rules/prose-maps.md, .claude/rules/schema-cards.md, .claude/rules/build.md (layers), .claude/rules/drawing.md (frame-cost rules), and the commit message (`git log -1 --format=%B 3e66cbae`).

What the commit does: adds a module `Sources/ProseMaps` (a "surface" layer plugin on LanguageModels) that maps words of a plain-language text ("prose") to parts of a lower-level text ("target": a JSON Schema, code, a query) by asking a language model, and moves the schema card's existing description highlights (previously `SchemaHighlighter` + a static `SchemaHighlightAnswers` cache in Sources/Schemas) onto it. Key pieces:
- `ProseTarget` protocol (name, guide, Address defaulting to String quotes, locate, role(of:)), `LinkRole`, `ProseLink`, `ProseMap` (im […3434 more chars]

[2026-10-06 19:57] ASSISTANT:
While the review runs, I'm flagging the PortEdgesTests failure from main as a separate task, since it's outside this change.

[2026-10-06 19:57] ASSISTANT:
The benchmark boards include schema cards drawn in full, so I'm running `./build.sh bench` in the background too, to hold the frame budgets now that the render path goes through ProseMaps.

[2026-10-06 19:57] ASSISTANT:
Benchmarks and the review are both running in the background; I'll pick up when they finish.

[2026-10-06 20:00] NOTICE:
background task completed: Background command "Build in release and run the benchmarks against their budgets" completed (exit code 0)

[2026-10-06 20:00] ASSISTANT:
All 64 benchmarks pass their budgets. The review is still running; I'll wait for it.

[2026-10-06 20:26] ASSISTANT:
The review found no serious defects and six smaller ones, all fixable here. Here's how I'll handle each:

- A sync answer that writes nothing never redraws the card. The reviewer reproduced it, and the old code had the same hole. I'll call `inStep` there too.
- Only the shape that asked keeps a last answer, so a pasted copy or a card brought back by undo drops its highlights on the first keystroke. A shape will now keep any exact answer it reads.
- Text compared as Unicode-equal but in a different normalization form could reuse a map with stale indices and crash. I'll also require equal UTF-8 counts (cheap), and convert ranges against the map's own string.
- `find` misses overlapping repeats ("x + x" in "x + x + x"). I'll search again from one past the first match.
- Some per-frame cost: build the request only when asking, hash the cache key once, skip the readiness check for pairs already failed or in flight, early-out on commits that remove nothing, and keep shapes that only moved to another board.
- A stale doc reference and an unused function. Removing both.

[2026-10-06 20:26] ASSISTANT:
The review is in and my fix plan stands. Applying the fixes now, starting with the sync and the service.

[2026-10-06 20:28] ASSISTANT:
Now the service changes: the cache key hashes once, the request is built only when asking, and the remaining fixes.

[2026-10-06 20:35] ASSISTANT:
Applying the service changes in one pass.

[2026-10-06 20:35] ASSISTANT:
Adding tests for the review's findings.

[2026-10-06 20:42] ASSISTANT:
The failure is my test's arithmetic: "every item" starts at 18 and "over ten dollars" at 29, which is what the code returned. Fixing the expectation.

[2026-10-06 20:43] ASSISTANT:
All 18 ProseMaps tests and 235 schema tests pass, and each new test would fail without its fix. Updating the two docs where the semantics changed.

[2026-10-06 20:43] ASSISTANT:
Running the full suite once more before committing the fixes.

[2026-10-06 20:43] ASSISTANT:
Only the PortEdgesTests failure from main remains. Committing the review fixes on the branch.

[2026-10-06 20:44] GIT:
git add -A && git commit -q -F - <<'EOF'
Prose maps: fix what reviewing them found

A sync answer that leaves its side as it was commits nothing, so nothing heard the card come into
step and it waited for some other frame to ask for its highlights: the sync asks for one itself
(the old highlighter had the same hole). An answer a shape reads for its pair is now its last too,
as one it asked for was, so a pasted copy or a card undo brought back keeps its links as its words
are typed, as the docs already said. A map is kept only for texts equal and as long in UTF-8, and
the card moves its ranges with the map's own text: Swift calls an accent written as one scalar or
two equal, and a map made for one, read for the other, trapped on its ranges. A quote of the target
written again overlapping itself ("x + x" in "x + x + x") leads nowhere, as one written twice does.

Cheaper per frame: a request is made as it's asked, not each time a pair with no answer is read
again (any answer landing anywhere had every such shape in view make its own); an answer's key is
hashed once; a pair that failed or is out isn't put to the reader's readiness check; a commit that
takes nothing out costs no look. A shape moved to another board keeps its last answer, as the sync
keeps it. The popover's comment cited a helper that nothing called, now gone.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
git log --oneline -2

[2026-10-06 20:44] ASSISTANT:
Committed as 9cfa3a75. The fixes only take work out of the frame path, but I'm rerunning the benchmarks on this commit so the report covers what will land.

[2026-10-06 20:46] ASSISTANT:
The schema card highlights now run on a new general-purpose module, ProseMaps, and behave as before. The work is on this worktree's branch in two commits (3e66cbae, then 9cfa3a75 with the review fixes), on top of the latest local main. Nothing is on main yet.

**Testing**
- **Test suite:** everything passes except one PortEdgesTests case that also fails on main. Nothing that test builds from was touched here, so I left it alone and put up a task chip for it.
- **Benchmarks:** `./build.sh bench` passes all 64, run on the final commit.
- **Highlight evals:** rebuilt so they send exactly what the app now sends, and run four times on all 28 cases. The new prompt found 753 of 760 links and the old prompt 749 of 760. Neither pointed any words at the wrong part.

**Where it differs from the proposal you approved**
- **Readiness instead of hold/release:** the caller passes a closure saying when a pair may be asked about. The schema card's answer is "while its sync is in step", which the sync already knew; when that changes without an edit, the sync asks the canvas to redraw.
- **The map lives on each editor:** a render can now reach editor services, so the read sits there rather than in a process-wide static. Answers are still shared across files.
- **The awaited `ask` is left out** until something needs to call it.
- **The "leave it out when unsure" rule was dropped.** I tried it in the shared prompt; it caught no extra mistakes and cost recall.
- **One small behavior change:** a card isn't asked about while its description is being edited. Previously an in-step card could be.

**Review:** an independent reviewer found no serious defects. I fixed all six minor findings and added a test for each behavior fix:
- A sync answer that changed nothing never redrew the card, so its highlights weren't asked for. The old code had this too.
- A pasted copy, or a card brought back by undo, lost its highlights on the first keystroke.
- The same accented word written in two Unicode forms could reuse a map with stale positions and crash.
- A target quote that repeats overlapping itself ("x + x" in "x + x + x") was wrongly treated as unique.
- Some per-frame overhead.
- A stale doc reference.

The guide has a new "Prose maps" section, and there's a new topic file at `.claude/rules/prose-maps.md`.

Say when to land it on main.

[2026-10-06 21:32] USER:
land

[2026-10-06 21:33] ASSISTANT:
Landing: squash to one commit, rebase onto main if it moved, fast-forward main, then clean up the worktree.

[2026-10-06 21:33] GIT:
git -C /Users/zekenie/code/native-canvas status --short | head -5; echo "main: $(git log -1 --format='%h %s' main)"; echo "merge-base: $(git merge-base HEAD main | cut -c1-8)"; git log --oneline main..HEAD; git status --short | head -3

[2026-10-06 21:33] ASSISTANT:
Main moved to 86a1a2ba since the branch was cut, and the main checkout is clean. Squashing the two commits into one, keeping both messages' substance and leaving out the review process.

[2026-10-06 21:33] GIT:
git reset -q --soft 39203118 && git commit -q -F /private/tmp/claude-501/-Users-zekenie-code-native-canvas--claude-worktrees-nl-source-maps-exploration-c42408/811cd2c4-f739-4115-b60b-76fca163ff38/scratchpad/squash-message.txt && git log --oneline -2 && git rebase main 2>&1 | tail -5

[2026-10-06 21:33] ASSISTANT:
The rebase onto main applied cleanly. Fast-forwarding main.

[2026-10-06 21:33] ASSISTANT:
Main is at 5a0245e6. Removing this session's worktree and branch.

[2026-10-06 21:33] ASSISTANT:
It's on main as 5a0245e6.
