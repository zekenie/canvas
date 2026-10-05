---
name: jev-route
description: Pick each subagent's model (haiku, sonnet or opus) and effort with Jev, TypeSafe's routing model, before launching it. Use in this project before every Agent tool call and every Workflow run, routing all the agents about to launch in one call. Where Jev isn't available (no TYPESAFE_API_KEY on this machine, no network), launch without it.
---

# Routing subagents with Jev

Before launching subagents, ask Jev which model each should run on and with how much effort: the cheapest model that will do the task well. One call routes every agent about to launch; route each later batch when you launch it.

## Route

1. Write the tasks to a JSON file in your scratchpad: one key per agent (its description, or the workflow stage's label) and a sentence or two on what it must do. A summary, never the prompt: it's sent to TypeSafe, so no code, file contents or secrets.

   ```json
   {
     "survey-topology": "Read the Topology and Connections modules and report how edges are derived and how arrows bind, with file:line citations.",
     "design-seam": "Design a dependency inversion that lets a feature module use the query engine under strict layer rules; weigh three alternatives."
   }
   ```

2. Run `python3 .claude/skills/jev-route/route.py <tasks.json>`. For each task it prints `model` and `effort`, with Jev's probabilities.

## Apply

- An Agent tool call takes the route's `model`. It has no effort setting.
- A Workflow takes the routes in `args` (a script can't run commands), and each `agent()` gets its route's `model` and `effort`.

Use the routes as Jev gave them.

## When Jev isn't available

Exit status 3 means Jev can't be reached here: no key (another machine), no network, an API error or a timeout. The one line on standard error says which. Launch without `model` or `effort`, so the agents run on the session's, say so in a few words, and don't retry. Status 2 is a mistake in the tasks file: fix it and run again.

## The key

`TYPESAFE_API_KEY` from the environment, else its `export` line in `~/.zshrc` (the Bash tool doesn't load `.zshrc`). Never print, log or write it.
