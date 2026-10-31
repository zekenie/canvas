"""A lite live check: can the translator write a rule chip's query from its words?

Each case is a phrase a person might write in brackets in a rule on a type, on one of the prototype's
boards (Cars, Votes, Listings, open in the test app). The request is built as `translate(_:about:)` builds
it (AskRequest's blocks: question, vocabulary, board, titles, fields, instances), with the shipped prompt
and its stored-query rule line read from Shipped/, the model and effort read from AskStyle.haiku55 in the
Swift, plus the line and `:scope` words a query bound to the shape checked adds: `Shipped/ask-bound.txt`, filled in as
`BoundWords` fills it (VARIANT=shipped, the default), or the drafts it was written from (VARIANT=framed, connections). The
query the model writes is
run through `canvas query` for two sample shapes of the type, `:scope` written as each one's id (as
context.py does), and compared with what a hand-written reference query finds. A refused query is sent
back once, as the app does. The key is read from the app's Settings file and never printed.
"""
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CLI = ROOT + "/build/canvas"
OUT = os.environ.get("OUT") or os.path.dirname(os.path.abspath(__file__))  # where requests and runs are written

PROMPT = open(ROOT + "/Shipped/ask-prompt.txt").read()
STORED_RULE = open(ROOT + "/Shipped/ask-rule.txt").read().strip("\n")


def sections(text):
    """A file of sections after `## <name>` lines, as BoundWords reads one: each section's lines (empty ones dropped)."""
    out, current = {}, None
    for line in text.split("\n"):
        if line.startswith("## "):
            current = line[3:].strip()
            out[current] = []
        elif current is not None and line:
            out[current].append(line)
    return out


BOUND = sections(open(ROOT + "/Shipped/ask-bound.txt").read())
swift = open(ROOT + "/Sources/QueryTranslation/AskRequest.swift").read()
m = re.search(r'static let haiku55 = AskStyle\(model: "([^"]+)", maxTokens: ([\d_]+), effort: "(\w+)"\)', swift)
MODEL, MAX_TOKENS, EFFORT = m.group(1), int(m.group(2).replace("_", "")), m.group(3)


def key():
    try:
        with open(os.path.expanduser("~/Library/Application Support/InfiniteCanvas/anthropic-api-key")) as f:
            k = f.read().strip()
            if k:
                return k
    except OSError:
        pass
    k = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if not k:
        raise SystemExit("no Anthropic key")
    return k


KEY = key()


def query(board, text, limit=5000):
    p = subprocess.run([CLI, "query", "--board", str(board), "--limit", str(limit), "-"], input=text, capture_output=True, text=True)
    d = json.loads(p.stdout or p.stderr or "{}")
    if p.returncode != 0 or "error" in d:
        return None, d.get("error", {"message": (p.stderr or "")[:300]})
    return d, None


def quoted(t):
    return '"' + t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def words(t):
    return set(w for w in re.findall(r"[a-z0-9]+", t.lower()) if len(w) > 2)


# ---------------------------------------------------------------- the request's blocks

EDITOR_WORDS = (":invalid", ":warned", ":incomplete", ":selected")


def vocabulary(board, arrow):
    p = subprocess.run([CLI, "query-vocabulary"], capture_output=True, text=True)
    text = json.loads(p.stdout)["vocabulary"]
    lines = [l for l in text.splitlines() if not any(l.startswith("- " + w) for w in EDITOR_WORDS)]
    if VARIANT == "shipped":
        # As BoundWords.vocabulary(for:) adds them.
        return "\n".join(lines + BOUND["words"] + (BOUND["end words"] if arrow else []))
    lines.append("- :scope — the shape the rule is checking. Example: :scope")
    if arrow:
        lines.append("- :scope-start — the shape the arrow being checked starts at. Example: :scope-start")
        lines.append("- :scope-end — the shape the arrow being checked ends at. Example: :scope-end")
    return "\n".join(lines)


def titles(board, question, limit=200):
    d, _ = query(board, "*")
    asked = words(question)
    rows = [r for r in d["rows"] if r.get("title")]
    seen, first, rest = set(), [], []
    for r in rows:
        line = f'{quoted(r["title"])} {r["kind"]}' + (", in " + " › ".join(r["inside"]) if r.get("inside") else "")
        if line in seen:
            continue
        seen.add(line)
        (first if asked & words(r["title"]) else rest).append(line)
    return "\n".join((first + rest)[:limit])


KIND = {"string": "text", "integer": "number", "number": "number", "boolean": "yes/no", "array": "list"}


