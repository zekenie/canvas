"""The weekly review of main's commit messages against the records of the sessions that made them
(SKILL.md, Weekly review). Every step reads and writes the run's folder, outside the repository,
and only `land` moves a ref or pushes.

    python3 review.py prepare [--base history-reviewed] [--tip main] [--dir DIR]
    python3 review.py args DIR [--only ID,...]          # the workflow's args, or a batch of them
    python3 review.py cost DIR <workflow run id>...
    python3 review.py collect DIR <workflow output file>...
    python3 review.py rebuild DIR [--message FILE] [--leave-unreviewed]
    python3 review.py land DIR
"""
import argparse, glob, json, os, re, subprocess, sys, tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECTS = os.path.expanduser("~/.claude/projects/")
RECORDS = "history/sessions"
# The owner's models (2026-10-18): "for the transcript reviews sonnet is fine. in cases where the
# commit message needs work i want it written w/ opus". Jev picks each stage's effort; these are
# the efforts when it can't be reached.
MODELS = {"review": "sonnet", "write": "opus", "verify": "sonnet", "revise": "opus"}
EFFORTS = {"review": "medium", "write": "high", "verify": "high", "revise": "medium"}
TASKS = {
    "review": "Read a condensed chat transcript (20-150 KB) of the coding session that produced one to three git commits, compare each commit message with what the owner asked for and decided, and list the missing intent with quoted evidence, wrong claims, and whether consecutive commits are one piece of work. Read-only, no writing of messages.",
    "write": "Write final git commit messages that carry a change's motivation, decisions, rejected alternatives and constraints for later agent readers, from a reviewer's findings, checking every added claim against the transcript and the code at that commit, in a dense house prose style.",
    "verify": "Adversarially check rewritten commit messages: for every new or changed sentence, find support in the session transcript and in the code at that commit, flag unsupported or overclaimed statements and lost facts. Report problems only.",
    "revise": "Apply a verifier's confirmed objections to a few commit messages, checking each objection first, and return the corrected messages in the same prose style.",
}
# $ per million tokens, at list price: input, cache write, cache read, output.
PRICE = {"opus": (5, 6.25, 0.5, 25), "sonnet": (3, 3.75, 0.3, 15), "haiku": (1, 1.25, 0.1, 5)}


def git_try(*args, cwd=None, env=None):
    r = subprocess.run(["git", *args], capture_output=True, text=True, cwd=cwd, env=env)
    return r.returncode == 0, (r.stdout if r.returncode == 0 else r.stderr).strip()


def git(*args, cwd=None, env=None):
    ok, out = git_try(*args, cwd=cwd, env=env)
    if not ok:
        sys.exit(f"git {' '.join(args[:2])}: {out}")
    return out


def ancestor(a, b):
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b]).returncode == 0


def load(path):
    return json.load(open(path))


def dump(value, path):
    json.dump(value, open(path, "w"), indent=1, ensure_ascii=False)


def main_checkout():
    return os.path.dirname(git("rev-parse", "--path-format=absolute", "--git-common-dir"))


def unique(path, ext=""):
    n, out = 1, path
    while os.path.exists(out + ext):
        n += 1
        out = f"{path}-{n}"
    return out + ext


def today():
    return datetime.now().strftime("%Y%m%d")


def first_parent(base, tip):
    """Main's first parent after the base, which must be on it: a base off it would have the
    rebuild chain commits it already has onto it again."""
    if not ancestor(base, tip):
        sys.exit(f"{base[:8]} isn't in {tip[:8]}'s history")
    fp = git("rev-list", "--first-parent", "--reverse", f"{base}..{tip}").split()
    if fp and git("rev-parse", f"{fp[0]}^") != base:
        sys.exit(f"{base[:8]} isn't on {tip[:8]}'s first parent")
    return fp


def is_merge(sha):
    return len(git("log", "-1", "--format=%P", sha).split()) > 1


def members_of(sha):
    """The commits a first-parent commit brings to main: itself, or a merge's branch, which the
    rebuild flattens into one commit with the merge's tree. A merge whose branch holds only
    merges brings itself."""
    parents = git("log", "-1", "--format=%P", sha).split()
    if len(parents) < 2:
        return [sha]
    return git("rev-list", "--reverse", "--no-merges", f"{parents[0]}..{parents[1]}").split() or [sha]


def message(sha):
    return git("log", "-1", "--format=%B", sha)


def trailer_records(msg):
    return [os.path.basename(p) for p in re.findall(r"^Session: (\S+)\s*$", msg, re.M)]


def records_at(rev):
    return {os.path.basename(p) for p in git("ls-tree", "--name-only", rev, f"{RECORDS}/").split()}


def run_condense(*args):
    r = subprocess.run([sys.executable, f"{HERE}/condense.py", *args], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"condense.py {' '.join(args[:1])}: {r.stderr.strip()}")
    return r.stdout.strip().splitlines()[-1]


