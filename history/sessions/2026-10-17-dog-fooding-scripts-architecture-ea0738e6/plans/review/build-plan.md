# Build plan

Six slices take the ingestion from this repo's script to something any repo gets with the app. It is done when a TypeScript monorepo, set up in a few rounds, draws any commit the same way twice, with its workflows, Lambdas and tables as types. Each slice is a commit with its tests; the whole lands on your word, after a review.

## Names

One sentence says the whole pipeline: **`ingest` scans a commit, your lens turns the scan into a digest, and canvas-digest draws the digest as boards.** "Model" already means a language model in this app, and "runner", "the function" and "typed digests" were placeholders.

| Was | Now | What it is |
| --- | --- | --- |
| the runner | `ingest` | The one command |
| `model.json`, the reader | the scan, a scanner | What `ingest` reads out of a commit: modules, files and who uses whom. One scanner for Swift, one for SCIP (TypeScript and others) |
| the function, `codebase.py` | the lens, `.canvas/lens.py` | Your repo's file that decides what the boards show |
| the default picture | the default lens | Today's picture: modules in bands, files in frames |
| `codebase.json` | `.canvas/ingest.json` | `ingest`'s settings for your repo: the scanner, the view, the dial |
| `canvas-codebase` | `canvas-ingest` | The skill that sets a repo up and runs `ingest` |
| digest | digest, kept | canvas-digest's word: what is on the boards, what holds what and what points at what |

## Where things live

Once it is built, a team's repo holds two small files, and everything else comes with the app.

| Where | What |
| --- | --- |
| The app | `canvas`, and three skills: `canvas`, `canvas-digest` and the new `canvas-ingest`, which holds `ingest`, the scanners and the default lens |
| Your agents, such as Claude Code | The three skills, which `canvas install` copies into `~/.agents/skills`, the folder agents share, and links into `~/.claude/skills` for Claude Code. It also puts `canvas` on the PATH |
| Your repo | `.canvas/ingest.json`, the settings, and `.canvas/lens.py`, the lens, both checked in |
| A cache outside the repo | Each commit's scan, Swift's index, the plans and the record of what was drawn: one per repository, shared by its worktrees |

## Decided

Claude made these calls. They settle the design's open questions and the ones planning raised; overturn any with a comment.

| Decision | Why |
| --- | --- |
| The lens returns a digest. canvas-digest still places every shape. | Past about forty shapes, nobody places them by hand. |
| The lens is Python: `.canvas/lens.py` defines `digest(scan, repo)`. | The default lens and its helpers are Python already. A lens has to list the repo's files, which jsc can't. Python 3 comes with the Command Line Tools, which git needs anyway. |
| The input is a commit, HEAD by default. The lens reads that commit's files through `repo`, never the working tree. The lens itself comes from the checkout you run in. | Two commits drawn by one lens differ only by their code. |
| Every lens is run twice, under different hash seeds, and a digest that differs is refused. | Set order and the clock are how a lens stops being deterministic. |
| A repo's view is pinned in its config, where setup writes the window's room once. A config without one, like this repo's, is laid out for the window, as today. | The window's size is the one hidden input. |
| State lives in a cache outside the repo, one per repository, shared by its worktrees. | Nothing new to ignore in a team's repo, and any worktree can redraw what another drew. |
| Digests learn types. Notes take `schema`, `relationship`, `is` and `fieldValues`; edges take `is`, `fieldValues` and `endRule`. Only notes and edges can be instances, as in the app. | The app has all of these already; the digest passes them through. |
| A type in a digest can't `$ref` another type. Types relate through relationship types. | A `$ref` needs the other type's id, which exists only once it is drawn. |
| `spec.py` is gone. Its overrides become arguments of the default lens, which a repo's lens can call. | One place to art-direct. |
| `ingest` and its scanners become a third skill, `canvas-ingest`, moved from `dogfood/model`. This repo's run draws the same board. | It ships the way the other two skills do. |
| The skills follow the Agent Skills standard, and the app carries them. `canvas install` copies them into `~/.agents/skills`, links them into `~/.claude/skills` for Claude Code, and links `canvas` onto the PATH. You run it again after updating the app, and a run warns when the skills and the app are different builds. | Any agent that reads Agent Skills can use them: agents share that folder by convention (https://agentskills.io/client-implementation/adding-skills-support), and Claude Code reads its own and follows links (https://code.claude.com/docs/en/skills). One step after installing the app. |
| A proposal is a commit drawn into a new file and written on. Nothing carries a proposal to a newer commit. | It keeps today's rule: a drawing never takes over a board someone wrote on. |

## Order

(Diagram: slice 1 "Types in the digest" runs beside the chain 2 "Ingest any repo" -> 3 "Your lens" -> 4 "Any commit"; 1 and 4 both feed 5 "Setup in rounds", then 6 "Install for agents", then "Tried for real".)

Slice 1 touches only canvas-digest, so it can be built in a session of its own while 2 to 4 are.

## 1. Types in the digest

The digest format learns types, so a lens can say "this is a workflow". It touches only canvas-digest.

- **Format.** A node takes `schema`, `relationship`, `is` and `fieldValues`; an edge takes `is`, `fieldValues` and `endRule`. `graph.md` and the canvas-digest skill say how, with an example.
- **Check.** It refuses an `is` that names no type in the digest, `is` on a frame or a subboard, `relationship` without a `schema`, and a `$ref` in a schema.
- **Measure.** The measure script carries the types, their ends and every relationship, so a typed note is planned at the size it is drawn, rows and all.
- **Order of runs.** Frames, cards, types and plain notes first, then the types' ends, then the notes that are instances, then every other edge. A note can name a type only once the type is on the board.
- **Arrows.** Two edges between one pair with different `is` are two arrows, and one edge to the layout, their weights added. An untyped edge beside typed ones is dropped, with a warning. `verify` and `replay` tell typed arrows apart.

**Tests.** The tool's tests: each refusal, the order of runs, byte-identical output. A DigestTests case: a typed fixture (workflows and tables on two services' boards, a `writes` relationship crossing boards through a pill) drawn and verified, with `:is-a("Table")` and the relationship's query answering as drawn.

