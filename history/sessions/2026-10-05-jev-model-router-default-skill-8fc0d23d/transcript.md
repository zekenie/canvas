# JEV model router default skill

Claude Code session `8fc0d23d-1422-4b7e-95ed-a18a9fd93e06`, 2026-10-05 12:46 to 2026-10-05 12:57 UTC, on `claude/jev-router-default-skill-ab75fd`.

Condensed: the owner's messages, questions and answers, the assistant's prose, plans, agent briefs and git commands. Tool output is left out.

[2026-10-05 12:46] USER:
in @[Reference shape system] i made a jev model router. i want to make this a default via skill any time i'm using sub-agents in this project. when jev is not availibe (like on another laptop) it's ok not to use it.

[2026-10-05 12:46] ASSISTANT:
I'm reading the "Reference shape system" session to find how you built the Jev router.

[2026-10-05 12:46] ASSISTANT:
The other session wrote its router into its scratchpad. Let me find it.

[2026-10-05 12:47] ASSISTANT:
I read the router (`jev_route.py` in that session's scratchpad). Your notes say to show the plan before writing code, so here it is.

**What it does now:** one TypeSafe call (`jev-latest`) asks two questions for each task: which model (haiku, sonnet or opus, "the cheapest that will do it well") and how much effort (low, medium or high). It reads the key from `TYPESAFE_API_KEY`, or else from the export line in `~/.zshrc`. That second source is needed: my Bash tool doesn't load `.zshrc`, so the variable is empty here even though the key is in the file.

**Plan**

1. **A project skill, `.claude/skills/jev-route/`, checked in.** It holds a `SKILL.md` and `route.py`, the script moved into the repo. Because it's in the repo it goes with you to other laptops. It doesn't affect SkillTests, which only read `.claude/skills/canvas`.
2. **When it runs:** the skill's description tells me to use it before any Agent call or Workflow run in this project. I route all of a turn's agents in one call, before launching them.
3. **Applying the routes:**
   - An Agent call takes the chosen `model`. The Agent tool has no effort setting.
   - A Workflow takes both `model` and `effort`, passed in through `args`, since workflow scripts can't run shell commands.
4. **When Jev isn't available** (no key, no network, an API error, or a timeout of about 10s), the script exits with code 3 and prints one line to stderr. I then launch without a model setting, so agents use the session's model. I mention that in a few words and don't retry.
5. **What gets sent to TypeSafe:** a one- or two-sentence summary of each task. No full prompts, code or file contents.
6. **Script changes:**
   - Make the setting text general by removing "to plan a big cross-cutting feature".
   - Add the timeout and the exit code 3.
   - The key is never printed.
   - Otherwise it stays as you built it: same three models and three effort levels, and no policy of my own for low-confidence answers.
7. **Check:** run it once on the control tasks from your session (list, grep, count, summarize, implement, design, race), and once with the key hidden to confirm the fallback. Then commit on this branch, and land it only when you say so.

**Decisions:**
- **No line in CLAUDE.md.** That file is for what every task needs, and the skill's description is already loaded in every session. If the skill doesn't trigger reliably, a hook that fires before every Agent or Workflow call could enforce it. I'd add that only if you ask.
- **Fable isn't one of the choices**, the same as in your version. I could add it as a fourth model if you want.

Should I go ahead?

[2026-10-05 12:50] USER:
yes go

[2026-10-05 12:51] ASSISTANT:
`sys.exit("message")` exits with status 1, not the 2 the skill promises. Fixing that before testing.

[2026-10-05 12:51] ASSISTANT:
Now the three checks: a live call on your session's control tasks, the fallback with no key, and a bad tasks file.

[2026-10-05 12:51] ASSISTANT:
All three checks pass, and the live routes match what your session got: haiku for list, grep and count, sonnet for summarize and implement, opus for design and the race bug. Committing on the branch.

===== [2026-10-05 12:51] commit written: Route every subagent's model and effort with Jev, by a project skill (#16) =====

[2026-10-05 12:51] ASSISTANT:
I've added the Jev router as a project skill, [.claude/skills/jev-route/](.claude/skills/jev-route/SKILL.md), and committed it on this branch as `8ebe85b`. It isn't on main yet.

**What it does:** before any Agent or Workflow launch in this project, I write a one-line summary of each agent's task and run [route.py](.claude/skills/jev-route/route.py) once for all of them. Each agent gets the model Jev picks. Workflow agents also get its effort; the Agent tool has no effort setting.

**Where Jev isn't available**, the script exits with code 3 and a one-line reason, and the agents run on the session's model. That covers no key (another laptop), no network, an API error, or no answer within 10 seconds. The key comes from `TYPESAFE_API_KEY` or your `~/.zshrc` and is never printed.

**Tests run:**

| Case | Result |
|---|---|
| Your session's control tasks | Same routes as before: haiku/low for list, grep and count; sonnet/medium for summarize and implement; opus/high for design and the race bug |
| No key | Exit 3, "no TYPESAFE_API_KEY" |
| Wrong key | Exit 3, "HTTP 401" |
| Malformed tasks file | Exit 2 |

**When it takes effect:** a skill added mid-session doesn't show up in that session's skill list. So it applies from the next session that has this branch, or, once it's on main, from every new session.

To get it there, I'll run a code review whenever you want and land it on your go-ahead.

[2026-10-05 12:56] USER:
lets sqash merge to main

[2026-10-05 12:57] ASSISTANT:
Your last six landings went through squash-merged GitHub PRs (#10–#15), so I'll land this one the same way. That keeps your local main in step with origin.

[2026-10-05 12:57] GIT:
W=/Users/zekenie/code/native-canvas/.claude/worktrees/jev-router-default-skill-ab75fd; B=claude/jev-router-default-skill-ab75fd; cd $W && git push -q -u origin $B 2>&1 | tail -2; gh pr create --base main --head $B --title "Route every subagent's model and effort with Jev, by a project skill" --body "$(git log -1 --format=%b | sed '/^Co-Authored-By/d')

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

[2026-10-05 12:57] ASSISTANT:
Merged. Now bringing your local main up to date and removing the worktree and branches.

[2026-10-05 12:57] ASSISTANT:
It's on main as `d7f0291`, via [zekenie/canvas#16](https://github.com/zekenie/canvas/pull/16). There was no code review, since you asked to merge straight away. Your local main is up to date, and this session's worktree and branch are removed, locally and on GitHub. New sessions will route their subagents with Jev from now on.