def keep_name(path, in_repo):
    """A session already recorded in the repository keeps its record's name, so the new record
    replaces the old one."""
    m = re.search(r"-([0-9a-f]{8})\.md$", path)
    same = [n for n in in_repo if m and "-pr-" not in path and n.endswith(f"-{m.group(1)}.md")]
    if same and os.path.basename(path) != same[0]:
        os.replace(path, os.path.join(os.path.dirname(path), same[0]))
        return same[0]
    return os.path.basename(path)


# ---- prepare ---------------------------------------------------------------------------------

def patterns_for(msg):
    """Stretches of a message to find in the transcript that wrote it: its subject, and its body's
    first long line. JSON escapes quotes and backslashes, so a stretch stops at one."""
    lines = [l.strip() for l in msg.splitlines() if l.strip()]
    body = next((l for l in lines[1:] if len(l) > 40 and not re.match(r"^[A-Za-z-]+: ", l)), "")
    out = []
    for text, n in ((lines[0] if lines else "", 55), (body, 45)):
        piece = max(re.split(r'["\\\t]', text[:120]), key=len)[:n]
        if len(piece) >= 25:
            out.append(piece)
    return out


def strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from strings(x)


def session_start(proj, sid):
    path = f"{PROJECTS}{proj}/{sid}.jsonl"
    for line in open(path, errors="replace") if os.path.exists(path) else []:
        m = re.search(r'"timestamp":"([^"]+)"', line)
        if m:
            return m.group(1)[:19]
    return "~"


def find_authors(shas):
    """The session that wrote each commit's message: of the transcripts with the message's words
    in a tool call's input (a commit command, a message file), not only in output such as git log,
    the latest to write it by the time it was committed. A subagent's transcript counts for the
    session that ran it; this session, which quotes every message, is left out. Every project's
    transcripts are read, as a session may have started anywhere."""
    table = defaultdict(list)
    for sha in shas:
        for p in patterns_for(message(sha)):
            table[p].append(sha)
    if not table:
        return {}
    pats = [(p.encode(), p) for p in table]
    me = os.environ.get("CLAUDE_CODE_SESSION_ID")
    # A transcript last written before a commit was first made can't hold its message.
    since = min(int(git("log", "-1", "--format=%at", s)) for s in shas) - 2 * 86400
    wrote = defaultdict(dict)
    for folder, _, files in os.walk(PROJECTS):
        for name in files:
            path = os.path.join(folder, name)
            m = re.match(r"([^/]+)/([0-9a-f-]{36})", path[len(PROJECTS):])
            if not name.endswith(".jsonl") or not m or (me and me in path) or os.path.getmtime(path) < since:
                continue
            with open(path, "rb") as f:
                for line in f:
                    if b'"tool_use"' not in line:
                        continue
                    found = [p for b, p in pats if b in line]
                    if not found:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    for b in (d.get("message") or {}).get("content") or []:
                        if not (isinstance(b, dict) and b.get("type") == "tool_use") or not d.get("timestamp"):
                            continue
                        inp = "\n".join(strings(b.get("input", {})))
                        for p in found:
                            if p in inp:
                                for sha in table[p]:
                                    key = m.groups()
                                    wrote[sha][key] = min(wrote[sha].get(key, "~"), d["timestamp"][:19])

    out = {}
    for sha in shas:
        committed = datetime.fromisoformat(git("log", "-1", "--format=%cI", sha).replace("Z", "+00:00"))
        limit = (committed + timedelta(minutes=5)).astimezone(timezone.utc).isoformat()[:19]
        pool = [dict(proj=p, sid=s, wrote_at=t, start=session_start(p, s)) for (p, s), t in wrote[sha].items() if t <= limit]
        if not pool:
            continue
        # A session forked from the author copies its moments: the same minute goes to the one
        # that started first.
        latest = max(c["wrote_at"][:16] for c in pool)
        best = min((c for c in pool if c["wrote_at"][:16] == latest), key=lambda c: c["start"])
        out[sha] = [best] + sorted((c for c in pool if c is not best), key=lambda c: c["wrote_at"], reverse=True)
    return out