def types_of(board):
    d, _ = query(board, "sticky-note[schema]")
    d2, _ = query(board, "sticky-note[schema]")  # rows carry no properties without --fields; read them below
    p = subprocess.run([CLI, "query", "--board", str(board), "--fields", "schema", "--fields", "is", "--fields", "relationship", "-"],
                       input="sticky-note[schema]", capture_output=True, text=True)
    out = []
    for r in json.loads(p.stdout)["rows"]:
        props = r.get("properties", {})
        schema = json.loads(props.get("schema") or "{}")
        fields = [(k, KIND.get(v.get("type"), "text")) for k, v in (schema.get("properties") or {}).items() if not k.startswith("$")]
        out.append({"title": r["title"], "is": props.get("is") or [], "relationship": bool(props.get("relationship")), "fields": fields})
    return out


def fields_block(board, question, relates):
    ts = types_of(board)
    asked = words(question)
    counts = {}
    for t in ts:
        d, _ = query(board, f":is-a({quoted(t['title'])})", limit=1)
        counts[t["title"]] = d["count"] if d else 0
    lines = []
    for t in ts:
        line = t["title"] + (" builds on " + ", ".join(t["is"]) if t["is"] else "")
        if t["relationship"]:
            line += " relates " + relates.get(t["title"], "anything to anything")
        line += ": " + (", ".join(f"{k} ({kind})" for k, kind in t["fields"]) or "no fields")
        lines.append((bool(asked & words(line)), counts[t["title"]], t["title"], line))
    lines.sort(key=lambda x: (not x[0], -x[1], x[2]))
    return "\n".join(l[3] for l in lines), ts


def instances_block(board, question, ts):
    asked = words(question)
    out = []
    for t in ts:
        if t["relationship"]:
            continue
        d, _ = query(board, f":is-a({quoted(t['title'])})")
        if not d or not d["count"]:
            continue
        names = sorted(r["title"] for r in d["rows"] if r.get("title"))
        line = t["title"] + ": " + ", ".join(quoted(n) for n in names[:20])
        if d["count"] > min(len(names), 20):
            line += (", " if names else "") + f"and {d['count'] - min(len(names), 20)} more"
        out.append((bool(asked & words(t["title"])), d["count"], t["title"], line))
    out.sort(key=lambda x: (not x[0], -x[1], x[2]))
    return "\n".join(o[3] for o in out)


def block(tag, text):
    text = text.strip()
    return f"<{tag}>\n{text}\n</{tag}>" if text else None


VARIANT = os.environ.get("VARIANT", "shipped")  # "shipped": Shipped/ask-bound.txt; "connections", "framed": its drafts


def rule_line(case):
    if VARIANT == "shipped":
        # As BoundWords.line(for:sentence:) fills it in.
        return (" ".join(BOUND["line"]).replace("{type}", quoted(case["type"])).replace("{shapes}", "arrows" if case["arrow"] else "notes")
                .replace("{ends}", "".join(BOUND["ends"]) if case["arrow"] else "").replace("{sentence}", case["sentence"]))
    shape = "arrows" if case["arrow"] else "notes"
    ends = (", :scope-start the shape it starts at and :scope-end the shape it ends at" if case["arrow"] else "")
    line = (f"The question is a phrase in brackets in a rule on the type {quoted(case['type'])}, whose shapes are {shape}. "
            "Write a query that finds the shapes the phrase names, so that whoever checks the rule can read them. "
            "The rule is judged elsewhere, never by the query: never answer UNANSWERABLE because a query can't judge the rule. "
            f"The query is run once for each shape of the type: :scope is the shape being checked{ends}. "
            "Words about the shape being checked, or about what is around it, are written from these words; words that name "
            "the same shapes whatever shape is checked are written as any stored query. "
            f"The rule, for what the phrase means: “{case['sentence']}”")
    if VARIANT == "connections":
        line += " <connections> says how arrows join shapes on the board: the type, else the kind, at each end, and how many."
    return line


