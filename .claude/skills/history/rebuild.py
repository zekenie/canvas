"""Rebuild main's history from a plan, keeping every tree: each commit on main's first parent
from the base up keeps its tree, author, committer and dates, and takes the plan's message; a
run of them squashed becomes one commit with the run's last tree and identity; a merge becomes
one commit with the merge's tree, unless its unit is a replay, which keeps the merge's other
parents and its message as they are. Nothing moves a ref: this prints the new tip, and checks it.

    python3 rebuild.py <plan.json>

The plan: {"base": <sha kept as is>, "tip": <old tip>, "units": [{"shas": [first-parent shas,
oldest first], "message": <full message>, "sessions": [paths], "replay": <optional bool>}]}.
Every first-parent commit after the base appears in exactly one unit, in order. A Session:
trailer is added for each path, above the other trailers. A replay unit is one commit carried
with its own message and all its parents, for what landed after the review began.
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


def copy(sha, parents, message):
    """sha's commit made again on new parents, with its tree, author, committer and dates."""
    fmt = "%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI"
    an, ae, ad, cn, ce, cd = git("log", "-1", f"--format={fmt}", sha).split("\x00")
    env = dict(os.environ, GIT_AUTHOR_NAME=an, GIT_AUTHOR_EMAIL=ae, GIT_AUTHOR_DATE=ad,
               GIT_COMMITTER_NAME=cn, GIT_COMMITTER_EMAIL=ce, GIT_COMMITTER_DATE=cd)
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".msg") as f:
        f.write(message)
    new = git("commit-tree", f"{sha}^{{tree}}", *[x for p in parents for x in ("-p", p)], "-F", f.name, env=env)
    os.unlink(f.name)
    return new


def main():
    plan = json.load(open(sys.argv[1]))
    base, tip = plan["base"], plan["tip"]
    first_parent = git("rev-list", "--first-parent", "--reverse", f"{base}..{tip}").split()
    covered = [s for u in plan["units"] for s in u["shas"]]
    full = [git("rev-parse", s) for s in covered]
    if full != first_parent:
        sys.exit("the plan's units don't cover main's first parent from the base, in order")
    # A base off the tip's first parent would chain commits it already has onto it again.
    check(not first_parent or git("rev-parse", f"{first_parent[0]}^") == git("rev-parse", base),
          "the base isn't on the tip's first parent")

    parent, made, moved = git("rev-parse", base), [], {}
    for u in plan["units"]:
        shas = [git("rev-parse", s) for s in u["shas"]]
        parents = [parent]
        if u.get("replay"):
            # A merge that landed after the review began keeps its branch, made again onto the
            # new history where it forked from the old, so no old commit comes back through it.
            first, *others = git("log", "-1", "--format=%P", shas[-1]).split()
            for c in git("rev-list", "--reverse", "--topo-order", *others, f"^{first}").split() if others else []:
                ps = git("log", "-1", "--format=%P", c).split()
                if any(p in moved for p in ps):
                    moved[c] = copy(c, [moved.get(p, p) for p in ps], with_sessions(git("log", "-1", "--format=%B", c), []))
                    made.append(dict(old=[c], new=moved[c], side=True))
            parents += [moved.get(o, o) for o in others]
        new = copy(shas[-1], parents, with_sessions(u["message"], u.get("sessions", [])))
        moved.update({s: new for s in shas})
        made.append(dict(old=u["shas"], new=new))
        parent = new

    # The checks: the same end state, each new commit's tree its unit's last tree.
    check(git("rev-parse", f"{parent}^{{tree}}") == git("rev-parse", f"{tip}^{{tree}}"), "the new tip's tree isn't the old tip's")
    for m in made:
        check(git("rev-parse", f"{m['new']}^{{tree}}") == git("rev-parse", f"{m['old'][-1]}^{{tree}}"), f"{m['old'][-1][:8]}'s tree changed")
    check(len(git("rev-list", "--first-parent", f"{base}..{parent}").split()) == len(plan["units"]), "the new history has the wrong number of commits")
    json.dump(made, open(sys.argv[1].replace(".json", ".map.json"), "w"), indent=1)
    print(parent)


if __name__ == "__main__":
    main()
