"""Rebuild main's history from a plan, keeping every tree: each commit on main's first parent
from the base up keeps its tree, author, committer and dates, and takes the plan's message; a
run of them squashed becomes one commit with the run's last tree and identity; a merge becomes
one commit with the merge's tree. Nothing moves a ref: this prints the new tip, and checks it.

    python3 rebuild.py <plan.json>

The plan: {"base": <sha kept as is>, "tip": <old tip>, "units": [{"shas": [first-parent shas,
oldest first], "message": <full message>, "sessions": [paths]}]}. Every first-parent commit
after the base appears in exactly one unit, in order. A Session: trailer is added for each
path, above the other trailers.
"""
import json, os, re, subprocess, sys, tempfile


def git(*args, env=None, inp=None):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True,
                          env=env, input=inp).stdout.strip()


TRAILER = re.compile(r"^[A-Za-z][A-Za-z0-9-]*: \S")
KNOWN = re.compile(r"^(Co-Authored-By|Co-authored-by|Signed-off-by|Session|Claude-Session): ", re.I)


def check(ok, what):
    if not ok:
        sys.exit(f"refused: {what}")


def with_sessions(message, sessions):
    if not sessions:
        return message.rstrip() + "\n"
    lines = message.rstrip().split("\n")
    # The trailer block is the last paragraph, when every line of it is "Key: value" and one of
    # them is a trailer git writes for us (so a closing "Note: ..." line stays prose).
    cut = len(lines)
    while cut > 0 and TRAILER.match(lines[cut - 1]):
        cut -= 1
    block = lines[cut:]
    has_block = bool(block) and (cut == 0 or not lines[cut - 1].strip()) and any(KNOWN.match(t) for t in block)
    if not has_block:
        cut = len(lines)
    body, trailers = lines[:cut], lines[cut:]
    trailers = [t for t in trailers if not t.startswith("Session: ")]
    ours = [f"Session: {p}" for p in sessions]
    if body and body[-1].strip():
        body.append("")
    return "\n".join(body + ours + trailers) + "\n"


def main():
    plan = json.load(open(sys.argv[1]))
    base, tip = plan["base"], plan["tip"]
    first_parent = git("rev-list", "--first-parent", "--reverse", f"{base}..{tip}").split()
    covered = [s for u in plan["units"] for s in u["shas"]]
    full = [git("rev-parse", s) for s in covered]
    if full != first_parent:
        sys.exit("the plan's units don't cover main's first parent from the base, in order")

    parent, made = git("rev-parse", base), []
    for u in plan["units"]:
        last = git("rev-parse", u["shas"][-1])
        fmt = "%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI"
        an, ae, ad, cn, ce, cd = git("log", "-1", f"--format={fmt}", last).split("\x00")
        env = dict(os.environ, GIT_AUTHOR_NAME=an, GIT_AUTHOR_EMAIL=ae, GIT_AUTHOR_DATE=ad,
                   GIT_COMMITTER_NAME=cn, GIT_COMMITTER_EMAIL=ce, GIT_COMMITTER_DATE=cd)
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".msg") as f:
            f.write(with_sessions(u["message"], u.get("sessions", [])))
        new = git("commit-tree", f"{last}^{{tree}}", "-p", parent, "-F", f.name, env=env)
        os.unlink(f.name)
        made.append(dict(old=u["shas"], new=new))
        parent = new

    # The checks: the same end state, each new commit's tree its unit's last tree.
    check(git("rev-parse", f"{parent}^{{tree}}") == git("rev-parse", f"{tip}^{{tree}}"), "the new tip's tree isn't the old tip's")
    for m in made:
        check(git("rev-parse", f"{m['new']}^{{tree}}") == git("rev-parse", f"{m['old'][-1]}^{{tree}}"), f"{m['old'][-1][:8]}'s tree changed")
    check(len(git("rev-list", f"{base}..{parent}").split()) == len(plan["units"]), "the new history has the wrong number of commits")
    json.dump(made, open(sys.argv[1].replace(".json", ".map.json"), "w"), indent=1)
    print(parent)


if __name__ == "__main__":
    main()
