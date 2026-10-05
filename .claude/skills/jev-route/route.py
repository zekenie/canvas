#!/usr/bin/env python3
"""Route subagent tasks to a Claude model and effort with Jev (TypeSafe System One).

usage: route.py tasks.json > routes.json
tasks.json: {"<task id>": "<what the agent must do>", ...}
Prints {"<task id>": {"model": ..., "model_p": {...}, "model_conf": ..., "effort": ..., "effort_p": {...}}}.
Exits 3, with one line on standard error, when Jev can't be reached here (no key, no network,
an API error, a timeout); 2 when the tasks file is wrong.
The API key is read from TYPESAFE_API_KEY, else from its export line in ~/.zshrc; it is never printed.
"""
import json, os, re, socket, sys, urllib.error, urllib.request

UNAVAILABLE = 3
BAD_TASKS = 2
TIMEOUT = 10

def bad_tasks(why):
    print(why, file=sys.stderr)
    sys.exit(BAD_TASKS)

def unavailable(why):
    print(f"jev unavailable: {why}", file=sys.stderr)
    sys.exit(UNAVAILABLE)

def api_key():
    key = os.environ.get("TYPESAFE_API_KEY")
    if key:
        return key
    try:
        with open(os.path.expanduser("~/.zshrc")) as f:
            for line in f:
                m = re.match(r"\s*export\s+TYPESAFE_API_KEY=['\"]?([^'\"\s]+)", line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    unavailable("no TYPESAFE_API_KEY")

MODEL_CRITERIA = {
    "haiku": "Mechanical, low-judgment work: locate where something is defined or used, list files or symbols, copy facts verbatim, run a command and report its output. Little reading comprehension and no design judgment.",
    "sonnet": "Careful reading and explanation, or well-specified implementation: study one or a few subsystems of a large Swift codebase and report accurately how they work (APIs, extension points, constraints) with file:line citations; or write code to a precise spec. Needs solid comprehension, but the hard decisions are already made.",
    "opus": "Deep, open-ended reasoning: design a new architecture across many subsystems, weigh module-dependency and layering trade-offs, invent APIs, resolve semantic cycles, judge between competing designs, or adversarially hunt for subtle flaws. Mistakes here are expensive and the problem is underspecified.",
}
EFFORT_CRITERIA = {
    "low": "Routine; a quick pass is enough.",
    "medium": "Some care needed; moderate depth and cross-checking.",
    "high": "Hard or high-stakes; think deeply, check thoroughly, consider edge cases.",
}

def main():
    if len(sys.argv) != 2:
        bad_tasks("usage: route.py tasks.json")
    try:
        with open(sys.argv[1]) as f:
            tasks = json.load(f)
    except (OSError, ValueError) as e:
        bad_tasks(f"can't read the tasks: {e}")
    if not isinstance(tasks, dict) or not tasks or not all(isinstance(t, str) for t in tasks.values()):
        bad_tasks("tasks.json must map each task id to a description")
    state = {
        "setting": "A lead engineer is fanning out subagents over a large native macOS Swift codebase (an infinite-canvas app built from compiled-in plugins with a strict module-layer graph). Each task below goes to one subagent; the lead must pick the cheapest model tier that will still do the task well, and how much reasoning effort to give it.",
        "tasks": tasks,
    }
    questions = {}
    for tid in tasks:
        questions[f"{tid}::model"] = {
            "type": "choice",
            "instructions": f"Which model tier should run the subagent task `tasks.{tid}`? Pick the cheapest tier that will do this task well.",
            "criteria": MODEL_CRITERIA,
        }
        questions[f"{tid}::effort"] = {
            "type": "choice",
            "instructions": f"How much reasoning effort does the subagent task `tasks.{tid}` need?",
            "criteria": EFFORT_CRITERIA,
        }
    body = json.dumps({"state": state, "model": "jev-latest", "questions": questions}).encode()
    req = urllib.request.Request(
        "https://api.typesafe.ai/v1/systemone",
        data=body,
        headers={"Authorization": f"Bearer {api_key()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            resp = json.load(r)
        out = {}
        for tid in tasks:
            m = resp["answers"][f"{tid}::model"]
            e = resp["answers"][f"{tid}::effort"]
            out[tid] = {
                "model": m["choice"], "model_p": m["probabilities"], "model_conf": round(m["confidence"], 2),
                "effort": e["choice"], "effort_p": e["probabilities"],
            }
    except urllib.error.HTTPError as e:
        unavailable(f"HTTP {e.code}")
    except urllib.error.URLError as e:
        unavailable(f"can't reach the API ({e.reason})")
    except (socket.timeout, TimeoutError):
        unavailable(f"no answer in {TIMEOUT}s")
    except (ValueError, KeyError, TypeError):
        unavailable("unexpected response")
    out["_meta"] = {"jev": resp.get("model"), "usage": resp.get("usage")}
    print(json.dumps(out, indent=1))

main()
