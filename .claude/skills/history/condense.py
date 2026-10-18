"""Condense a Claude Code session's transcript to what carries intent, for history/sessions/:
the owner's messages in full, the questions asked and their answers, refusals, the assistant's
prose, plans, agent briefs, design-doc writes and git commands. Tool output is left out, and
anything shaped like a key is redacted.

    python3 condense.py --self [--out DIR]           # this session (CLAUDE_CODE_SESSION_ID)
    python3 condense.py <session id> [--out DIR] [--commits FILE]

--commits names a JSON map of main's commits to the sessions that wrote them (the
commit_sessions.json `review.py prepare` writes: {sha: {subject, candidates: [{sid, wrote_at},
...]}}, the author first), so the file marks where each commit's message was written. Prints
the file written.
"""
import argparse, glob, json, os, re, sys

PROJECTS = os.path.expanduser("~/.claude/projects/")
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
    os.makedirs(a.out, exist_ok=True)
    # A session that lands more than once keeps one file, under the name it got first.
    earlier = sorted(glob.glob(os.path.join(a.out, f"*-{sid[:8]}.md")))
    path = earlier[0] if earlier else os.path.join(a.out, f"{date}-{slug(title)}-{sid[:8]}.md")
    open(path, "w").write(scrub("".join(lines)))
    print(path)


if __name__ == "__main__":
    main()
