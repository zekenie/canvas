"""Write a Claude Code session's record to history/sessions/<date>-<title>-<session>/:
transcript.md, its transcript condensed to what carries intent (the owner's messages in full, the
questions asked and their answers, refusals, the assistant's prose, plans, agent briefs,
design-doc writes and git commands; tool output is left out), and plans/, the plan files the
session and its agents wrote. Anything shaped like a key is redacted from both.

    python3 condense.py --self [--out DIR]           # this session (CLAUDE_CODE_SESSION_ID)
    python3 condense.py <session id> [--out DIR] [--commits FILE]

--commits names a JSON map of main's commits to the sessions that wrote them (the
commit_sessions.json `review.py prepare` writes: {sha: {subject, candidates: [{sid, wrote_at},
...]}}, the author first), so the transcript marks where each commit's message was written.
Prints the record's directory.
"""
import argparse, glob, json, os, re, sys

PROJECTS = os.path.expanduser("~/.claude/projects/")
PLAN_MODE = os.path.expanduser("~/.claude/plans")
SCRATCH = os.path.join(os.path.realpath("/tmp"), f"claude-{os.getuid()}")
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
REFUSED = ("The user doesn't want to proceed", "The user rejected", "User rejected")
SECRETS = [
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bxox[abposr]-[A-Za-z0-9\-]{10,}"),
    # A value set for a key-like name, long and mixing letters and digits as generated keys do.
    re.compile(r"(?i)((?:api[_-]?key|secret|token|password)[\"']?\s*[=:]\s*[\"']?)(?=[A-Za-z0-9_\-\.]*\d)(?=[A-Za-z0-9_\-\.]*[A-Za-z])[A-Za-z0-9_\-\.]{32,}"),
]


def scrub(s):
    for p in SECRETS:
        s = p.sub(lambda m: (m.group(1) if m.groups() else "") + "[REDACTED]", s)
    return s


def cap(s, n):
    s = s.strip()
    return s if len(s) <= n else s[:n] + f" […{len(s) - n} more chars]"


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def session_files(sid):
    return sorted(set(glob.glob(f"{PROJECTS}*/{sid}.jsonl")))


def slug(s):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", s.lower())).strip("-")[:60] or "session"


# ---- plans -----------------------------------------------------------------------------------

def plan_name(path, sid, plan_dirs, stems):
    """Where a file the session wrote goes in its record's plans/, or None when it isn't a plan.
    A plan is a plan-mode file (any markdown in ~/.claude/plans, and in a plansDirectory of the
    project's only the session's own, named for its plan), or markdown in the session's
    scratchpad named for a plan or kept in a plan/ or plans/ folder at its top; not one under such
    a folder deeper down, which is a copy of a record or a fixture's, nor one in a checkout of a
    repository the scratchpad holds, whose plans land with its own commits."""
    folder, base = os.path.split(path)
    if folder in plan_dirs and base.endswith(".md") and (
            folder == PLAN_MODE or re.sub(r"-agent-[^/]+$", "", base.removesuffix(".md")) in stems):
        return base
    root, _, rel = path.partition(f"/{sid}/scratchpad/")
    if not rel or not rel.endswith(".md"):
        return None
    parts = rel.split("/")
    if not (re.search(r"(?<![a-z])plan", parts[-1], re.I) or (len(parts) > 1 and parts[0].lower() in ("plan", "plans"))):
        return None
    if "docs" in parts[:-1] or any(p.lower() in ("plan", "plans") for p in parts[1:-1]) or any(os.path.exists(os.path.join(root, sid, "scratchpad", *parts[:i], ".git"))
                                   for i in range(1, len(parts))):
        return None
    return rel


def replay(ops):
    """A file's text as the session's writes, edits and plan-mode exits left it, in time order, or
    None when they start from text the transcript doesn't hold (a file written by a shell command)."""
    text = None
    for name, inp, result in ops:
        if name == "Write":
            text = inp.get("content", "")
        elif name == "ExitPlanMode":
            text = result.get("plan") or inp.get("plan") or text
        else:
            for e in inp.get("edits") or [inp]:
                old, new = e.get("old_string", ""), e.get("new_string", "")
                if text is None and not old:
                    text = new  # an edit that makes the file
                elif text is None or old not in text:
                    # Changed out of the transcript's sight: lost until a whole write gives it again.
                    text = None
                    break
                else:
                    text = text.replace(old, new) if e.get("replace_all") else text.replace(old, new, 1)
    return text


