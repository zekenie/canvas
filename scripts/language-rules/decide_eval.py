"""The decision models' Haiku adapter, asked live: `LanguageDecisionModel` (Sources/DecisionModels) as the app sends
it, its system prompt read from the Swift and its message written as `message(for:)` writes it, over the states and
questions an earlier round sent Jev (a run's prompts.jsonl: the rules read together, worded as what should hold, the
`medium` budget), scored against that round's labels beside the round's own Haiku answers in its own framing.

    python3 scripts/language-rules/decide_eval.py RUN_DIR OUT_DIR [--limit N]

RUN_DIR is a run of evals.py (its prompts.jsonl and results.tsv). The Anthropic key the app's Settings saved is read
(else $ANTHROPIC_API_KEY) and never printed.
"""
import argparse
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWIFT = os.path.join(ROOT, "Sources/DecisionModels/LanguageDecisionModel.swift")
FLAG, HOLD = 0.7, 0.3   # DecisionCutoffs.standard


def swift_string(source, name):
    """A Swift multi-line string constant, as the compiler reads it: the closing quotes' indentation taken off each
    line, and a line ending in a backslash joined to the next."""
    m = re.search(r'static let ' + name + r' = """\n(.*?)\n( *)"""', source, re.S)
    if not m:
        raise SystemExit(f"no {name} in {SWIFT}")
    indent = len(m.group(2))
    lines = [line[indent:] for line in m.group(1).split("\n")]
    return re.sub(r"\\\n", "", "\n".join(lines))


def swift_setting(source, name):
    m = re.search(name + r': String\?? = "([^"]+)"', source) or re.search(r"static let " + name + r' = "([^"]+)"', source)
    if not m:
        raise SystemExit(f"no {name} in {SWIFT}")
    return m.group(1)


def pretty(value, indent=""):
    """JSON as the app's `prettyText` writes it: sorted keys, two spaces, a list of plain values on one line."""
    inner = indent + "  "
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [f"{inner}{json.dumps(k, ensure_ascii=False)}: {pretty(value[k], inner)}" for k in sorted(value)]
        return "{\n" + ",\n".join(items) + "\n" + indent + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        if all(not isinstance(v, (dict, list)) for v in value):
            return "[" + ", ".join(pretty(v, inner) for v in value) + "]"
        return "[\n" + ",\n".join(inner + pretty(v, inner) for v in value) + "\n" + indent + "]"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return json.dumps(value, ensure_ascii=False)


def message(state, preface, questions):
    """`LanguageDecisionModel.message(for:)`."""
    text = f"<state>\n{pretty(state)}\n</state>\n\n"
    if preface:
        text += preface + "\n\n"
    text += "<questions>\n"
    for i, q in enumerate(questions):
        text += f'{i + 1}. {q["asks"]}\n   Answer "{q["yes"]}" or "{q["no"]}".\n'
    form = ", ".join(f'"{i + 1}": "…"' for i in range(len(questions)))
    text += f'</questions>\n\nAnswer {{{form}}}: for each question, one of its two answers word for word, or "unsure".'
    return text


def last_object(text):
    end = text.rfind("}")
    start = end
    while end >= 0:
        start = text.rfind("{", 0, start)
        if start < 0:
            return None
        try:
            value = json.loads(text[start:end + 1])
            if isinstance(value, dict):
                return value
        except json.JSONDecodeError:
            continue
    return None


def answers(text, questions):
    """`LanguageDecisionModel.answers`: each question's yes words 1, its no words 0, unsure 0.5."""
    obj = last_object(text)
    if obj is None:
        return None

    def folded(words):
        return words.strip().lower().rstrip(".")

    out = {}
    for i, q in enumerate(questions):
        said = obj.get(str(i + 1))
        if not isinstance(said, str):
            continue
        said = folded(said)
        if said == folded(q["yes"]):
            out[q["id"]] = 1.0
        elif said == folded(q["no"]):
            out[q["id"]] = 0.0
        elif said == "unsure":
            out[q["id"]] = 0.5
    return out


def anthropic_key():
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


def post(body, key, tries=4):
    data = json.dumps(body).encode()
    for attempt in range(tries):
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=data,
                                     headers={"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
        t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r), time.time() - t
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 529) and attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"error": f"HTTP {e.code}: {e.read().decode()[:300]}"}, time.time() - t
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"error": str(e)}, time.time() - t


def requests_of(run):
    """The rounds' Jev requests, read together and worded as what holds, at the medium budget: each as the
    decision model's request (the shared head as its preface, each question's own ask), with whether a yes flags."""
    out = []
    with open(os.path.join(run, "prompts.jsonl")) as f:
        for line in f:
            d = json.loads(line)
            if (d["provider"], d["mode"], d["polarity"], d["budget"]) != ("jev", "composed", "hold", "medium"):
                continue
            qs = d["request"]["questions"]
            texts = [q["instructions"] for q in qs.values()]
            head = os.path.commonprefix(texts)
            head = head[:head.rfind("\n") + 1]   # whole lines: the rules' listing
            questions = [{"id": qid, "asks": q["instructions"][len(head):], "yes": q["criteria"]["true"], "no": q["criteria"]["false"]}
                         for qid, q in qs.items()]
            out.append({"subject": d["subject"], "state": d["request"]["state"], "preface": head.rstrip("\n"), "questions": questions,
                        "flags_when_yes": {qid: qid != "all" for qid in qs}})
    return out