def pr_record(n, out_dir):
    """A cloud session's transcript isn't on this machine, so its pull request stands in: title,
    description, comments, reviews and review comments, and the commits it merged."""
    def gh(*args):
        r = subprocess.run(["gh", *args], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"gh {' '.join(args[:3])}: {r.stderr.strip()}")
        return r.stdout
    repo = gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner").strip()
    pr = json.loads(gh("pr", "view", n, "--json", "number,title,body,headRefName,createdAt,mergedAt,comments,reviews,commits"))
    inline = json.loads(gh("api", f"repos/{repo}/pulls/{n}/comments"))
    lines = [f"# PR #{pr['number']}: {pr['title']}\n\n",
             f"Branch {pr['headRefName']}, opened {pr['createdAt']}, merged {pr['mergedAt']}.\n\n",
             "Made by a Claude Code session in the cloud; its transcript isn't on this machine, so this PR is the record of it.\n",
             f"\n## Description\n\n{pr['body']}\n", "\n## Commits\n"]
    lines += [f"- {c['oid'][:8]} {c['messageHeadline']}\n" for c in pr["commits"]]
    lines += [f"\n## Comment by {c['author']['login']} at {c['createdAt']}\n\n{c['body']}\n" for c in pr["comments"]]
    lines += [f"\n## Review by {r['author']['login']} ({r['state']}) at {r['submittedAt']}\n\n{r['body']}\n"
              for r in pr["reviews"] if r.get("body")]
    lines += [f"\n## Review comment by {c['user']['login']} on {c['path']}:{c.get('line')} at {c['created_at']}\n\n{c['body']}\n"
              for c in inline]
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", pr["title"].lower())).strip("-")[:60]
    name = f"{pr['createdAt'][:10]}-pr-{n}-{slug}.md"
    open(f"{out_dir}/{name}", "w").write("".join(lines))
    return name


def routes(run):
    dump(TASKS, f"{run}/jev-tasks.json")
    r = subprocess.run([sys.executable, f"{main_checkout()}/.claude/skills/jev-route/route.py", f"{run}/jev-tasks.json"],
                       capture_output=True, text=True)
    jev = json.loads(r.stdout) if r.returncode == 0 else {}
    if not jev:
        print(f"Jev: {r.stderr.strip() or 'no answer'}; the efforts are the defaults")
    return {s: dict(model=MODELS[s], effort=(jev.get(s) or {}).get("effort", EFFORTS[s])) for s in MODELS}