def plans(sid):
    """The plan files the session and its agents wrote, {path in plans/: text}: each as it is on
    disk, or as the transcript's tool calls left it once it's gone."""
    files = session_files(sid) + sorted(glob.glob(f"{PROJECTS}*/{sid}/subagents/*.jsonl"))
    calls, results, failed, slugs = {}, {}, set(), set()
    for f in files:
        for line in open(f, errors="replace"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("slug"):
                slugs.add(d["slug"])
            content = (d.get("message") or {}).get("content")
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") in ("Write", "Edit", "MultiEdit", "ExitPlanMode"):
                    calls[b.get("id")] = (d.get("timestamp") or "", b["name"], b.get("input") or {})
                elif b.get("type") == "tool_result":
                    if b.get("is_error"):
                        failed.add(b.get("tool_use_id"))
                    if isinstance(d.get("toolUseResult"), dict):
                        results[b.get("tool_use_id")] = d["toolUseResult"]
    ops = {}
    for cid, (ts, name, inp) in sorted(calls.items(), key=lambda c: c[1][0]):
        result = results.get(cid, {})
        if name == "ExitPlanMode":
            # A plan turned down was still the file's text when it was shown.
            path = result.get("filePath") or inp.get("planFilePath")
        elif cid in failed:
            continue
        else:
            path = inp.get("file_path")
        if path:
            ops.setdefault(path, []).append((name, inp, result))
    shown = [p for p, o in ops.items() if any(n == "ExitPlanMode" for n, _, _ in o)]
    plan_dirs = {PLAN_MODE} | {os.path.dirname(p) for p in shown}
    stems = slugs | {os.path.basename(p).removesuffix(".md") for p in shown}
    on_disk = [p for d in plan_dirs for s in stems for p in glob.glob(f"{d}/{s}.md") + glob.glob(f"{d}/{s}-agent-*.md")]
    for pad in glob.glob(f"{SCRATCH}/*/{sid}/scratchpad"):
        for dirpath, dirs, names in os.walk(pad):
            if ".git" in dirs or ".git" in names:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if d != "node_modules"]
            on_disk += [os.path.join(dirpath, n) for n in names]
    out = {}
    for path in sorted(set(ops) | set(on_disk)):
        name = plan_name(path, sid, plan_dirs, stems)
        if not name:
            continue
        text = open(path, errors="replace").read() if os.path.isfile(path) else replay(ops.get(path, []))
        if text is not None:
            out[name] = scrub(text)
    return out


def read(sid):
    """The session's entries in time order, and what it was called and where it ran."""
    entries, seen, tools = [], set(), {}
    meta = dict(title=None, branches=[], first=None, last=None)
    for f in session_files(sid):
        for line in open(f, errors="replace"):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get("type")
            if t == "custom-title":
                meta["title"] = d.get("customTitle") or meta["title"]
                continue
            if d.get("uuid") in seen or d.get("isSidechain"):
                continue
            seen.add(d.get("uuid"))
            ts = d.get("timestamp") or ""
            if ts:
                meta["first"] = min(filter(None, [meta["first"], ts]))
                meta["last"] = max(filter(None, [meta["last"], ts]))
            b = d.get("gitBranch")
            if b and b != "HEAD" and b not in meta["branches"]:
                meta["branches"].append(b)
            if t == "attachment":
                a = d.get("attachment") or {}
                if a.get("type") == "queued_command" and (a.get("origin") or {}).get("kind") == "human":
                    entries.append((ts, "USER (sent mid-turn)", typed(a.get("prompt", ""))))
            elif t == "user":
                user_entries(d, ts, tools, entries)
            elif t == "assistant":
                assistant_entries(d, ts, tools, entries)
    entries.sort(key=lambda e: e[0])
    return entries, meta


