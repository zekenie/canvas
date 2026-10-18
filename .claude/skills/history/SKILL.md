---
name: history
description: Keep this repository's history readable to the agents that change it later. Use when landing a change on main (squash merge, "land", "merge it"): the commit carries the session's condensed transcript in history/sessions/ and names it in a Session: trailer. Also use to read why a commit was made (follow its Session: trailer), and for the weekly review of main's commit messages against their sessions.
---

# History

Every commit on main says why it was made, and names the session that made it. The message is
the summary an agent reads in `git log` and blame; the session's record, in `history/sessions/`,
is the evidence: what the owner asked, the questions put to them and their answers, their
corrections, the plans, and what was turned down.

## Landing

When a change lands on main as one squashed commit:

1. `python3 .claude/skills/history/condense.py --self` condenses this session's transcript to
   `history/sessions/<date>-<title>-<session>.md` and prints the path. A session that lands more
   than once rewrites its one file, which then covers both landings. The record covers the session up to
   this step, so the landing itself is in the next landing's record, or none.
2. Add the file to the squashed commit.
3. End the message with the trailer `Session: history/sessions/<file>.md`, above
   `Co-Authored-By`.

The record keeps the owner's messages whole, the questions and answers, refusals, the
assistant's prose, plans, agent briefs and git commands; it leaves tool output out and redacts
anything shaped like a key. Read it before committing, as the commit publishes it to everyone
with the repository.

## Reading a commit's why

`git log -1 --format=%B <sha>` ends with its `Session:` trailer; read that file. A record holds
the whole session, so a session that landed several commits has one record they all name, with a
line where each commit's message was written. The records began on 2026-10-18, when the commits
from `canvas draw` (2026-09-28) on were reviewed against their sessions, their messages rewritten
where the session said more than the message did, and every record added in one commit. The 41
commits before them name no record. A commit from a cloud session, whose transcript stayed in the
cloud, names its pull request's record instead: the description, comments and commits.

`history/` is in `.ignore`, so a search of the code skips it; search it by path.