**Done when** the typed fixture draws through the dry-run gate with no warning but the out-of-view one.

## 2. Ingest any repo

The ingestion stops depending on where it lives. This repo's board comes out the same.

- `dogfood/model` moves to `.claude/skills/canvas-ingest/`: `ingest`, the scanners and the default lens. It gets a topic file of its own, `.claude/rules/ingest.md`.
- `ingest` runs in any repo. It finds the digest tool beside itself, and `canvas` the way the digest driver does.
- A repo's settings are `.canvas/ingest.json`: the scanner (Swift or SCIP), the index command with the indexer's version pinned, a command that installs the repo's packages before scanning, the view, the dial and the ranks.
- State moves to the cache, keyed by the repository's git folder so its worktrees share one.
- This repo gets a `.canvas/ingest.json` that names the Swift scanner and no view, so it is still laid out for the window.

**Tests.** DigestTests' ingestion cases move to the new path, with a cache of their own.

**Done when** this repo, from the same scan and view, plans the same board as before the move.

## 3. Your lens

Each repo's picture becomes its own: `.canvas/lens.py` turns the scan and the repo into a digest.

- `common.py`, `defaults.py` and `to_digest.py` become a library every lens imports, `lenskit`: the scan with its lookups, a digest builder that gives every title out once (today's `Titles`), the notes' texts, and the default lens as `default.digest(scan, **overrides)`.
- `ingest` loads `.canvas/lens.py`, or uses the default lens when there is none. It calls `digest(scan, repo)`, checks what comes back, runs it twice under different hash seeds, and writes `digest.json`.
- `repo` reads the drawn commit's files through git: `files(pattern)`, `read(path)` and `exists(path)`.
- A node may carry `source`, what it was made from. canvas-digest ignores it; the skill uses it to map a selection back to code.
- A lens that raises stops the run with its traceback, before anything is drawn.

**Tests.** The default lens's digest is byte-identical to today's for a fixture scan. A lens that regroups the files is drawn and verified. A lens that depends on set order, and one that reads the clock, are refused. `repo` doesn't see an uncommitted edit. A lens that raises draws nothing.

**Done when** this repo draws the same board through the default lens, and a repo's own lens draws its own.

## 4. Any commit

Any commit can be drawn again, and comes out the same.

- `ingest --commit REF`, HEAD by default.
- A commit is scanned once: from a clean copy of it (`git archive`), after the settings' install command. Its scan is kept in the cache by commit and scanner, so later rounds go straight to the lens.
- The view, the dial and the ranks come from the settings.
- The root's header ends with what drew it: the commit and its date, the lens's last commit (or "uncommitted"), and the app's build, which `build.sh` stamps into the bundle.

**Tests.** A Swift package in a scratch git repository with two commits. Each commit draws its own board. One drawn twice gives byte-identical scripts and plan. A working-tree edit never shows. The second run scans nothing. The header names both commits.

**Done when** one commit drawn twice gives the same scripts.

## 5. Setup in rounds

Setup and every later edit are one skill, canvas-ingest, and setup is round one.

- **`SKILL.md`.** Set a repo up in rounds: survey it, confirm the main things with you, write the lens and its types, draw HEAD, fix what the report shows, then take your direction. Read what you point at with `canvas query ':selected'`, mapped back to code by `source`. Write each request as a named rule with its reason. Redraw a commit, or draw one into a new file for a proposal.
- **`reference/lens.md`.** The scan, `repo`, `lenskit`, types in the digest, and what keeps a lens deterministic.
- **A worked example.** A small TypeScript monorepo (packages, a Temporal workflow and its activities, a Lambda, SQL migrations) and its lens, with Workflow, Activity, Lambda and Table types and `reads` and `writes` relationships.
- **Any agent.** The skill works through `ingest`, `canvas` and plain instructions, never one agent's own tools, so any agent that reads Agent Skills can follow it.

**Tests.** The example is drawn and verified, and its questions ("which workflows write orders?") are answered by queries as drawn. The skill's commands and options are held to `ingest`'s help, as SkillTests hold the canvas skill.

**Done when** new sessions of Claude Code and of one other agent you use each set the example up from the skill alone, and draw it.

## 6. Install for agents

Installing the app is the only download, and one command puts its skills where your agents read them.

- `build.sh` copies the three skills into the app (`Contents/Resources/skills`, without their tests), with `build/canvas` written as `canvas`.
- `canvas install` copies them into `~/.agents/skills`, the folder agents that read Agent Skills share, and links each into `~/.claude/skills`, the only folder Claude Code reads. `--to DIR` puts them in any other agent's folder. It also links `canvas` into a folder on the PATH, or says how to add one. It runs without the app.
- A run warns when the skills and the app answering are different builds.

**Tests.** CommandLineTests run `canvas install` twice into a temporary home folder and PATH, never the real ones: the copies, the links, `--to`, and no `build/canvas` in what it copied. SkillTests hold all three skills to the Agent Skills spec: each name matches its folder, each description is at most 1,024 characters, and each `SKILL.md` is under 500 lines.

**Done when** an agent's session in another repo (Claude Code's, and one other's), with nothing installed but the app and what canvas install copied, sets that repo up and draws it.

## Then, for real

Claude sets up a public TypeScript monorepo you name, end to end. Then you run setup on the work monorepo and bring back the report, the timings and what you would change.
