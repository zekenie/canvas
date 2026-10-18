# PR #16: Route every subagent's model and effort with Jev, by a project skill
Branch claude/jev-router-default-skill-ab75fd, opened 2026-10-05T12:57:31Z, merged 2026-10-05T12:57:48Z.
Made by a Claude Code session in the cloud; its transcript isn't on this machine, so this PR is the record of it.

## Description

The router began as a scratchpad script in the Reference shape session, where
Jev (TypeSafe's System One model) picked haiku, sonnet or opus and an effort
for each research and design agent. Checked against control tasks, it picks
haiku for lookups, sonnet for reading and spec'd implementation, and opus for
design and bug hunts, so it should be the default whenever agents fan out here.

A project skill rather than a CLAUDE.md line: the skill's description is in
every session's listing already, and CLAUDE.md holds only what every task
needs. If the skill doesn't fire reliably, a hook before Agent and Workflow
calls could enforce it; not added.

Checked in so it goes to other machines; where the key or network is missing
the script exits 3 and agents run on the session's model, as the user asked.
The key comes from the environment or ~/.zshrc (the Bash tool doesn't load
it), and only one-line task summaries are sent, never prompts or code. The
choices stay haiku/sonnet/opus as built, with no low-confidence policy added.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

## Commits
- 8ebe85ba Route every subagent's model and effort with Jev, by a project skill
