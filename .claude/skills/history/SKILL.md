---
name: history
description: Keep this repository's history readable to the agents that change it later. Use when landing a change on main (squash merge, "land", "merge it"): the commit carries the session's condensed transcript in history/sessions/ and names it in a Session: trailer. Also use to read why a commit was made (follow its Session: trailer), and for the weekly review of main's commit messages against their sessions.
---

# History

Every commit on main says why it was made, and names the session that made it. The message is
the summary an agent reads in `git log` and blame; the session's record, in `history/sessions/`,
is the evidence: what the owner asked, the questions put to them and their answers, their
corrections, the plans, and what was turned down.

A record is a directory, `history/sessions/<date>-<title>-<session>/`: `transcript.md`, the
session's transcript condensed, and `plans/`, the plan files the session and its agents wrote, as
they were last written, when it wrote any. A plan file is a plan mode's (`~/.claude/plans/`), or
markdown in the session's scratchpad named for a plan (`plan.md`, `v1-plan.md`, `build-plan.md`)
or kept in a `plan/` or `plans/` folder at its top, outside any clone of a repository and any
deeper `plans/` folder (a copy of a record's); its path under
`plans/` is its path in the scratchpad.

## Landing

When a change lands on main as one squashed commit:

1. `python3 .claude/skills/history/condense.py --self` writes this session's record and prints its
   directory. A session that lands more than once rewrites its one record, which then covers both
   landings. The record covers the session up to this step, so the landing itself is in the next
   landing's record, or none.
2. Add the directory to the squashed commit.
3. End the message with the trailer `Session: history/sessions/<record>/`, above
   `Co-Authored-By`.

The transcript keeps the owner's messages whole, the questions and answers, refusals, the
assistant's prose, plans, agent briefs and git commands; it leaves tool output out. A message of
the owner's is kept whole, a command's arguments and a message sent mid-turn too, without what the
app sent with it (its reminders and the view of a doc they had open as they wrote, which the app
writes on lines of their own, so the owner's own mention of one in a sentence stays); what the
app, another session or a program put in a turn is said for what it is (a notice, a session's
message, a comment sent from a page, a prompt the SDK sent), never as the owner's: `HistoryTests`
(SkillToolsTests) holds it. A plan file
is taken from disk, or rebuilt from the transcript's writes and edits when it's gone; plans only
accumulate, so one recorded before stays when it can no longer be found. Both redact
anything shaped like a key. Read them before committing, as the commit publishes them to everyone
with the repository.

## Reading a commit's why

`git log -1 --format=%B <sha>` ends with its `Session:` trailer; read that record's
`transcript.md`, and its plans. A trailer written before records were directories, on
2026-10-21, names `history/sessions/<record>.md`: the record is the directory of that name
without `.md`. A record holds the whole session, so a session that landed several commits has one
record they all name, with a line where each commit's message was written. The records began on 2026-10-18, when the commits
from `canvas draw` (2026-09-28) on were reviewed against their sessions, their messages rewritten
where the session said more than the message did, and every record added in one commit. The 41
commits before them name no record. A commit from a cloud session, whose transcript stayed in the
cloud, names its pull request's record instead: the description, comments and commits.

`history/` is in `.ignore`, so a search of the code skips it; search it by path.

## Backfill

Claude Code deletes a transcript 30 days after its session was last used (unless
`cleanupPeriodDays` in `~/.claude/settings.json` says otherwise), and plan files can go sooner, with the
scratchpad. `python3 .claude/skills/history/backfill.py [--dry-run]` makes every record in
`history/sessions/` a directory (a record kept as one file, `<record>.md`, becomes
`<record>/transcript.md`) and writes the plans of every recorded session whose transcript is still
on this machine. It leaves the transcripts as they were committed, since the weekly review read
those, and a pull request's record, whose session never ran here. It prints what it moved and which
records' plans it wrote; run it again and it writes only plans that are new or changed. Commit what
it writes like any other change.

## Weekly review

Each week the owner has main's new commits reviewed against their sessions, as the commits before
the `history-reviewed` tag were on 2026-10-18: a Sonnet reviewer for each session, an Opus writer
for each message the session says more than, a Sonnet verifier that tries to refute every new
sentence, and an Opus revision. The models are the owner's; Jev picks each stage's effort (the
defaults when it can't be reached). `review.py` does every step, keeping the run in a folder beside
the repository (`../native-canvas-backups/history-review-<date>/`), and only the last moves a ref.
Work in a worktree off main.

1. `python3 .claude/skills/history/review.py prepare` takes main's first parent after
   `history-reviewed` and groups its commits by the records their `Session:` trailers name. For a
   commit without one, the session that wrote its message is found in this machine's transcripts
   (the latest to write it by the time it was committed) and condensed into a record to add; a
   pull request's merge brings the PR's record. A commit that only adds records isn't reviewed, and
   neither is one with no record found. It prints the run's folder, the groups with their records'
   sizes, and the routes.
2. Run the workflow: `scriptPath` `.claude/skills/history/review.js`, and as `args` the object
   that `review.py args <run>` prints. Over about 25 groups, run batches oldest first
   (`--only <id>,...`) and report the cost after each; the first review cost about $1 a commit at
   list prices, mostly in proportion to the records' size.
3. `review.py cost <run> <workflow run id>` prints each stage's tokens and price: report it.
   `review.py collect <run> <workflow output file>` gathers the messages and writes
   `<run>/proposed-messages.md`: each new message under the old, what changed, and what the
   writers turned down. A group with no result (an agent that died on an API error) is named
   there: run it again by itself with `--only` rather than resuming, which re-runs every group after
   the first that failed; a later run of a group replaces the earlier one's messages.
4. Send the owner proposed-messages.md, and wait: they read it before anything is rebuilt.
5. `review.py rebuild <run> [--message FILE]` builds the new history from the proposals. Every
   commit keeps its tree, author, committer and dates and gets its records as `Session:`
   trailers; a PR's merge becomes one commit with the merge's tree, and a squash run one with its
   last commit's, each with that last commit's identity (the merger's, for a merge). Only
   consecutive commits are squashed (the owner is skeptical of anything else), and it refuses a
   message for any other run. It refuses while a group has no finished review, unless
   `--leave-unreviewed` (those commits then never come up again). Commits that landed on main
   since prepare are replayed as they are, merges included, to be reviewed next week.
   When records were found from transcripts, they go in one commit at the tip, with this
   session's record, condensed then: write that commit's message to FILE first (the range
   reviewed, what changed, and the records added). It moves no ref: it prints the new tip and
   checks every tree against the old.
6. When the owner says to land it, `review.py land <run>` makes a mirror backup beside the
   repository, tags the old tip `pre-history-review-<date>`, moves main by compare-and-swap
   (refused if main moved since the rebuild: rebuild again), moves `history-reviewed` to the last
   commit reviewed, and force-pushes main and the tags with a lease on what origin had (refused
   if origin has commits main lacks). It prints the branches built on the old history and the
   `git rebase --onto` each needs: tell the owner, as they are other sessions' to run.
