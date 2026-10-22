#!/usr/bin/env python3
"""Evals for a note's fields filled from its words (FieldFill): does the model set what the words say, and only that?
The request is put together as the app puts it: the system prompt, max_tokens, the model and its effort out of
Sources/Types/Sync/FillPrompts.swift (`system`, `maxTokens`, `model`, `effort`), the user message as
`FillPrompts.request` lays it out, and the answer read and written as `FillPrompts.parse` and `FieldFill.apply` do
(a member no field names passed over, a group set member by member, a list whole, null taking a value away, empties
not kept), so there's one copy of the prompt.

    python3 fill_evals.py --check                    # read the prompt and settings, self-test the scoring; no call
    python3 fill_evals.py                            # every case in fill_cases.py, three times
    python3 fill_evals.py --runs 1 --only owner_feature,edit_adds -v
    EVAL_EFFORT=medium python3 fill_evals.py         # another effort than the app's

Scores each answer by the values the note would hold once it is written: each field a case names holds one of the
values it allows (text compared loosely), every other field holds what it held, and no key no field names is set.
Reads the key from ~/Library/Application Support/InfiniteCanvas/anthropic-api-key (where the app's Settings saves
it), else $ANTHROPIC_API_KEY, and never prints it (evalkit).
"""
import argparse
import concurrent.futures
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from evalkit import SOURCES, Fatal, block, call, literal, load_key, number_setting, read_swift, text_setting, unwrap  # noqa: E402
from fill_cases import ABSENT, CASES, TODAY  # noqa: E402
from gen_cases import fmt  # noqa: E402

SWIFT = os.path.join(SOURCES, "Types", "Sync", "FillPrompts.swift")
NO_CHANGE = "NO_CHANGE"


def swift_settings():
    src = read_swift(SWIFT)
    return {"system": literal(src, "system", SWIFT), "model": text_setting(src, "model", SWIFT),
            "effort": text_setting(src, "effort", SWIFT), "max_tokens": int(number_setting(src, "maxTokens", SWIFT))}


def user_message(case):
    """FillPrompts.request: the fields, the values (keys in order), today, the words before and the words, each a
    block, a block with nothing left out."""
    values = {k: case["values"][k] for k in sorted(case["values"])}
    blocks = [block("fields", fmt(case["fields"])), block("values", fmt(values)), block("today", TODAY),
              block("previous_words", case.get("previous", "")), block("words", case["words"])]
    return "\n\n".join(b for b in blocks if b)


# ------------------------------------------------------------------ reading and writing an answer, as the app does

def says_no_change(t):
    def starts(t):
        if not t.startswith(NO_CHANGE):
            return False
        rest = t[len(NO_CHANGE):]
        return not rest or not (rest[0].isalnum() or rest[0] == "_")
    last = ([line for line in t.split("\n") if line] or [""])[-1].strip()
    return starts(t) or (len(last) < len(NO_CHANGE) + 3 and starts(last))


def parse(answer):
    """FillPrompts.parse: the changes, or None for an answer that can't be used."""
    if answer["stop_reason"] != "end_turn":
        return None
    text = unwrap(answer["text"], "changes")
    if says_no_change(text):
        return {}
    if not (text.startswith("{") and text.endswith("}")):
        return None
    try:
        changes = json.loads(text)
    except ValueError:
        return None
    return changes if isinstance(changes, dict) else None


def pruned(value):
    """FieldValues.pruned: nothing empty is kept, at any depth."""
    if value is None or value == "":
        return None
    if isinstance(value, list):
        items = [p for p in (pruned(v) for v in value) if p is not None]
        return items or None
    if isinstance(value, dict):
        members = {k: p for k, p in ((k, pruned(v)) for k, v in value.items()) if p is not None}
        return members or None
    return value


def merged(written, held):
    """FieldValuesMerge.merged."""
    if not isinstance(written, dict):
        return written
    if held is not None and not isinstance(held, dict) and pruned(written) is None:
        return held
    result = dict(held) if isinstance(held, dict) else {}
    for key, member in written.items():
        if member is None:
            result.pop(key, None)
        else:
            result[key] = merged(member, result.get(key))
    return result


def apply(case, changes):
    """FieldFill.apply, with nothing changed while the call was out: the values the note holds after."""
    keys = set(case["fields"]["properties"])
    held = dict(case["values"])
    for key in sorted(changes):
        if key not in keys:
            continue
        change = changes[key]
        value = None if change is None else pruned(merged(change, held.get(key)))
        if value is None:
            held.pop(key, None)
        else:
            held[key] = value
    return held


# ------------------------------------------------------------------ scoring

def loose(value):
    if isinstance(value, str):
        return " ".join(value.strip().strip(".,;:!\"'“”").casefold().split())
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, list):
        return [loose(v) for v in value]
    if isinstance(value, dict):
        return {k: loose(v) for k, v in value.items()}
    return value