def connections_block(board):
    p = subprocess.run([CLI, "query", "--board", str(board), "--limit", "10000", "--fields", "is", "-"], input="arrow",
                       capture_output=True, text=True)
    rows = json.loads(p.stdout)["rows"]
    d, _ = query(board, "*")
    label = {}
    p2 = subprocess.run([CLI, "query", "--board", str(board), "--limit", "10000", "--fields", "is", "-"], input="*",
                        capture_output=True, text=True)
    for r in json.loads(p2.stdout)["rows"]:
        types = (r.get("properties") or {}).get("is") or []
        label[r["id"]] = types[0] if types else r["kind"]
    counts = {}
    for r in rows:
        c = r.get("connection")
        if not c:
            continue
        types = (r.get("properties") or {}).get("is") or []
        k = (label.get(c["from"]["id"], "?"), types[0] if types else "", label.get(c["to"]["id"], "?"))
        counts[k] = counts.get(k, 0) + 1
    lines = [f"{a} → {b}: {n} {(t + ' ') if t else ''}arrow{'s' if n != 1 else ''}" for (a, t, b), n in
             sorted(counts.items(), key=lambda kv: -kv[1])]
    return "\n".join(lines[:30])


# ---------------------------------------------------------------- the model

def post(body):
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(body).encode(), method="POST",
                                 headers={"x-api-key": KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"})
    for attempt in range(4):
        t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.loads(r.read()), time.time() - t
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 529) and attempt < 3:
                time.sleep(2 + 3 * attempt)
                continue
            return {"error": {"status": e.code, "body": e.read()[:300].decode("utf-8", "replace")}}, time.time() - t
        except Exception as e:  # noqa: BLE001
            if attempt < 3:
                time.sleep(2)
                continue
            return {"error": {"message": str(e)[:200]}}, time.time() - t


def read_answer(text):
    lines = [l.strip() for l in text.strip().splitlines() if l.strip() and not l.strip().startswith("```")]
    if not lines:
        return None, None
    last = lines[-1]
    if last.upper().startswith("UNANSWERABLE"):
        return None, last
    return last.strip("`"), None


def scoped(q, sample):
    sid = "#" + sample["id"]
    return q.replace(":scope-start", f":start-of({sid})").replace(":scope-end", f":end-of({sid})").replace(":scope", sid)


def found(board, q, sample):
    d, err = query(board, scoped(q, sample))
    return (set(r["id"] for r in d["rows"]) if d else None), err


# ---------------------------------------------------------------- the cases

CASES = [
    # Votes: the rule is on Vote, a relationship type whose arrows run from a Member to a Bill.
    dict(id="V1", board=3, type="Vote", arrow=True, phrase="the member's district",
         sentence="Unusual for someone representing [the member's district].",
         accept=["subboard:edge-from(:scope-start) *", "subboard:edge-from(:scope-start)"]),
    dict(id="V2", board=3, type="Vote", arrow=True, phrase="the member's other votes",
         sentence="Unusual given [the member's other votes].",
         accept=['arrow:is-a("Vote"):starts-at(:scope-start):not(:scope)', 'arrow:is-a("Vote"):starts-at(:scope-start)']),
    dict(id="V3", board=3, type="Vote", arrow=True, phrase="how the rest of the delegation voted on this bill",
         sentence="Unlike [how the rest of the delegation voted on this bill].",
         accept=['arrow:is-a("Vote"):ends-at(:scope-end):not(:scope)', 'arrow:is-a("Vote"):ends-at(:scope-end)']),
    dict(id="V4", board=3, type="Vote", arrow=True, phrase="the district's median household income",
         sentence="Odd for a district with [the district's median household income].",
         accept=['subboard:edge-from(:scope-start) "Median household income"']),
    dict(id="V5", board=3, type="Vote", arrow=True, phrase="members of the member's party",
         sentence="Against the way [members of the member's party] voted.", cant=True),
    # Cars: the rule is on Toyota, a type of note built on Car.
    dict(id="C1", board=2, type="Toyota", arrow=False, phrase="the Toyota lineup",
         sentence="This model wasn't made in this year, per [the Toyota lineup].",
         accept=['subboard"Toyota lineup" *', 'subboard"Toyota lineup"']),
    dict(id="C2", board=2, type="Toyota", arrow=False, phrase="this car's model in the Toyota lineup",
         sentence="This model wasn't made in this year, per [this car's model in the Toyota lineup].", cant=True),
    # Listings: the rule is on Listing, a type of note built on Car.
    dict(id="L1", board=4, type="Listing", arrow=False, phrase="the other listings",
         sentence="Described unlike [the other listings].",
         accept=[':is-a("Listing"):not(:scope)', ':is-a("Listing")']),
    dict(id="L2", board=4, type="Listing", arrow=False, phrase="listings for vintage cars",
         sentence="Reads unlike [listings for vintage cars].",
         accept=[':is-a("Listing"):is-a("Vintage")']),
    dict(id="L3", board=4, type="Listing", arrow=False, phrase="listings of the same make",
         sentence="Priced unlike [listings of the same make].", cant=True),
]

