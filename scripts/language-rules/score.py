#!/usr/bin/env python3
"""Score a run of evals.py: for each rule and variant, what it caught, what it missed, its false alarms and how
often it was unsure, at the cutoffs the feature would use (a flag at a probability of 0.7 or more, a pass at 0.3 or
less, unsure between), and how well the probabilities separate the two (AUC: 1 is perfect, 0.5 chance).

    python3 score.py RUN [RUN ...] > summary.md
"""
import csv
import statistics
import sys
from collections import defaultdict

FLAG, PASS = 0.7, 0.3


def auc(pos, neg):
    if not pos or not neg:
        return None
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def rows_of(paths):
    out = []
    for path in paths:
        with open(f"{path}/results.tsv") as f:
            out += list(csv.DictReader(f, delimiter="\t"))
    return out


def table(rows, keys, title):
    groups = defaultdict(list)
    for r in rows:
        groups[tuple(r[k] for k in keys)].append(r)
    print(f"\n### {title}\n")
    print("| " + " | ".join(keys) + " | n+ | caught | missed | unsure+ | n− | false alarms | unsure− | AUC | median s |")
    print("|" + "---|" * (len(keys) + 9))
    for key in sorted(groups):
        g = groups[key]
        pos = [float(r["p_flag"]) for r in g if r["expect"] == "True"]
        neg = [float(r["p_flag"]) for r in g if r["expect"] == "False"]
        if not pos and not neg:
            continue
        caught = sum(p >= FLAG for p in pos)
        missed = sum(p <= PASS for p in pos)
        fa = sum(p >= FLAG for p in neg)
        a = auc(pos, neg)
        secs = statistics.median(float(r["seconds"]) for r in g)
        print("| " + " | ".join(key) + f" | {len(pos)} | {caught} | {missed} | {len(pos) - caught - missed} | {len(neg)} | "
              f"{fa} | {sum(PASS < p < FLAG for p in neg)} | {'' if a is None else f'{a:.2f}'} | {secs:.2f} |")


def main(paths):
    rows = rows_of(paths)
    rules = sorted({r["rule"] for r in rows})
    print(f"# Language rules: eval results\n\n{len(rows)} verdicts from {len(paths)} run(s). Cutoffs: flag at p ≥ {FLAG}, "
          f"pass at p ≤ {PASS}, unsure between. A + is a shape the rule should flag, a − one it shouldn't.")
    for rule in rules:
        rr = [r for r in rows if r["rule"] == rule]
        if not any(r["expect"] in ("True", "False") for r in rr):
            continue
        table(rr, ["provider", "mode", "polarity", "budget"], f"{rule}")
    # the vintage override: Car's rule on vintage cars, read alone and read with Vintage's "mileage doesn't matter"
    vint = [r for r in rows if r["rule"] == "car-mileage" and r["subject"] in ("Car 31", "Car 32", "Car 33", "Car 34", "Car 35", "Car 36")]
    if vint:
        print("\n### The vintage override: Car's mileage rule on the six vintage cars\n")
        print("Mean probability that Car's rule flags them (0 is what Vintage's \"mileage doesn't matter\" asks for).\n")
        print("| provider | mode | polarity | budget | " + " | ".join(sorted({r['subject'] for r in vint}, key=lambda s: int(s.split()[1]))) + " | mean |")
        subjects = sorted({r['subject'] for r in vint}, key=lambda s: int(s.split()[1]))
        print("|" + "---|" * (5 + len(subjects)))
        g = defaultdict(dict)
        for r in vint:
            g[(r["provider"], r["mode"], r["polarity"], r["budget"])][r["subject"]] = float(r["p_flag"])
        for key in sorted(g):
            vals = [g[key].get(s) for s in subjects]
            print("| " + " | ".join(key) + " | " + " | ".join("" if v is None else f"{v:.2f}" for v in vals) +
                  f" | {statistics.mean(v for v in vals if v is not None):.2f} |")
    qual = [r for r in rows if r["rule"] == "vintage-qualifier"]
    if qual:
        print("\n### A qualifier asked as a check\n")
        print("Vintage's \"Mileage doesn't matter for a vintage car\" says how to read another rule. Asked on its own, "
              "what did each variant make of it (mean probability it flags the car)?\n")
        g = defaultdict(list)
        for r in qual:
            g[(r["provider"], r["mode"], r["polarity"])].append(float(r["p_flag"]))
        print("| provider | mode | polarity | mean p_flag | flagged (≥0.7) of n |")
        print("|---|---|---|---|---|")
        for key in sorted(g):
            v = g[key]
            print("| " + " | ".join(key) + f" | {statistics.mean(v):.2f} | {sum(p >= FLAG for p in v)} of {len(v)} |")
    dist = [r for r in rows if r["rule"] == "vote-district" and r["provider"] == "jev" and r["mode"] == "composed"
            and r["polarity"] == "flag" and r["budget"] == "medium"]
    if dist:
        print("\n### Unusual for the district: the votes Jev flags most (composed, flag, medium), for a person to judge\n")
        print("| vote | p_flag | Voteview: unusual for the record? |")
        print("|---|---|---|")
        rec = {(r["subject"]): r["expect"] for r in rows if r["rule"] == "vote-record"}
        for r in sorted(dist, key=lambda r: -float(r["p_flag"]))[:25]:
            print(f"| {r['subject']} | {float(r['p_flag']):.2f} | {rec.get(r['subject'], '')} |")
        print(f"\n{sum(float(r['p_flag']) >= FLAG for r in dist)} of {len(dist)} votes flagged at p ≥ {FLAG}.")
    secs = defaultdict(list)
    toks = defaultdict(list)
    for r in rows:
        secs[r["provider"]].append(float(r["seconds"]))
        if r["tokens_in"]:
            toks[r["provider"]].append(int(r["tokens_in"]))
    print("\n### Time and size\n")
    for p in secs:
        s = sorted(secs[p])
        print(f"- {p}: median {statistics.median(s):.2f} s a call, 90th percentile {s[int(len(s) * 0.9)]:.2f} s; "
              f"median {statistics.median(toks[p]) if toks[p] else 0:.0f} input tokens.")


if __name__ == "__main__":
    main(sys.argv[1:])