def typed(content):
    """What a person typed or attached: the text, with an image or file noted, never its bytes."""
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if isinstance(b, dict) and b.get("type") == "text":
            out.append(b.get("text", ""))
        elif isinstance(b, dict) and b.get("type") in ("image", "document"):
            out.append(f"[{b['type']} attached]")
    return "\n".join(out)


def user_text(txt):
    """A user turn's text as the record keeps it: what the owner typed in full; what the app
    or a finished agent put in a user turn cut down to what it says, or left out."""
    if txt.startswith("<task-notification>"):
        summary = re.search(r"<summary>(.*?)</summary>", txt, re.S)
        status = re.search(r"<status>(.*?)</status>", txt, re.S)
        return "NOTICE", f"background task {status.group(1) if status else 'done'}: " + (summary.group(1).strip() if summary else "")
    if txt.startswith("<command-name>"):
        name = re.search(r"<command-name>(.*?)</command-name>", txt, re.S)
        args = re.search(r"<command-args>(.*?)</command-args>", txt, re.S)
        return "USER", cap(f"{name.group(1) if name else ''} {args.group(1).strip() if args else ''}", 1500)
    if txt.startswith("<bash-input>"):
        cmd = re.search(r"<bash-input>(.*?)</bash-input>", txt, re.S)
        return "USER (shell)", cap(cmd.group(1) if cmd else "", 400)
    if txt.startswith(("<local-command", "<bash-stdout", "<bash-stderr", "<artifact-view-context", "<create-pr-command")):
        return None, None
    return "USER", txt


def user_entries(d, ts, tools, entries):
    if d.get("isCompactSummary"):
        entries.append((ts, "COMPACTED", "(the context was summarized here)"))
        return
    content = (d.get("message") or {}).get("content")
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    if not d.get("isMeta") and any(isinstance(b, dict) and b.get("type") in ("image", "document") for b in content or []):
        entries.append((ts, "USER", "[image attached]"))
    for b in content or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text" and not d.get("isMeta"):
            kind, txt = user_text(REMINDER.sub("", b.get("text", "")).strip())
            if kind and txt:
                entries.append((ts, kind, txt))
        elif b.get("type") == "tool_result":
            name = tools.get(b.get("tool_use_id"), "")
            txt = REMINDER.sub("", text_of(b.get("content")))
            if name == "AskUserQuestion":
                entries.append((ts, "ANSWER", cap(txt, 3000)))
            elif name == "ExitPlanMode":
                entries.append((ts, "PLAN RESULT", cap(txt, 2000)))
            elif b.get("is_error") and txt.lstrip().startswith(REFUSED):
                entries.append((ts, f"REFUSED ({name})", cap(txt, 2000)))


