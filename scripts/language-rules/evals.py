#!/usr/bin/env python3
"""Lite evals of language rules: real boards, the prompt the feature would send, real answers from Jev and Haiku 5.5.

    CANVAS_SOCKET=... python3 evals.py --board 2 --labels cars.json --out RUN       # every variant on Jev
    CANVAS_SOCKET=... python3 evals.py --board 3 --labels votes.json --out RUN --haiku 80

Reads the board through `canvas query` (context.py): each shape a rule checks, everything one step around it, shrunk
to a budget, and what the rule's chips find. Asks each variant (one thing changed at a time):

- mode: `separate` (a question a rule) or `composed` (the rules read together, the more specific type's winning,
  with a question a rule for which one flags it, in the same call);
- polarity: `flag` (the rule says what to flag, as stored) or `hold` (the same rule said as what should be true);
- budget: how much of the free context is sent in full (`small`, `medium`, `large`).

Every request and answer is kept in OUT/prompts.jsonl, every verdict in OUT/results.tsv; score.py reads them.
Keys: TYPESAFE_API_KEY (else its export line in ~/.zshrc) and the Anthropic key the app's Settings saved (else
$ANTHROPIC_API_KEY). Neither is printed. Python 3.9 stdlib.
"""
import argparse
import concurrent.futures
import json
import os
import random
import re
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from context import Canvas, Chips, Snapshot, context  # noqa: E402
import listings  # noqa: E402

RULE_IDS = {
    "The mileage is implausible for the car's age.": "car-mileage",
    "This model wasn't made in this year, per the Toyota lineup.": "toyota-lineup",
    "Mileage doesn't matter for a vintage car.": "vintage-qualifier",
    "It's less than 25 years old.": "vintage-age",
    "Unusual for the member's record.": "vote-record",
    "Unusual for someone representing the member's district.": "vote-district",
}
# Each stored rule said the other way, as what should be true. A qualifier says how to read another rule and checks
# nothing, so it reads the same either way.
HOLD = {
    "The mileage is implausible for the car's age.": "The mileage is plausible for the car's age.",
    "This model wasn't made in this year, per the Toyota lineup.": "This model was made in this year, per the Toyota lineup.",
    "Mileage doesn't matter for a vintage car.": "Mileage doesn't matter for a vintage car.",
    "It's less than 25 years old.": "It's at least 25 years old.",
    "Unusual for the member's record.": "In line with the member's record.",
    "Unusual for someone representing the member's district.": "Fits someone representing the member's district.",
}

# The listings' rules are stored as what should be true, so their "hold" wording is the stored one.
RULE_IDS.update(listings.RULE_IDS)
HOLD.update({says: says for says in listings.RULE_IDS})

JEV_URL = "https://api.typesafe.ai/v1/systemone"
JEV_MODEL = "jev-latest"
HAIKU_MODEL = "claude-haiku-5-5"
HAIKU_EFFORT = "medium"
TODAY = "2026-10-27"


# ------------------------------------------------------------------------------------------------ keys

def jev_key():
    key = os.environ.get("TYPESAFE_API_KEY")
    if key:
        return key
    with open(os.path.expanduser("~/.zshrc")) as f:
        for line in f:
            m = re.match(r"\s*export\s+TYPESAFE_API_KEY=['\"]?([^'\"\s]+)", line)
            if m:
                return m.group(1)
    raise SystemExit("no TYPESAFE_API_KEY")


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


def post(url, body, headers, timeout=90, tries=4):
    data = json.dumps(body).encode()
    for attempt in range(tries):
        req = urllib.request.Request(url, data=data, headers=dict(headers, **{"content-type": "application/json"}))
        t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r), time.time() - t
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:300]
            if e.code in (429, 500, 502, 503, 529) and attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"error": f"HTTP {e.code}: {detail}"}, time.time() - t
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"error": str(e)}, time.time() - t


# ------------------------------------------------------------------------------------------------ the questions

def said(rule, polarity):
    return rule["says"] if polarity == "flag" else HOLD[rule["says"]]