def prepare(a):
    base, tip = git("rev-parse", f"{a.base}^{{commit}}"), git("rev-parse", f"{a.tip}^{{commit}}")
    fp = first_parent(base, tip)
    if a.tip == "main":
        git("fetch", "-q", "origin")
        if not ancestor("refs/remotes/origin/main", tip):
            sys.exit("origin/main has commits main lacks: bring them to main first, or the landing will refuse")
    checkout = main_checkout()
    run = os.path.abspath(a.dir) if a.dir else unique(
        f"{os.path.dirname(checkout)}/{os.path.basename(checkout)}-backups/history-review-{today()}")
    if os.path.exists(f"{run}/prepare.json"):
        sys.exit(f"{run} has a run already: give a new --dir")
    for sub in ("records", "backfill"):
        os.makedirs(f"{run}/{sub}", exist_ok=True)
    in_repo = records_at(tip)

    units = []
    for pos, sha in enumerate(fp, 1):
        merge, members = is_merge(sha), members_of(sha)
        changed = git("diff-tree", "--no-commit-id", "--name-only", "-r", "-m", "--first-parent", sha).split()
        commits = []
        for m in members:
            msg = message(m)
            commits.append(dict(sha=m, subject=msg.splitlines()[0], records=trailer_records(msg)))
        merged = re.search(r"^Merge pull request #(\d+)", message(sha)) if merge else None
        squashed = re.search(r"\(#(\d+)\)$", commits[0]["subject"]) if not merge else None
        units.append(dict(pos=pos, sha=sha, merge=merge, commits=commits,
                          pr=(merged or squashed).group(1) if merged or squashed else None,
                          # A commit that only adds records (a review's own) isn't reviewed.
                          skip=bool(changed) and all(p.startswith(f"{RECORDS}/") for p in changed)))

    unmapped = [c["sha"] for u in units if not u["skip"] for c in u["commits"] if not c["records"]]
    authors = find_authors(unmapped)
    dump({sha: dict(sha=sha, subject=message(sha).splitlines()[0], candidates=c) for sha, c in authors.items()},
         f"{run}/commit_sessions.json")
    condensed = {}
    for sid in dict.fromkeys(c[0]["sid"] for c in authors.values()):
        path = run_condense(sid, "--out", f"{run}/backfill", "--commits", f"{run}/commit_sessions.json")
        condensed[sid] = keep_name(path, in_repo)
    prs = {}
    for u in units:
        for c in u["commits"]:
            if not c["records"] and c["sha"] in authors:
                c["records"], c["source"] = [condensed[authors[c["sha"]][0]["sid"]]], "transcript"
            else:
                c["source"] = "trailer" if c["records"] else "none"
        # A pull request's record goes beside its sessions' unless they named their own.
        if u["pr"] and not u["skip"] and (u["merge"] or u["commits"][0]["source"] != "trailer"):
            if u["pr"] not in prs:
                found = [n for n in in_repo if f"-pr-{u['pr']}-" in n]
                prs[u["pr"]] = found[0] if found else pr_record(u["pr"], f"{run}/backfill")
            u["pr_record"] = prs[u["pr"]]

    backfill = sorted(os.listdir(f"{run}/backfill"))
    named = {r for u in units for c in u["commits"] for r in c["records"]} | {u["pr_record"] for u in units if u.get("pr_record")}
    for name in sorted(named - set(backfill)):
        if name not in in_repo:
            sys.exit(f"a Session: trailer names {RECORDS}/{name}, which isn't in the repository at {tip[:8]}")
        open(f"{run}/records/{name}", "w").write(git("show", f"{tip}:{RECORDS}/{name}") + "\n")

    def where(name):
        return f"{run}/{'backfill' if name in backfill else 'records'}/{name}"

    def raw(name):
        m = re.search(r"-([0-9a-f]{8})\.md$", name)
        return sorted(glob.glob(f"{PROJECTS}*/{m.group(1)}*.jsonl")) if m and "-pr-" not in name else []

    groups = {}
    for u in units:
        names = [r for c in u["commits"] for r in c["records"]] + ([u["pr_record"]] if u.get("pr_record") else [])
        if not u["skip"] and names:
            groups.setdefault(tuple(sorted(set(names))), []).append(u)
    out = []
    for names, us in groups.items():
        sessions = [n for n in names if "-pr-" not in n] + [n for n in names if "-pr-" in n]
        title = re.sub(r"^\d{4}-\d\d-\d\d-|-[0-9a-f]{8}\.md$|\.md$", "", sessions[0])[:40]
        notes, must = [], False
        for u in us:
            if u["merge"] and len(u["commits"]) > 1:
                must = True
                notes.append(f"PR #{u['pr']}'s commits {', '.join(c['sha'][:8] for c in u['commits'])} come into main through the merge {u['sha'][:8]}; the new history flattens them and the merge into one commit with the merge's tree, so they are one squash run: list them as one, and its one message must be written.")
            elif u["merge"] and u["commits"][0]["sha"] != u["sha"]:
                notes.append(f"{u['commits'][0]['sha'][:8]} comes into main through the merge {u['sha'][:8]} (PR #{u['pr']}); the new history flattens the two into one commit with the merge's tree, so review {u['commits'][0]['sha'][:8]}'s message as that commit's (GitHub's merge message is dropped).")
        if all("-pr-" in n for n in names):
            notes.insert(0, "These commits were made by Claude Code sessions in the cloud, whose transcripts are not on this machine; each session record above is the pull request's (description, comments and commits). The owner's own request is lost, so do not invent a motivation the PR doesn't state.")
        elif any("-pr-" in n for n in names):
            notes.insert(0, "The pull request's record is given beside the session's.")
        positions = [u["pos"] for u in us]
        if positions != list(range(positions[0], positions[0] + len(positions))):
            notes.append("This session's commits are not all next to each other on main: only a consecutive run may be squashed.")
        out.append(dict(id=f"{us[0]['pos']}-{title}", first=us[0]["pos"],
                        commits=[dict(n=u["pos"], sha=c["sha"], subject=c["subject"]) for u in us for c in u["commits"]],
                        sessions=[where(n) for n in sessions], raw=[r for n in sessions for r in raw(n)],
                        note=" ".join(notes), mustWrite=must))
    out.sort(key=lambda g: g["first"])

    dump(dict(base=base, tip=tip, units=units, backfill=backfill, condensed=condensed), f"{run}/prepare.json")
    proj = re.sub(r"[^A-Za-z0-9]", "-", checkout)
    rs = routes(run)
    dump(dict(repo=git("rev-parse", "--show-toplevel"), memory=f"{PROJECTS}{proj}/memory", routes=rs, groups=out),
         f"{run}/args.json")

    reviewed = [(u, c) for u in units if not u["skip"] for c in u["commits"]]
    print(f"{run}\n")
    print(f"{len(reviewed)} commits from {base[:8]} to {tip[:8]} in {len(out)} groups"
          f" ({sum(1 for u in units if u['skip'])} commits that only add records left out)")
    for g in out:
        kb = sum(os.path.getsize(s) for s in g["sessions"]) // 1000
        print(f"  {g['id'][:48]:48s} {len(g['commits']):2d} commits {kb:5d} KB{'  must write' if g['mustWrite'] else ''}")
    print(f"records named by a Session: trailer: {sum(1 for _, c in reviewed if c['source'] == 'trailer')} commits; "
          f"found from transcripts: {sum(1 for _, c in reviewed if c['source'] == 'transcript')}")
    if backfill:
        print(f"records to add at the tip: {', '.join(backfill)}")
    none = [c for u, c in reviewed if not c["records"] and not u.get("pr_record")]
    if none:
        print("no record, so not reviewed:")
        print("\n".join(f"  {c['sha'][:8]} {c['subject'][:80]}" for c in none))
    print("routes: " + ", ".join(f"{s} {r['model']}/{r['effort']}" for s, r in rs.items()))