def assistant_entries(d, ts, tools, entries):
    for b in (d.get("message") or {}).get("content") or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text" and b.get("text", "").strip():
            entries.append((ts, "ASSISTANT", cap(b["text"], 5000)))
            continue
        if b.get("type") != "tool_use":
            continue
        name, inp = b.get("name", ""), b.get("input") or {}
        tools[b.get("id")] = name
        if name == "AskUserQuestion":
            qs = []
            for q in inp.get("questions", []):
                opts = "; ".join(f"{o.get('label')}: {o.get('description', '')}" for o in q.get("options", []))
                qs.append(f"Q: {q.get('question')}\n   options: {opts}")
            entries.append((ts, "ASK", "\n".join(qs)))
        elif name == "ExitPlanMode":
            entries.append((ts, "PLAN", cap(inp.get("plan", ""), 8000)))
        elif name in ("Agent", "Task"):
            entries.append((ts, f"AGENT {inp.get('description', '')}", cap(inp.get("prompt", ""), 1500)))
        elif name == "Workflow":
            script = inp.get("script", "") or ""
            desc = re.search(r"description:\s*'([^']*)'", script)
            entries.append((ts, "WORKFLOW", desc.group(1) if desc else cap(script or inp.get("scriptPath", ""), 400)))
        elif name == "Bash":
            cmd = inp.get("command", "")
            if re.search(r"\bgit (commit|merge|rebase|reset|push|cherry-pick|revert)\b", cmd):
                entries.append((ts, "GIT", cap(cmd, 6000)))
        elif name in ("Write", "Edit"):
            path = inp.get("file_path", "")
            body = inp.get("content", "") or inp.get("new_string", "")
            short = path.split("/native-canvas/")[-1].split("/.claude/worktrees/")[-1]
            if re.search(r"(msg|COMMIT|commit)", path.split("/")[-1]):
                entries.append((ts, f"COMMIT MESSAGE FILE {path.split('/')[-1]}", cap(body, 6000)))
            elif re.search(r"(docs/|\.claude/rules/|/memory/|plan|design|PLAN|DESIGN)", path):
                entries.append((ts, f"{name.upper()} {short}", cap(body, 1500)))
        elif name.endswith(("__batch", "__update", "__create")) and "ccd_" not in name:
            entries.append((ts, f"DOC {name.split('__')[-1]}", cap(json.dumps(inp, ensure_ascii=False), 3000)))
        elif name.endswith("wrap_up"):
            entries.append((ts, "WRAP-UP", cap(f"{inp.get('recap', '')}\nAsk: {inp.get('ask', '')}", 1200)))
        elif name.endswith("start_session"):
            entries.append((ts, "STARTED SESSION", cap(json.dumps(inp, ensure_ascii=False), 1500)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", nargs="?")
    ap.add_argument("--self", action="store_true", dest="this")
    ap.add_argument("--out", default="history/sessions")
    ap.add_argument("--commits")
    a = ap.parse_args()
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID") if a.this else a.session
    if not sid or not session_files(sid):
        sys.exit(f"no transcript for session {sid!r} under {PROJECTS}")
    entries, meta = read(sid)
    if a.commits:
        for c in json.load(open(a.commits)).values():
            if c["candidates"] and c["candidates"][0]["sid"] == sid:
                entries.append((c["candidates"][0]["wrote_at"] or "", "MAIN COMMIT", c["subject"]))
        entries.sort(key=lambda e: e[0])
    title = meta["title"] or (meta["branches"][-1] if meta["branches"] else "session")
    date = (meta["first"] or "")[:10]
    lines = [f"# {title}\n\n",
             f"Claude Code session `{sid}`, {(meta['first'] or '')[:16].replace('T', ' ')} to "
             f"{(meta['last'] or '')[:16].replace('T', ' ')} UTC",
             f", on {', '.join(f'`{b}`' for b in meta['branches'])}" if meta["branches"] else "",
             ".\n\nCondensed: the owner's messages, questions and answers, the assistant's prose, plans, "
             "agent briefs and git commands. Tool output is left out.\n"]
    for ts, kind, txt in entries:
        stamp = ts[:16].replace("T", " ")
        if kind == "MAIN COMMIT":
            lines.append(f"\n===== [{stamp}] commit written: {txt} =====\n")
        else:
            lines.append(f"\n[{stamp}] {kind}:\n{txt}\n")
    # A session that lands more than once keeps one record, under the name it got first; one made
    # before records were directories becomes one.
    earlier = (sorted(d for d in glob.glob(os.path.join(a.out, f"*-{sid[:8]}")) if os.path.isdir(d))
               + sorted(glob.glob(os.path.join(a.out, f"*-{sid[:8]}.md"))))
    record = earlier[0].removesuffix(".md") if earlier else os.path.join(a.out, f"{date}-{slug(title)}-{sid[:8]}")
    os.makedirs(record, exist_ok=True)
    open(os.path.join(record, "transcript.md"), "w").write(scrub("".join(lines)))
    write_plans(record, plans(sid))
    if os.path.isfile(record + ".md"):
        os.remove(record + ".md")
    print(record)


def write_plans(record, found):
    """Plans only accumulate: one recorded before stays when it can no longer be found (its file
    gone with the scratchpad, written by a command the transcript doesn't hold)."""
    for name, text in found.items():
        path = os.path.join(record, "plans", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").write(text)


if __name__ == "__main__":
    main()