def listing(rules, polarity):
    return "\n".join(f'{i + 1}. (on {r["type"]}) "{said(r, polarity)}"' for i, r in enumerate(rules))


def composed_head(rules, polarity, noun):
    kind = ("Each rule says something that, if true of the {n}, means the {n} should be flagged." if polarity == "flag"
            else "Each rule says something that should be true of the {n}.").format(n=noun)
    return (f"These rules come from the {noun}'s types, the most general type first. Read them together: where two "
            f"disagree, the more specific type's rule wins. {kind}\n{listing(rules, polarity)}\n")


def jev_questions(rules, mode, polarity, noun):
    """Jev's yes/no questions, and for each whether "true" means the rule flags the shape."""
    qs, flags_when_true = {}, {}
    if mode == "separate":
        for i, r in enumerate(rules):
            qs[f"r{i}"] = {"type": "noul", "instructions": f'A rule on {r["type"]}, about this {noun}: "{said(r, polarity)}" '
                                                             f"Judging from the state, is this true of the {noun}?",
                           "criteria": {"true": f"True of this {noun}", "false": f"Not true of this {noun}"}}
            flags_when_true[f"r{i}"] = polarity == "flag"
    else:
        head = composed_head(rules, polarity, noun)
        if polarity == "flag":
            qs["all"] = {"type": "noul", "instructions": head + f"Read together, should this {noun} be flagged?",
                         "criteria": {"true": "Flag it", "false": "Don't flag it"}}
        else:
            qs["all"] = {"type": "noul", "instructions": head + f"Read together, does this {noun} meet them?",
                         "criteria": {"true": "It meets them", "false": "It breaks one"}}
        flags_when_true["all"] = polarity == "flag"
        for i, r in enumerate(rules):
            ask = (f"Read with the others, does rule {i + 1} flag this {noun}?" if polarity == "flag"
                   else f"Read with the others, does this {noun} fail rule {i + 1}?")
            qs[f"r{i}"] = {"type": "noul", "instructions": head + ask, "criteria": {"true": "Yes", "false": "No"}}
            flags_when_true[f"r{i}"] = True
    return qs, flags_when_true


HAIKU_SYSTEM = ("You check a shape on a board against the rules its types carry. The user message gives the shape and "
                "what is around it on the board, as JSON, then the rules. Judge only from what you are given and plain "
                "common knowledge; never assume what isn't there. Answer with one JSON object and nothing else.")


def haiku_message(state, rules, mode, polarity, noun):
    head = f"<state>\n{json.dumps(state, ensure_ascii=False, indent=1)}\n</state>\n\n"
    if mode == "separate":
        return head + (f"<rules>\n{listing(rules, polarity)}\n</rules>\n\nFor each rule, say whether its sentence is true "
                       f'of this {noun}. Answer {{"rules": {{"1": "true" | "false" | "unsure", ...}}}}.')
    if polarity == "flag":
        ask = (f'\nAnswer {{"flag": "yes" | "no" | "unsure", "rules": {{"1": "flags" | "clear" | "unsure", ...}}}}: '
               f"whether, read together, the rules flag this {noun}, and for each rule whether, read with the others, "
               f"it flags the {noun} (\"flags\") or not (\"clear\").")
    else:
        ask = (f'\nAnswer {{"meets": "yes" | "no" | "unsure", "rules": {{"1": "meets" | "fails" | "unsure", ...}}}}: '
               f"whether, read together, this {noun} meets the rules, and for each rule whether, read with the others, "
               f"the {noun} meets it or fails it.")
    return head + composed_head(rules, polarity, noun) + ask


def last_json(text):
    for m in reversed(list(re.finditer(r"\{", text))):
        try:
            return json.loads(text[m.start():text.rindex("}") + 1])
        except (ValueError, json.JSONDecodeError):
            continue
    return None