def labels_of(run):
    """(subject, question) -> (rule, expected flag, the round's Haiku p_flag) from the round's results."""
    expected, haiku = {}, {}
    with open(os.path.join(run, "results.tsv")) as f:
        next(f)
        for line in f:
            board, subject, rule, on, provider, mode, polarity, budget, q, p, exp, *_ = line.rstrip("\n").split("\t")
            if (mode, polarity) != ("composed", "hold"):
                continue
            if provider == "jev" and budget == "medium" and exp:
                expected[(subject, q)] = (rule, exp == "True")
            if provider == "haiku":
                haiku[(subject, q)] = float(p)
    return expected, haiku


def main():
    a = argparse.ArgumentParser()
    a.add_argument("run")
    a.add_argument("out")
    a.add_argument("--limit", type=int, default=0)
    a.add_argument("--workers", type=int, default=6)
    a = a.parse_args()
    source = open(SWIFT).read()
    system = swift_string(source, "system")
    model = swift_setting(source, "haiku55")
    effort = swift_setting(source, "effort")
    reqs = requests_of(a.run)
    if a.limit:
        reqs = reqs[:a.limit]
    expected, old = labels_of(a.run)
    key = anthropic_key()
    os.makedirs(a.out, exist_ok=True)

    def ask(r):
        body = {"model": model, "max_tokens": 2048, "system": system, "output_config": {"effort": effort},
                "messages": [{"role": "user", "content": message(r["state"], r["preface"], r["questions"])}]}
        resp, secs = post(body, key)
        text = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text")
        return r, body, resp, text, secs

    rows = []
    with concurrent.futures.ThreadPoolExecutor(a.workers) as pool, open(os.path.join(a.out, "prompts.jsonl"), "w") as log:
        for r, body, resp, text, secs in pool.map(ask, reqs):
            got = answers(text, r["questions"])
            log.write(json.dumps({"subject": r["subject"], "request": body, "text": text, "usage": resp.get("usage"),
                                  "error": resp.get("error")}, ensure_ascii=False) + "\n")
            for q in r["questions"]:
                key_ = (r["subject"], q["id"])
                if key_ not in expected:
                    continue
                rule, exp = expected[key_]
                p_yes = (got or {}).get(q["id"])
                p_flag = None if p_yes is None else (p_yes if r["flags_when_yes"][q["id"]] else 1 - p_yes)
                rows.append((rule, r["subject"], q["id"], p_flag, exp, old.get(key_), secs,
                             (resp.get("usage") or {}).get("input_tokens", 0)))
    with open(os.path.join(a.out, "results.tsv"), "w") as f:
        f.write("rule\tsubject\tquestion\tp_flag\texpect\tround_haiku\tseconds\ttokens_in\n")
        for row in rows:
            f.write("\t".join("" if v is None else str(v) for v in row) + "\n")

    def verdicts(pairs):
        n = dict(pos=0, caught=0, missed=0, unsure_pos=0, neg=0, false=0, unsure_neg=0, unread=0)
        for p, exp in pairs:
            if p is None:
                n["unread"] += 1
                continue
            if exp:
                n["pos"] += 1
                n["caught" if p >= FLAG else "missed" if p <= HOLD else "unsure_pos"] += 1
            else:
                n["neg"] += 1
                if p >= FLAG:
                    n["false"] += 1
                elif p > HOLD:
                    n["unsure_neg"] += 1
        return n

    print(f"# The Haiku adapter, {model} at {effort}, over {a.run}\n")
    print("| rule | framing | n+ | caught | missed | unsure+ | n− | false alarms | unsure− | unread |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for rule in sorted({r[0] for r in rows}):
        mine = [(r[3], r[4]) for r in rows if r[0] == rule]
        theirs = [(r[5], r[4]) for r in rows if r[0] == rule and r[5] is not None]
        for name, pairs in (("adapter", mine), ("round's own", theirs)):
            if not pairs:
                continue
            n = verdicts(pairs)
            print(f"| {rule} | {name} | {n['pos']} | {n['caught']} | {n['missed']} | {n['unsure_pos']} | {n['neg']} | {n['false']} | "
                  f"{n['unsure_neg']} | {n['unread']} |")
    secs = sorted(r[6] for r in rows)
    toks = sorted(r[7] for r in rows if r[7])
    if secs:
        print(f"\nmedian {secs[len(secs) // 2]:.2f} s a call; median {toks[len(toks) // 2] if toks else 0} input tokens; "
              f"{len(reqs)} calls", file=sys.stdout)


if __name__ == "__main__":
    main()