def args_cmd(a):
    args = load(f"{a.dir}/args.json")
    if a.only:
        only = set(a.only.split(","))
        args["groups"] = [g for g in args["groups"] if g["id"] in only]
    print(json.dumps(args, ensure_ascii=False))


# ---- cost ------------------------------------------------------------------------------------

def cost(a):
    """Tokens each workflow agent used, from its transcript, with a price at list rates. A
    streamed message's lines carry placeholder output counts, and only a last line with the stop
    reason has the real one, which most messages' transcripts lack: those are estimated from what
    was written, about four characters a token, and for thinking, whose text the transcript
    leaves out, from its signature (base64, so three bytes in four characters)."""
    lines, total = [], 0.0
    for run_id in a.runs:
        dirs = glob.glob(f"{PROJECTS}*/*/subagents/workflows/{run_id}*")
        if not dirs:
            sys.exit(f"no transcripts for workflow {run_id} under {PROJECTS}")
        stage = defaultdict(lambda: [0, 0, 0.0])
        for f in sorted(glob.glob(f"{dirs[0]}/agent-*.jsonl")):
            meta = f[:-6] + ".meta.json"
            label = (load(meta).get("description") or "") if os.path.exists(meta) else ""
            tot, model, outs = [0, 0, 0], None, {}
            for line in open(f, errors="replace"):
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                m = j.get("message") or {}
                u = m.get("usage")
                if j.get("type") != "assistant" or not u:
                    continue
                key = m.get("id")
                if key not in outs:
                    outs[key] = dict(out=0, stopped=False, written=0)
                    model = m.get("model") or model
                    tot[0] += u.get("input_tokens", 0)
                    tot[1] += u.get("cache_creation_input_tokens", 0)
                    tot[2] += u.get("cache_read_input_tokens", 0)
                o = outs[key]
                o["out"] = max(o["out"], u.get("output_tokens", 0))
                o["stopped"] |= bool(m.get("stop_reason"))
                for b in m.get("content") or []:
                    o["written"] += (len(b.get("signature", "")) * 3 // 16 if b.get("type") == "thinking"
                                     else len(json.dumps(b, ensure_ascii=False)) // 4)
            output = sum(o["out"] if o["stopped"] else max(o["out"], o["written"]) for o in outs.values())
            p = PRICE[next((k for k in PRICE if k in (model or "")), "opus")]
            usd = (tot[0] * p[0] + tot[1] * p[1] + tot[2] * p[2] + output * p[3]) / 1e6
            s = stage[label.split(":")[0] or "agent"]
            s[0] += 1
            s[1] += sum(tot) + output
            s[2] += usd
        for name, (n, tokens, usd) in stage.items():
            lines.append(f"{run_id} {name:8s} {n:3d} agents {tokens / 1e6:6.2f}M tokens ${usd:7.2f}")
            total += usd
    lines.append(f"total ${total:.2f}")
    print("\n".join(lines))
    with open(f"{a.dir}/cost.txt", "a") as f:
        f.write("\n".join(lines) + "\n")


# ---- collect ---------------------------------------------------------------------------------

def collect(a):
    """Gather workflow runs' final messages into proposals.json, a later run of a group replacing
    an earlier one's, and write proposed-messages.md for the owner to read."""
    prep, groups = load(f"{a.dir}/prepare.json"), load(f"{a.dir}/args.json")["groups"]
    order = {c["sha"]: i for i, c in enumerate(c for u in prep["units"] for c in u["commits"])}
    unit_of = {c["sha"]: i for i, u in enumerate(prep["units"]) for c in u["commits"]}
    path = f"{a.dir}/proposals.json"
    props = load(path) if os.path.exists(path) else {}
    for k, v in dict(messages=[], reviews={}, declined=[], unverified=[], failed=[]).items():
        props.setdefault(k, v)

    def resolve(sha):
        ok, out = git_try("rev-parse", "--verify", "-q", f"{sha}^{{commit}}")
        return out if ok and out in order else None

    bad = []
    for f in a.outputs:
        r = load(f)
        r = r if isinstance(r, list) else r.get("result", r)
        rerun = {g["id"] for g in r}
        for k in ("messages", "declined"):
            props[k] = [m for m in props[k] if m["group"] not in rerun]
        for k in ("unverified", "failed"):
            props[k] = [g for g in props[k] if g not in rerun]
        props["reviews"] = {s: v for s, v in props["reviews"].items() if v["group"] not in rerun}
        for g in r:
            for c in g["review"]["commits"]:
                sha = resolve(c["sha"])
                if sha:
                    props["reviews"][sha] = dict(group=g["id"], verdict=c["verdict"], intent=c["intent_summary"])
            for m in (g.get("final") or {}).get("messages", []):
                shas = [resolve(s) for s in m["shas"]]
                if None in shas:
                    bad.append(f"{g['id']}: {', '.join(m['shas'])}")
                    continue
                shas.sort(key=order.get)
                props["messages"] = [p for p in props["messages"] if p["shas"] != shas]
                props["messages"].append(dict(group=g["id"], shas=shas, message=m["message"], notes=m["notes"]))
            props["declined"] += [dict(group=g["id"], **d) for d in (g.get("written") or {}).get("declined", [])]
            if g.get("unverified"):
                props["unverified"].append(g["id"])
            if g.get("writeFailed"):
                props["failed"].append(g["id"])
    dump(props, path)

    reviewed = {r["group"] for r in props["reviews"].values()}
    missing = [g["id"] for g in groups if g["id"] not in reviewed]
    msgs = sorted(props["messages"], key=lambda m: order.get(m["shas"][0], 0))
    covered = {s for m in msgs for s in m["shas"]}
    wanting = [(s, r) for s, r in props["reviews"].items() if r["verdict"] != "keep" and s not in covered]
    squashes = sum(1 for m in msgs if len({unit_of[s] for s in m["shas"]}) > 1)
    kept = sum(1 for r in props["reviews"].values() if r["verdict"] == "keep")
    fence = "````"
    out = ["# Proposed commit messages\n\n",
           f"{len(props['reviews'])} commits reviewed, from {prep['base'][:8]} to {prep['tip'][:8]}; {kept} kept as they are. "
           f"{len(msgs)} messages below replace {sum(len(m['shas']) for m in msgs)} commits' messages ({squashes} squash runs).\n"]
    if missing:
        out.append(f"\nNot reviewed yet (no result): {', '.join(missing)}.\n")
    if props["failed"]:
        out.append(f"\nReviewed, but the writer didn't finish, so they need another run: {', '.join(props['failed'])}.\n")
    if wanting:
        out.append("\nJudged wanting, with no message written:\n\n")
        out += [f"- `{s[:8]}` ({r['verdict']}, {r['group']}): {r['intent']}\n" for s, r in sorted(wanting, key=lambda x: order[x[0]])]
    for m in msgs:
        subject = m["message"].splitlines()[0]
        span = f"`{m['shas'][0][:8]}`" if len(m["shas"]) == 1 else f"`{m['shas'][0][:8]}`..`{m['shas'][-1][:8]}` ({len(m['shas'])} commits)"
        before = "\n\n".join(message(s) for s in m["shas"])
        flag = "\n\n**Not checked:** the verifier or the revision didn't finish, so this is the writer's draft." if m["group"] in props["unverified"] else ""
        out += [f"\n---\n\n## {span} {subject}\n\n**What changed:** {m['notes']}{flag}\n\n",
                f"<details><summary>Before</summary>\n\n{fence}\n{before}\n{fence}\n</details>\n\n",
                f"**After**\n\n{fence}\n{m['message'].rstrip()}\n{fence}\n"]
    if props["declined"]:
        out.append("\n---\n\n## Findings the writers didn't take\n\n")
        out += [f"- {d['group']}: {d['what']} ({d['reason']})\n" for d in props["declined"]]
    open(f"{a.dir}/proposed-messages.md", "w").write("".join(out))
    print(f"{len(props['reviews'])} commits reviewed, {len(msgs)} messages written"
          + (f", {len(props['unverified'])} groups unverified" if props["unverified"] else "")
          + (f"; writer failed for {', '.join(props['failed'])}" if props["failed"] else "")
          + (f"; no result for {', '.join(missing)}" if missing else ""))
    if bad:
        print("messages left out, naming commits that aren't under review:\n  " + "\n  ".join(bad))
    print(f"{a.dir}/proposed-messages.md")


# ---- rebuild ---------------------------------------------------------------------------------

def rebuild(a):
    """The plan for main's first parent from the base to its tip now, with the proposed messages
    and each commit's records as Session: trailers; rebuild.py makes it and checks every tree. A
    commit that landed after prepare is replayed as it is, merges included. Records found from
    transcripts go in one commit at the tip, with this session's."""
    sys.path.insert(0, HERE)
    from rebuild import with_sessions
    prep, groups = load(f"{a.dir}/prepare.json"), load(f"{a.dir}/args.json")["groups"]
    props = load(f"{a.dir}/proposals.json") if os.path.exists(f"{a.dir}/proposals.json") else {}
    base, tip = prep["base"], git("rev-parse", "refs/heads/main")
    fp = first_parent(base, tip)
    if prep["tip"] != base and prep["tip"] not in fp:
        sys.exit(f"main no longer has {prep['tip'][:8]} on its first parent: its history was rewritten since prepare")
    reviewed = {r["group"] for r in props.get("reviews", {}).values()} - set(props.get("failed", []))
    unreviewed = [g["id"] for g in groups if g["id"] not in reviewed]
    if unreviewed and not a.leave_unreviewed:
        sys.exit(f"{len(unreviewed)} groups have no finished review ({', '.join(unreviewed)}): run them again with "
                 "`args --only`, or pass --leave-unreviewed, and they won't come up again")
    backfill = sorted(os.listdir(f"{a.dir}/backfill"))
    if backfill and not a.message:
        sys.exit(f"{len(backfill)} records to add at the tip ({', '.join(backfill)}): write that commit's message "
                 "to a file and pass --message")
    if backfill and not os.environ.get("CLAUDE_CODE_SESSION_ID"):
        sys.exit("the records commit carries this session's record: run rebuild from the Claude Code session doing the review")

    # A session found from transcripts may have landed again since, under a name of its own:
    # its record takes that name. Each is condensed again, as it may have gone on.
    now = records_at(tip)
    rename = {n: keep_name(f"{a.dir}/backfill/{n}", now) for n in backfill}
    for sid in prep.get("condensed", {}):
        run_condense(sid, "--out", f"{a.dir}/backfill", "--commits", f"{a.dir}/commit_sessions.json")

    end = fp.index(prep["tip"]) if prep["tip"] in fp else -1
    info = {u["sha"]: u for u in prep["units"]}
    members = {s: [c["sha"] for c in info[s]["commits"]] for s in fp[:end + 1]}
    at = {m: i for i, s in enumerate(fp[:end + 1]) for m in members[s]}

    spans = {}
    for m in props.get("messages", []):
        idx = [at.get(s) for s in m["shas"]]
        if None in idx:
            sys.exit(f"a message was written for {m['shas'][0][:8]}, which isn't among the commits reviewed")
        i, j = min(idx), max(idx)
        if [x for k in range(i, j + 1) for x in members[fp[k]]] != m["shas"]:
            sys.exit(f"the message for {m['shas'][0][:8]}.. doesn't cover whole consecutive commits of main, in order")
        if any(p <= j and i <= q for p, q in spans):
            sys.exit(f"two messages cover {fp[i][:8]}")
        spans[(i, j)] = m["message"]

    def records(sha):
        u = info[sha]
        names = [r for c in u["commits"] for r in c["records"]] + ([u["pr_record"]] if u.get("pr_record") else [])
        return [rename.get(n, n) for n in names]

    units, k, starts = [], 0, {i: (i, j) for i, j in spans}
    while k <= end:
        i, j = starts.get(k, (k, k))
        shas, text = fp[i:j + 1], spans.get((i, j))
        if text is None:
            if len(members[fp[k]]) > 1:
                sys.exit(f"{fp[k][:8]} merges {len(members[fp[k]])} commits and no message was written for them")
            text = message(members[fp[k]][0])
        names = list(dict.fromkeys(r for s in shas for r in records(s)))
        units.append(dict(shas=shas, message=text, sessions=[f"{RECORDS}/{n}" for n in names]))
        k = j + 1
    units += [dict(shas=[s], message=message(s), sessions=[], replay=True) for s in fp[end + 1:]]
    plan = f"{a.dir}/plan.json"
    dump(dict(base=base, tip=tip, units=units), plan)
    r = subprocess.run([sys.executable, f"{HERE}/rebuild.py", plan], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr.strip() or r.stdout.strip())
    rebuilt = r.stdout.strip()
    made = load(plan.replace(".json", ".map.json"))
    moved = {o: m["new"] for m in made for o in m["old"]}

    final = rebuilt
    if backfill:
        own = keep_name(run_condense("--self", "--out", f"{a.dir}/backfill"), now)
        index = f"{a.dir}/records.index"
        env = dict(os.environ, GIT_INDEX_FILE=index)
        git("read-tree", rebuilt, env=env)
        for name in sorted(os.listdir(f"{a.dir}/backfill")):
            blob = git("hash-object", "-w", f"{a.dir}/backfill/{name}")
            git("update-index", "--add", "--cacheinfo", f"100644,{blob},{RECORDS}/{name}", env=env)
        tree = git("write-tree", env=env)
        os.unlink(index)
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".msg") as f:
            f.write(with_sessions(open(a.message).read(), [f"{RECORDS}/{own}"]))
        final = git("commit-tree", tree, "-p", rebuilt, "-F", f.name)
        os.unlink(f.name)

    dump(dict(base=base, old_tip=tip, rebuilt=rebuilt, final=final, reviewed=moved.get(prep["tip"], prep["tip"]),
              moved=moved), f"{a.dir}/rebuilt.json")
    changed = sum(1 for m in made if len(m["old"]) > 1 or message(m["new"]) != message(m["old"][0]))
    print(f"{len(units)} commits after {base[:8]}: {changed} with a new message or trailer, "
          f"{sum(1 for u in units if len(u['shas']) > 1)} squash runs; {len(fp) - end - 1} landed since prepare, replayed as they are")
    if unreviewed:
        print(f"left unreviewed, for good: {', '.join(unreviewed)}")
    print(f"rebuilt {rebuilt[:8]}, every tree the same" + (f"; records commit {final[:8]} on it" if final != rebuilt else ""))
    print("main is untouched: review.py land moves it")