def haiku_flags(answer, rules, mode, polarity):
    """{question: p_flag} from Haiku's JSON: yes or true 1, no or false 0, unsure 0.5."""
    val = {"true": 1.0, "yes": 1.0, "false": 0.0, "no": 0.0, "unsure": 0.5,
           "flags": 1.0, "clear": 0.0, "fails": 1.0, "meets": 0.0}
    out = {}
    if not isinstance(answer, dict):
        return out
    per = answer.get("rules") or {}
    for i, r in enumerate(rules):
        a = str(per.get(str(i + 1), "")).lower()
        if a in val:
            p = val[a]
            if mode == "separate" and polarity == "hold":
                p = 1.0 - p if a != "unsure" else 0.5
            out[f"r{i}"] = p
    top = answer.get("flag" if polarity == "flag" else "meets")
    if mode == "composed" and str(top).lower() in val:
        p = val[str(top).lower()]
        out["all"] = p if polarity == "flag" else (1.0 - p if str(top).lower() != "unsure" else 0.5)
    return out


# ------------------------------------------------------------------------------------------------ the run

def subjects_of(snap):
    """The shapes some rule checks: those whose types carry rules."""
    out = []
    for s in snap.shapes.values():
        if s["props"].get("schema"):
            continue
        rules = snap.rules(s)
        if rules:
            out.append((s, rules))
    return sorted(out, key=lambda x: (x[0].get("title") or "", x[0]["id"]))


def label_key(s):
    if s["kind"] == "arrow":
        return (s["connection"]["from"].get("title"), s["connection"]["to"].get("title"))
    return s.get("title")


def labels_of(path):
    with open(path) as f:
        d = json.load(f)
    if "cars" in d:
        return {c["title"]: c["expect"] for c in d["cars"]}
    return {(v["member"], v["bill"]): v["expect"] for v in d["votes"]}