def score(case, after):
    """What's wrong with the values after, each a line; none for an answer that's right."""
    wrong = []
    for key, allowed in case["expect"].items():
        got = after.get(key, ABSENT)
        if not any((got is ABSENT) if want is ABSENT else (got is not ABSENT and loose(got) == loose(want)) for want in allowed):
            shown = [("(none)" if w is ABSENT else w) for w in allowed]
            wrong.append(f"{key}: {('(none)' if got is ABSENT else json.dumps(got, ensure_ascii=False))}, wanted one of {shown}")
    for key in set(case["values"]) | set(after):
        if key not in case["expect"] and after.get(key, ABSENT) != case["values"].get(key, ABSENT):
            wrong.append(f"{key}: changed from {case['values'].get(key, '(none)')!r} to {after.get(key, '(none)')!r}, which the words don't ask")
    return wrong


def selftest():
    """The scoring and the apply rule, on answers whose verdict is known."""
    case = next(c for c in CASES if c["id"] == "edit_removes_hand_kept")
    failures = []
    if score(case, apply(case, {"owner": None})) == []:
        failures.append("a hand-typed owner taken away should fail")
    if score(case, apply(case, {})) != []:
        failures.append("nothing changed should pass")
    task = next(c for c in CASES if c["id"] == "task_started")
    good = {"purpose": "To sort incoming mail.", "status": "doing", "estimate": 3}
    if score(task, apply(task, good)) != []:
        failures.append(f"a right answer, loosely: {score(task, apply(task, good))}")
    if score(task, apply(task, dict(good, owner="Sam"))) == []:
        failures.append("an owner the words don't give should fail")
    if score(task, apply(task, dict(good, colour="red"))) != []:
        failures.append("a key no field names is passed over, as the app does")
    nested = next(c for c in CASES if c["id"] == "nested_group")
    if score(nested, apply(nested, {"name": "Ann", "address": {"street": "12 Elm St", "city": "Leeds", "zip": None}})) != []:
        failures.append("a group set member by member, a null in it dropped")
    for text, expected in [("```json\n{\"a\": 1}\n```", {"a": 1}), ("NO_CHANGE", {}), ("{}", {}), ("Here: {\"a\": 1}", None), ("[1]", None)]:
        if parse({"text": text, "stop_reason": "end_turn"}) != expected:
            failures.append(f"parse {text!r}")
    if parse({"text": "{}", "stop_reason": "max_tokens"}) is not None:
        failures.append("a cut-off answer is unusable")
    if failures:
        raise Fatal("the scoring's self-test failed:\n  " + "\n  ".join(failures))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="read the prompt and settings out of the Swift, self-test; no call")
    ap.add_argument("--model", default=None, help="another model than the app's, to compare")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    settings = swift_settings()
    model = args.model or settings["model"]
    effort = os.environ.get("EVAL_EFFORT") or settings["effort"]
    cases = [c for c in CASES if not args.only or c["id"] in args.only.split(",")]
    selftest()
    if args.check:
        print(f"{model}, effort {effort}, max_tokens {settings['max_tokens']}; prompt {len(settings['system'])} characters; "
              f"{len(cases)} cases; the scoring's self-test passed")
        return
    key = load_key()
    if not key:
        raise Fatal("no key: save one in the app's Settings, or set ANTHROPIC_API_KEY")
    work = [(c, r) for c in cases for r in range(args.runs)]

    def run(item):
        c, r = item
        temperature, used = (0.0, None) if model.startswith("claude-haiku-4") else (None, effort)
        answer = call(key, model, settings["max_tokens"], settings["system"], user_message(c), effort=used, temperature=temperature)
        return c, r, answer, parse(answer)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run, work))
    passed, ms, tokens_in, tokens_out, records = 0, [], 0, 0, []
    for c, r, answer, changes in results:
        ms.append(answer["ms"])
        tokens_in += answer["in"]
        tokens_out += answer["out"]
        if changes is None:
            print(f"!! {c['id']} #{r}: unusable ({answer['stop_reason']}): {answer['text'][:200]!r}")
            records.append({"id": c["id"], "run": r, "unusable": True, "answer": answer["text"]})
            continue
        wrong = score(c, apply(c, changes))
        passed += not wrong
        print(f"{'ok' if not wrong else '!!'} {c['id']} #{r}: {answer['ms']} ms, {answer['out']} tokens out")
        if wrong or args.verbose:
            print(f"     answer {json.dumps(changes, ensure_ascii=False)}")
        for line in wrong:
            print(f"     {line}")
        records.append({"id": c["id"], "run": r, "changes": changes, "wrong": wrong, "ms": answer["ms"], "out": answer["out"]})
    print()
    print(f"{model}, effort {effort}: {passed}/{len(results)} answers right")
    ms.sort()
    if ms:
        print(f"latency p50 {ms[len(ms) // 2]} ms, max {ms[-1]} ms; tokens in {tokens_in}, out {tokens_out}")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"model": model, "effort": effort, "passed": passed, "records": records}, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    try:
        main()
    except Fatal as e:
        raise SystemExit(str(e))