# ---- land ------------------------------------------------------------------------------------

def land(a):
    """Back up, then push the new main and the tags to origin in one atomic push with a lease on
    what origin had, and only then move main here (by compare-and-swap) and the tags."""
    r = load(f"{a.dir}/rebuilt.json")
    main = git("rev-parse", "refs/heads/main")
    if main != r["old_tip"]:
        sys.exit(f"main moved since rebuild (it's {main[:8]}, the plan was built on {r['old_tip'][:8]}): run rebuild again")
    git("fetch", "-q", "origin")
    origin = git("rev-parse", "refs/remotes/origin/main")
    if not ancestor(origin, main):
        sys.exit(f"origin/main ({origin[:8]}) has commits main lacks: bring them to main first")
    checkout = main_checkout()
    backups = f"{os.path.dirname(checkout)}/{os.path.basename(checkout)}-backups"
    os.makedirs(backups, exist_ok=True)
    backup = unique(f"{backups}/{os.path.basename(checkout)}-{today()}-pre-history-review", ".git")
    git("clone", "-q", "--mirror", checkout, backup)
    if git("rev-parse", "refs/heads/main", cwd=backup) != main:
        sys.exit(f"the backup at {backup} doesn't have main at {main[:8]}")
    tag, n = f"pre-history-review-{today()}", 1
    while git("tag", "-l", tag):
        n += 1
        tag = f"pre-history-review-{today()}-{n}"

    # All or nothing at origin, and nothing here moves unless origin took it.
    git("push", "-q", "--atomic", f"--force-with-lease=refs/heads/main:{origin}", "origin",
        f"{r['final']}:refs/heads/main", f"{main}:refs/tags/{tag}", f"+{r['reviewed']}:refs/tags/history-reviewed")
    git("tag", tag, main)
    git("tag", "-f", "history-reviewed", r["reviewed"])
    behind = None
    if r["final"] != main:
        ok, _ = git_try("update-ref", "-m", "history review: messages rewritten, every tree kept", "refs/heads/main", r["rebuilt"], main)
        if not ok:
            behind = "main here moved during the push, so it wasn't moved"
        elif r["final"] != r["rebuilt"]:
            # The records commit adds files: the checkout that has main out takes them by a
            # fast-forward, so its working tree has them too.
            wts = [w.splitlines() for w in git("worktree", "list", "--porcelain").split("\n\n")]
            holder = next((w[0][len("worktree "):] for w in wts if "branch refs/heads/main" in w), None)
            ok, err = (git_try("merge", "--ff-only", "-q", r["final"], cwd=holder) if holder
                       else git_try("update-ref", "refs/heads/main", r["final"], r["rebuilt"]))
            if not ok:
                behind = f"main here is at {r['rebuilt'][:8]}, without the records commit ({err})"
    git("fetch", "-q", "origin")
    print(f"origin/main is {git('rev-parse', '--short', 'refs/remotes/origin/main')}; {tag} marks the old tip {main[:8]}; "
          f"history-reviewed is {r['reviewed'][:8]}; backup {backup}")
    if behind:
        print(f"{behind}: `git merge --ff-only origin/main` in the checkout that has main brings it up")

    moved = {o: n for o, n in r["moved"].items() if o != n}
    stale = []
    for b in git("for-each-ref", "--format=%(refname:short)", "refs/heads/").split():
        ok, fork = git_try("merge-base", b, main) if b != "main" else (False, "")
        if ok and fork in moved:
            stale.append(f"git rebase --onto {moved[fork][:12]} {fork[:12]} {b}")
    if stale:
        print("branches built on the old history, for their sessions to move:")
        print("\n".join(f"  {s}" for s in stale))


def cli():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--base", default="history-reviewed")
    p.add_argument("--tip", default="main")
    p.add_argument("--dir")
    p = sub.add_parser("args")
    p.add_argument("dir")
    p.add_argument("--only")
    p = sub.add_parser("cost")
    p.add_argument("dir")
    p.add_argument("runs", nargs="+")
    p = sub.add_parser("collect")
    p.add_argument("dir")
    p.add_argument("outputs", nargs="+")
    p = sub.add_parser("rebuild")
    p.add_argument("dir")
    p.add_argument("--message")
    p.add_argument("--leave-unreviewed", action="store_true")
    p = sub.add_parser("land")
    p.add_argument("dir")
    a = ap.parse_args()
    if getattr(a, "dir", None):
        a.dir = os.path.abspath(a.dir)
    dict(prepare=prepare, args=args_cmd, cost=cost, collect=collect, rebuild=rebuild, land=land)[a.cmd](a)


if __name__ == "__main__":
    cli()