RELATES = {3: {"Vote": "Member to Bill"}}


def samples(board, typ, arrow):
    d, _ = query(board, (f'arrow:is-a({quoted(typ)})' if arrow else f':is-a({quoted(typ)})'))
    rows = d["rows"]
    if arrow:
        # Two members, two bills: Smucker's first vote, and Boyle's on another bill.
        first = next(r for r in rows if r["connection"]["from"].get("title") == "Lloyd Smucker")
        other = next(r for r in rows if r["connection"]["from"].get("title") == "Brendan Boyle"
                     and r["connection"]["to"]["id"] != first["connection"]["to"]["id"])
        picks = [first, other]
    else:
        mustang = [r for r in rows if "Mustang" in (r.get("title") or "")]
        picks = (mustang[:1] + [r for r in rows if r not in mustang])[:2]
    return [p for p in picks if p]


def build(case):
    q = case["phrase"]
    fields, ts = fields_block(case["board"], q, RELATES.get(case["board"], {}))
    message = "\n\n".join(b for b in [
        block("question", q),
        block("vocabulary", vocabulary(case["board"], case["arrow"])),
        block("board", "The person is looking at the top board."),
        block("titles", titles(case["board"], q)),
        block("fields", fields),
        block("instances", instances_block(case["board"], q, ts)),
        block("connections", connections_block(case["board"])) if VARIANT in ("connections", "shipped") else None,
    ] if b)
    system = PROMPT + "\n" + STORED_RULE + "\n" + rule_line(case)
    return system, message


def run(case, run_no, system, message, picks, expected):
    body = {"model": MODEL, "max_tokens": MAX_TOKENS, "system": system, "output_config": {"effort": EFFORT},
            "messages": [{"role": "user", "content": message}]}
    record = {"case": case["id"], "run": run_no, "phrase": case["phrase"], "tries": []}
    for attempt in (1, 2):
        resp, secs = post(body)
        text = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text")
        usage = resp.get("usage") or {}
        q, unanswerable = read_answer(text)
        tried = {"secs": round(secs, 2), "in": usage.get("input_tokens"), "out": usage.get("output_tokens"),
                 "wrote": q or unanswerable or text[:200], "error": resp.get("error")}
        record["tries"].append(tried)
        if unanswerable or not q:
            record["outcome"] = "unanswerable" if unanswerable else "no answer"
            break
        results, refusals = [], []
        for s in picks:
            got, err = found(case["board"], q, s)
            if err:
                refusals.append(err)
            results.append(got)
        if refusals and attempt == 1:
            err = refusals[0]
            body["messages"] += [{"role": "assistant", "content": text.strip()},
                                 {"role": "user", "content": f"<error>\nquery: {q}\nrefused: {err.get('reason')}: {err.get('message')} {err.get('hint') or ''}\n</error>"}]
            continue
        if refusals:
            record["outcome"] = "refused"
            break
        sizes = [len(r) for r in results]
        ok = all(any(r == e for e in exp) for r, exp in zip(results, expected))
        record.update(outcome="right" if ok else "wrong", query=q, found=sizes,
                      expected=[[len(e) for e in exp] for exp in expected])
        break
    record["repaired"] = len(record["tries"]) > 1
    if case.get("cant"):
        record["right"] = record["outcome"] == "unanswerable"
    else:
        record["right"] = record["outcome"] == "right"
    return record


def main(runs=2):
    jobs = []
    prepared = {}
    for case in CASES:
        system, message = build(case)
        picks = samples(case["board"], case["type"], case["arrow"])
        expected = [[found(case["board"], a, s)[0] for a in case.get("accept", [])] for s in picks]
        prepared[case["id"]] = (case, system, message, picks, expected)
        with open(os.path.join(OUT, f"request-{VARIANT}-{case['id']}.txt"), "w") as f:
            f.write("SYSTEM (prompt file, rule line, then)\n" + rule_line(case) + "\n\nUSER\n" + message)
        for r in range(1, runs + 1):
            jobs.append((case, r, system, message, picks, expected))
    out = []
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for rec in pool.map(lambda j: run(*j), jobs):
            out.append(rec)
            print(json.dumps(rec), flush=True)
    with open(os.path.join(OUT, f"runs-{VARIANT}.jsonl"), "w") as f:
        for rec in out:
            f.write(json.dumps(rec) + "\n")
    right = sum(r["right"] for r in out)
    print(f"\n{right} of {len(out)} right; model {MODEL}, effort {EFFORT}", file=sys.stderr)


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 2)
