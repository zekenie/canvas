"""The rules' words as the product ships them (Shipped/rule-prompt.txt, `RulePrompts`), asked live of Jev over the
states an earlier round sent it: each request built as `RulePrompts.request(state:rules:noun:)` builds it (the preface
naming the noun, the rules' lines most general type first, a question for the rules read together and one for each),
checked word for word against the round's own request first, then asked, and scored against the round's labels
beside the round's own answers.

    python3 scripts/language-rules/rules_eval.py RUN_DIR OUT_DIR

TYPESAFE_API_KEY (else its export line in ~/.zshrc) is read and never printed.
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
PROMPT = os.path.join(ROOT, "Shipped/rule-prompt.txt")
JEV = "https://api.typesafe.ai/v1/systemone"
FLAG, HOLD = 0.7, 0.3


def prompts():
    """`RulePrompts(text:)`."""
    sections, current = {}, None
    for line in open(PROMPT).read().split("\n"):
        if line.startswith("## "):
            current = line[3:].strip()
            sections[current] = []
        elif current is not None:
            sections[current].append(line)

    def lines(name):
        found = list(sections[name])
        while found and not found[-1].strip():
            found.pop()
        return found

    def question(name):
        text, out = [], {}
        for line in lines(name):
            if line.startswith("true: "):
                out["yes"] = line[6:]
            elif line.startswith("false: "):
                out["no"] = line[7:]
            elif line.startswith("flags when: "):
                out["flags_when_yes"] = line.endswith("true")
            else:
                text.append(line)
        out["text"] = "\n".join(text)
        return out

    return {"preface": "\n".join(lines("preface")), "rule": "\n".join(lines("rule")),
            "together": question("together"), "each": question("each")}


def filled(template, values):
    for k, v in values.items():
        template = template.replace("{" + k + "}", v)
    return template


def request(p, state, rules, noun):
    """`RulePrompts.request(state:rules:noun:)`: rules are (type name, sentence) pairs."""
    lines = [filled(p["rule"], {"number": str(i + 1), "type": t, "says": s}) for i, (t, s) in enumerate(rules)]
    preface = "\n".join([filled(p["preface"], {"noun": noun})] + lines)
    questions = [{"id": "all", "asks": filled(p["together"]["text"], {"noun": noun}), "yes": p["together"]["yes"], "no": p["together"]["no"]}]
    for i in range(len(rules)):
        questions.append({"id": f"r{i}", "asks": filled(p["each"]["text"], {"noun": noun, "number": str(i + 1)}),
                          "yes": p["each"]["yes"], "no": p["each"]["no"]})
    return preface, questions


def flagging(p, qid, yes):
    q = p["together"] if qid == "all" else p["each"]
    return yes if q["flags_when_yes"] else 1 - yes


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


def post(body, key, tries=4):
    data = json.dumps(body).encode()
    for attempt in range(tries):
        req = urllib.request.Request(JEV, data=data, headers={"Authorization": "Bearer " + key, "content-type": "application/json"})
        t = time.time()
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r), time.time() - t
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 529) and attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"error": f"HTTP {e.code}"}, time.time() - t
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < tries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            return {"error": str(e)}, time.time() - t


def main():
    a = argparse.ArgumentParser()
    a.add_argument("run")
    a.add_argument("out")
    a.add_argument("--workers", type=int, default=6)
    a = a.parse_args()
    p = prompts()
    jobs, same = [], 0
    with open(os.path.join(a.run, "prompts.jsonl")) as f:
        for line in f:
            d = json.loads(line)
            if (d["provider"], d["mode"], d["polarity"], d["budget"]) != ("jev", "composed", "hold", "medium"):
                continue
            qs = d["request"]["questions"]
            head = qs["all"]["instructions"]
            noun = re.match(r"These rules come from the (.+?)'s types", head).group(1)
            rules = re.findall(r'^\d+\. \(on (.+?)\) "(.*)"$', head, re.M)
            preface, questions = request(p, d["request"]["state"], rules, noun)
            asked = {q["id"]: preface + "\n" + q["asks"] for q in questions}
            if all(asked[k] == v["instructions"] and v["criteria"] == {"true": q["yes"], "false": q["no"]}
                   for q in questions for k, v in [(q["id"], qs[q["id"]])]):
                same += 1
            jobs.append((d["subject"], d["request"]["state"], preface, questions))
    print(f"{same} of {len(jobs)} requests are the round's word for word", file=sys.stderr)

    expected, old = {}, {}
    with open(os.path.join(a.run, "results.tsv")) as f:
        next(f)
        for line in f:
            board, subject, rule, on, provider, mode, polarity, budget, q, pf, exp, *_ = line.rstrip("\n").split("\t")
            if (provider, mode, polarity, budget) == ("jev", "composed", "hold", "medium"):
                old[(subject, q)] = float(pf)
                if exp:
                    expected[(subject, q)] = (rule, exp == "True")

    key = jev_key()
    os.makedirs(a.out, exist_ok=True)

    def ask(job):
        subject, state, preface, questions = job
        body = {"state": state, "model": "jev-latest",
                "questions": {q["id"]: {"type": "noul", "instructions": preface + "\n" + q["asks"], "criteria": {"true": q["yes"], "false": q["no"]}}
                              for q in questions}}
        resp, secs = post(body, key)
        return job, body, resp, secs

    rows = []
    with concurrent.futures.ThreadPoolExecutor(a.workers) as pool, open(os.path.join(a.out, "prompts.jsonl"), "w") as log:
        for (subject, _, _, questions), body, resp, secs in pool.map(ask, jobs):
            log.write(json.dumps({"subject": subject, "request": body, "response": resp}, ensure_ascii=False) + "\n")
            for q in questions:
                k = (subject, q["id"])
                if k not in expected:
                    continue
                ans = (resp.get("answers") or {}).get(q["id"])
                pf = flagging(p, q["id"], float(ans["noul"])) if ans and "noul" in ans else None
                rows.append((expected[k][0], subject, q["id"], pf, expected[k][1], old.get(k), secs, (resp.get("usage") or {}).get("input_tokens", 0)))

    def tally(pairs):
        n = dict(pos=0, caught=0, unsure_pos=0, neg=0, false=0, unsure_neg=0, unread=0)
        for pf, exp in pairs:
            if pf is None:
                n["unread"] += 1
                continue
            if exp:
                n["pos"] += 1
                if pf >= FLAG:
                    n["caught"] += 1
                elif pf > HOLD:
                    n["unsure_pos"] += 1
            else:
                n["neg"] += 1
                if pf >= FLAG:
                    n["false"] += 1
                elif pf > HOLD:
                    n["unsure_neg"] += 1
        return n

    print(f"# The shipped rule words, asked of Jev over {a.run}\n")
    print("| rule | words | n+ | caught | unsure+ | n− | false alarms | unsure− | unread |")
    print("|---|---|---|---|---|---|---|---|---|")
    for rule in sorted({r[0] for r in rows}):
        for name, idx in (("shipped", 3), ("round's own", 5)):
            pairs = [(r[idx], r[4]) for r in rows if r[0] == rule and (idx == 3 or r[5] is not None)]
            n = tally(pairs)
            print(f"| {rule} | {name} | {n['pos']} | {n['caught']} | {n['unsure_pos']} | {n['neg']} | {n['false']} | {n['unsure_neg']} | {n['unread']} |")
    drift = [abs(r[3] - r[5]) for r in rows if r[3] is not None and r[5] is not None]
    if drift:
        drift.sort()
        print(f"\nper question, |shipped - round|: median {drift[len(drift) // 2]:.3f}, max {drift[-1]:.3f}; "
              f"median {sorted(r[6] for r in rows)[len(rows) // 2]:.2f} s a call")


if __name__ == "__main__":
    main()