def state_for(snap, chips, s, rules, budget):
    st = context(snap, s, budget, TODAY)
    for r in rules:
        for phrase, query in (r.get("find") or {}).items():
            q, found = chips.found(query, s)
            st[f'found by "{phrase}"'] = found
    return st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--board", required=True)
    ap.add_argument("--labels", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--canvas", default=os.path.join(HERE, "..", "..", "build", "canvas"))
    ap.add_argument("--modes", default="separate,composed")
    ap.add_argument("--polarities", default="flag,hold")
    ap.add_argument("--budgets", default="small,medium,large")
    ap.add_argument("--haiku", type=int, default=0, help="shapes to ask Haiku about (every flagged one, then a sample)")
    ap.add_argument("--no-jev", action="store_true")
    ap.add_argument("--haiku-budget", default="medium")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--only", default="", help="subjects by name, separated by |")
    ap.add_argument("--max", type=int, default=0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    snap = Snapshot(Canvas(a.canvas, a.board))
    chips = Chips(snap)
    labels = labels_of(a.labels)
    subjects = subjects_of(snap)
    if a.only:
        wanted = set(a.only.split("|"))
        subjects = [x for x in subjects if (" → ".join(label_key(x[0])) if isinstance(label_key(x[0]), tuple) else label_key(x[0])) in wanted]
    if a.max:
        subjects = subjects[:a.max]
    print(f"{len(subjects)} shapes checked; {snap.canvas.queries_run} queries to read the board", file=sys.stderr)

    lock = threading.Lock()
    results = open(os.path.join(a.out, "results.tsv"), "a")
    prompts = open(os.path.join(a.out, "prompts.jsonl"), "a")
    if os.path.getsize(results.name) == 0:
        results.write("board\tsubject\trule\ton\tprovider\tmode\tpolarity\tbudget\tquestion\tp_flag\texpect\tseconds\ttokens_in\n")

    def record(s, rules, provider, mode, polarity, budget, flags, seconds, tokens, request, response):
        key = label_key(s)
        expect = labels.get(key, {})
        name = " → ".join(key) if isinstance(key, tuple) else key
        with lock:
            for q, p in flags.items():
                if q == "all":  # the composed verdict is about the shape: flagged if any rule, read with the others, flags it
                    rid, on = "all", ""
                    exps = [v for k, v in expect.items() if not k.endswith("/alone")]
                    exp = "" if not exps or any(v is None for v in exps) else str(any(exps))
                else:
                    r = rules[int(q[1:])]
                    rid, on = RULE_IDS.get(r["says"], r["says"]), r["type"]
                    e = expect.get(rid + "/alone") if (mode == "separate" and rid + "/alone" in expect) else expect.get(rid)
                    exp = "" if e is None else str(e)
                results.write(f"{a.board}\t{name}\t{rid}\t{on}\t{provider}\t{mode}\t{polarity}\t{budget}\t{q}\t{p:.3f}\t{exp}\t{seconds:.2f}\t{tokens}\n")
            prompts.write(json.dumps({"subject": name, "provider": provider, "mode": mode, "polarity": polarity,
                                      "budget": budget, "request": request, "response": response}, ensure_ascii=False) + "\n")
            results.flush()
            prompts.flush()

    jobs = []
    states = {}
    for s, rules in subjects:
        for budget in a.budgets.split(","):
            states[(s["id"], budget)] = state_for(snap, chips, s, rules, budget)
    print(f"states built; {snap.canvas.queries_run} queries in all ({len(chips.kept)} distinct chips)", file=sys.stderr)

    if not a.no_jev:
        jk = jev_key()

        def ask_jev(s, rules, mode, polarity, budget):
            noun = "vote" if s["kind"] == "arrow" else "car"
            qs, flags_when_true = jev_questions(rules, mode, polarity, noun)
            body = {"state": states[(s["id"], budget)], "model": JEV_MODEL, "questions": qs}
            resp, secs = post(JEV_URL, body, {"Authorization": "Bearer " + jk})
            flags = {}
            for q in qs:
                ans = (resp.get("answers") or {}).get(q)
                if ans and "noul" in ans:
                    p = float(ans["noul"])
                    flags[q] = p if flags_when_true[q] else 1.0 - p
            record(s, rules, "jev", mode, polarity, budget, flags, secs, (resp.get("usage") or {}).get("input_tokens", ""),
                   body, resp)
        for s, rules in subjects:
            for mode in a.modes.split(","):
                for polarity in a.polarities.split(","):
                    for budget in a.budgets.split(","):
                        jobs.append((ask_jev, (s, rules, mode, polarity, budget)))

    if a.haiku:
        hk = anthropic_key()
        flagged = [x for x in subjects if any(v for k, v in labels.get(label_key(x[0]), {}).items() if v)]
        rest = [x for x in subjects if x not in flagged]
        random.Random(7).shuffle(rest)
        sample = (flagged + rest)[:max(a.haiku, len(flagged))] if len(flagged) < a.haiku else flagged[:a.haiku]

        def ask_haiku(s, rules, mode, polarity, budget):
            noun = "vote" if s["kind"] == "arrow" else "car"
            body = {"model": HAIKU_MODEL, "max_tokens": 2048, "system": HAIKU_SYSTEM,
                    "output_config": {"effort": HAIKU_EFFORT},
                    "messages": [{"role": "user", "content": haiku_message(states[(s["id"], budget)], rules, mode, polarity, noun)}]}
            resp, secs = post("https://api.anthropic.com/v1/messages", body,
                              {"x-api-key": hk, "anthropic-version": "2023-06-01"})
            text = "".join(b.get("text", "") for b in resp.get("content", []) if b.get("type") == "text")
            flags = haiku_flags(last_json(text), rules, mode, polarity)
            record(s, rules, "haiku", mode, polarity, budget, flags, secs, (resp.get("usage") or {}).get("input_tokens", ""),
                   body, {"text": text, "usage": resp.get("usage"), "error": resp.get("error")})
        for s, rules in sample:
            for mode in a.modes.split(","):
                for polarity in a.polarities.split(","):
                    jobs.append((ask_haiku, (s, rules, mode, polarity, a.haiku_budget)))

    print(f"{len(jobs)} calls", file=sys.stderr)
    done = 0
    with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:
        for f in concurrent.futures.as_completed([pool.submit(fn, *args) for fn, args in jobs]):
            f.result()
            done += 1
            if done % 100 == 0:
                print(f"  {done}/{len(jobs)}", file=sys.stderr)
    print("done", file=sys.stderr)


if __name__ == "__main__":
    main()
