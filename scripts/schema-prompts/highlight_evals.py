#!/usr/bin/env python3
"""Evals for a type's highlights: does the model link its words' words to the right
parts of its schema? The highlights are a prose map (Sources/ProseMaps), so the request is put
together as the app puts it: every target's frame, the model, its effort and max_tokens out of
Sources/ProseMaps/ProseMapPrompt.swift (`frame`, `model`, `effort`, `maxTokens`), with the schema's
guide in it and what's said of other schemas after it out of Sources/Types/Sync/SchemaPrompts.swift
(`highlightsGuide`, `highlightsReferences`), so there's one copy.

    python3 highlight_evals.py --check                  # read the prompt and settings; no call
    python3 highlight_evals.py                          # every case in highlight_cases.py, once
    python3 highlight_evals.py --runs 2 --out r1.json   # twice each, everything written to r1.json
    python3 highlight_evals.py --model claude-haiku-4-5 --only jira,typo -v

Scores each answer as the app reads it: its links' words found in the description in order
(`anchor`, ProseMapText.anchor's rule) and their addresses followed in the schema (`resolve`). A
link is right when it overlaps words the case lists and points where they may (loosely, when its
words are wider or narrower), misattributed when it overlaps listed words but points elsewhere (the
popover would show the wrong part), an extra when it overlaps none (printed to be read), and
invalid when its words aren't in the description or its pointer leads nowhere. Recall is the
listed links found. Reads the key from ~/Library/Application Support/InfiniteCanvas/anthropic-api-key
(where the app's Settings saves it), else $ANTHROPIC_API_KEY, and never prints it.
"""
import argparse
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from highlight_cases import CASES, NEVER  # noqa: E402

API_URL = "https://api.anthropic.com/v1/messages"
SWIFT = os.path.normpath(os.path.join(HERE, "..", "..", "Sources", "Types", "Sync", "SchemaPrompts.swift"))
FRAME_SWIFT = os.path.normpath(os.path.join(HERE, "..", "..", "Sources", "ProseMaps", "ProseMapPrompt.swift"))


class Fatal(Exception):
    pass


def literal(src, name, path):
    """A raw string literal's text, between its delimiters, as Swift reads it."""
    m = re.search(r'static let ' + name + r' = #"""\n(.*?)\n"""#', src, re.S)
    if not m:
        raise Fatal(f"no {name} in {path}")
    return m.group(1)


def swift_settings():
    """The system prompt as ProseMapPrompt.system(for: SchemaTarget.self) makes it (the frame, the
    target's name "schema" and its guide in it, less the guide's final line breaks), what's said of
    other schemas, the model, the effort and max_tokens, read out of the Swift."""
    with open(FRAME_SWIFT, encoding="utf-8") as f:
        frame_src = f.read()
    with open(SWIFT, encoding="utf-8") as f:
        src = f.read()
    guide = literal(src, "highlightsGuide", SWIFT).rstrip("\n")
    system = literal(frame_src, "frame", FRAME_SWIFT).replace("{name}", "schema").replace("{guide}", guide)

    def value(name, pattern):
        found = re.search(r'static let ' + name + r' = ' + pattern, frame_src)
        if not found:
            raise Fatal(f"no {name} in {FRAME_SWIFT}")
        return found.group(1)
    return {"system": system, "references": literal(src, "highlightsReferences", SWIFT), "model": value("model", r'"([^"]+)"'),
            "effort": value("effort", r'"([^"]+)"'), "max_tokens": int(value("maxTokens", r'([0-9_]+)').replace("_", ""))}


def block(tag, text):
    text = (text or "").strip()
    return f"<{tag}>\n{text}\n</{tag}>" if text else ""


def user_message(prompt, schema):
    """ProseMapPrompt.request: the prose and the target in tagged blocks, each trimmed, a blank line
    between."""
    return "\n\n".join(p for p in (block("prose", prompt), block("schema", schema)) if p)


def load_key():
    path = os.path.expanduser("~/Library/Application Support/InfiniteCanvas/anthropic-api-key")
    try:
        with open(path, encoding="utf-8") as f:
            key = f.read().strip()
            if key:
                return key
    except OSError:
        pass
    return os.environ.get("ANTHROPIC_API_KEY", "").strip() or None


def call(key, settings, model, user, names_schemas=False):
    # What it says of other schemas after it, a blank line apart, for a prompt that names some (the
    # context SchemaHighlightsShown passes, which ProseMapPrompt.system puts after the frame).
    system = settings["system"] + "\n" + settings["references"] if names_schemas else settings["system"]
    body = {"model": model, "max_tokens": settings["max_tokens"], "system": system,
            "messages": [{"role": "user", "content": user}]}
    if model.startswith("claude-haiku-4"):
        body["temperature"] = 0.0      # Haiku 4.5 takes no effort; the app asks it at 0, as the sync does
    else:                              # Sonnet 5.5 and Haiku 5.5 take an effort and no temperature but their default
        body["output_config"] = {"effort": os.environ.get("EVAL_EFFORT") or settings["effort"]}
    data = json.dumps(body).encode("utf-8")
    headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}
    delay = 2.0
    for attempt in range(6):
        req = urllib.request.Request(API_URL, data=data, headers=headers, method="POST")
        started = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=60 + settings["max_tokens"] / 100) as resp:
                answer = json.load(resp)
            ms = int((time.monotonic() - started) * 1000)
            text = "".join(b.get("text", "") for b in answer.get("content", []) if b.get("type") == "text")
            usage = answer.get("usage", {})
            return {"text": text, "stop_reason": answer.get("stop_reason"), "ms": ms,
                    "in": usage.get("input_tokens", 0), "out": usage.get("output_tokens", 0)}
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = json.load(e).get("error", {}).get("message", "")
            except Exception:
                pass
            if e.code in (429, 500, 502, 503, 529) and attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise Fatal(f"HTTP {e.code}: {detail}")
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise Fatal(f"network: {e}")
    raise Fatal("gave up")


# ------------------------------------------------------------------ reading an answer, as the app does

def is_wrapper(line):
    line = line.strip()
    return line.startswith("```") or re.fullmatch(r"</?[A-Za-z_-]+>", line) is not None


def unwrap(t):
    """ModelAnswer.unwrapped: without a fence line or a lone tag's line at either end, again until
    nothing changes."""
    while True:
        before = t
        lines = t.strip().split("\n")
        if lines and is_wrapper(lines[0]):
            lines = lines[1:]
        if lines and is_wrapper(lines[-1]):
            lines = lines[:-1]
        t = "\n".join(lines).strip()
        if t == before:
            return t


def last_array(text):
    """The whole answer if it reads as a JSON array, else the last run of lines from one starting
    with [ to one ending with ] that does (ProseMapPrompt.links)."""
    try:
        items = json.loads(text)
        if isinstance(items, list):
            return items
    except ValueError:
        pass
    lines = text.split("\n")
    for end in range(len(lines) - 1, -1, -1):
        if not lines[end].strip().endswith("]"):
            continue
        for start in range(end, -1, -1):
            if not lines[start].strip().startswith("["):
                continue
            try:
                items = json.loads("\n".join(lines[start:end + 1]))
            except ValueError:
                continue
            if isinstance(items, list):
                return items
    return None


def parse(answer):
    """The links (words, pointer) an answer lists, each pointer its "address", or None for one that
    can't be read."""
    if answer["stop_reason"] != "end_turn":
        return None
    items = last_array(unwrap(answer["text"]))
    if items is None:
        return None
    return [(item["text"], item["address"]) for item in items
            if isinstance(item, dict) and isinstance(item.get("text"), str) and item["text"].strip()
            and isinstance(item.get("address"), str)]


def is_word(c):
    return c.isalnum() or c == "_"


def anchor(prompt, texts):
    """ProseMapText.anchor: where each text is, in order, (start, end) or None: as written, then
    ignoring case; from the end of the last one placed, then from the start; at word boundaries,
    then anywhere; never overlapping one placed."""
    placed, spans, cursor = [], [], 0
    lowered = prompt.lower() if len(prompt.lower()) == len(prompt) else None
    for text in texts:
        found = None
        for fold in (False, True):
            if found or not text or (fold and (lowered is None or len(text.lower()) != len(text))):
                continue
            hay, needle = (lowered, text.lower()) if fold else (prompt, text)
            for start_at in (cursor, 0):
                for bounded in (True, False):
                    i = hay.find(needle, start_at)
                    while i != -1 and found is None:
                        j = i + len(needle)
                        clear = all(j <= a or i >= b for a, b in placed)
                        whole = (i == 0 or not is_word(prompt[i - 1]) or not is_word(prompt[i])) and \
                                (j == len(prompt) or not is_word(prompt[j]) or not is_word(prompt[j - 1]))
                        if clear and (whole or not bounded):
                            found = (i, j)
                        else:
                            i = hay.find(needle, i + 1)
                    if found:
                        break
                if found:
                    break
        spans.append(found)
        if found:
            placed.append(found)
            cursor = found[1]
    return spans


def resolve(schema, pointer):
    """JSONPointer.resolve: whether an RFC 6901 pointer (or its "#…" form) leads to a member."""
    p = pointer[1:] if pointer.startswith("#") else pointer
    # A "#…" form is percent-decoded first, as written where an escape is malformed.
    if pointer.startswith("#") and not re.search(r"%(?![0-9A-Fa-f]{2})", p):
        try:
            p = urllib.parse.unquote(p, errors="strict")
        except UnicodeDecodeError:
            pass
    if p == "":
        return True
    if not p.startswith("/"):
        return False
    node = schema
    for raw in p.split("/")[1:]:
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict):
            if token not in node:
                return False
            node = node[token]
        elif isinstance(node, list):
            if not re.fullmatch(r"0|[1-9][0-9]*", token) or int(token) >= len(node):
                return False
            node = node[int(token)]
        else:
            return False
    return True


# ------------------------------------------------------------------ scoring

def score(case, links):
    prompt, schema, expected = case["prompt"], json.loads(case["schema"]), case["links"]
    expected_spans = anchor(prompt, [w for w, _ in expected])
    for (words, _), span in zip(expected, expected_spans):
        if span is None:
            raise Fatal(f"{case['id']}: the case's words {words!r} aren't in its prompt")
    hit = [False] * len(expected)
    rows = []
    for (text, pointer), span in zip(links, anchor(prompt, [t for t, _ in links])):
        if span is None:
            rows.append(("invalid_text", text, pointer, None))
            continue
        if not resolve(schema, pointer):
            rows.append(("invalid_pointer", text, pointer, None))
            continue
        pointer = pointer[1:] if pointer.startswith("#") else pointer
        overlapping = [k for k, (a, b) in enumerate(expected_spans) if span[0] < b and a < span[1]]
        right = [k for k in overlapping if pointer in expected[k][1]]
        if right:
            best = max(right, key=lambda k: min(span[1], expected_spans[k][1]) - max(span[0], expected_spans[k][0]))
            hit[best] = True
            rows.append(("right" if span == expected_spans[best] else "right_loose", text, pointer, expected[best][0]))
        elif overlapping:
            rows.append(("misattributed", text, pointer, " / ".join(f"{expected[k][0]}→{expected[k][1][0]}" for k in overlapping)))
        else:
            rows.append(("extra", text, pointer, None))
    counted = [k for k in range(len(expected)) if expected[k][1] != [NEVER]]
    return {"expected": len(counted), "hits": sum(hit[k] for k in counted), "rows": rows,
            "missed": [expected[k] for k in counted if not hit[k]]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="read the prompt and settings out of the Swift; no call")
    ap.add_argument("--model", default=None, help="another model than the app's, to compare")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    settings = swift_settings()
    model = args.model or settings["model"]
    cases = [c for c in CASES if not args.only or c["id"] in args.only.split(",")]
    if args.check:
        print(f"{model}, effort {settings['effort']}, max_tokens {settings['max_tokens']}; "
              f"prompt {len(settings['system'])} characters; {len(cases)} cases")
        for c in cases:
            score(c, [])                   # the cases' own words must be in their prompts
        return
    key = load_key()
    if not key:
        raise Fatal("no key: save one in the app's Settings, or set ANTHROPIC_API_KEY")
    work = [(c, r) for c in cases for r in range(args.runs)]

    def run(item):
        c, r = item
        answer = call(key, settings, model, user_message(c["prompt"], c["schema"]), c.get("names_schemas", False))
        return c, r, answer, parse(answer)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run, work))
    totals = dict.fromkeys(["expected", "hits", "right", "right_loose", "misattributed", "extra", "invalid_text",
                            "invalid_pointer", "unreadable"], 0)
    ms, tokens_in, tokens_out, records = [], 0, 0, []
    for c, r, answer, links in results:
        ms.append(answer["ms"])
        tokens_in += answer["in"]
        tokens_out += answer["out"]
        if links is None:
            totals["unreadable"] += 1
            totals["expected"] += sum(1 for _, p in c["links"] if p != [NEVER])
            print(f"!! {c['id']} #{r}: unreadable ({answer['stop_reason']}): {answer['text'][:200]!r}")
            records.append({"id": c["id"], "run": r, "unreadable": True, "answer": answer["text"]})
            continue
        s = score(c, links)
        totals["expected"] += s["expected"]
        totals["hits"] += s["hits"]
        for kind, *_ in s["rows"]:
            totals[kind] += 1
        bad = [row for row in s["rows"] if row[0] in ("misattributed", "invalid_text", "invalid_pointer")]
        print(f"{'ok' if not bad and not s['missed'] else '!!'} {c['id']} #{r}: {s['hits']}/{s['expected']} links, "
              f"{answer['ms']} ms, {answer['out']} tokens out")
        for kind, text, pointer, note in s["rows"]:
            if args.verbose or kind in ("misattributed", "invalid_text", "invalid_pointer", "extra"):
                print(f"     {kind:15} {text!r} → {pointer!r}" + (f"   [{note}]" if note else ""))
        for words, pointers in s["missed"]:
            print(f"     {'missed':15} {words!r} → {pointers[0]!r}")
        records.append({"id": c["id"], "run": r, "links": links, "rows": s["rows"], "missed": s["missed"],
                        "ms": answer["ms"], "in": answer["in"], "out": answer["out"]})
    drawn = sum(totals[k] for k in ("right", "right_loose", "misattributed", "extra", "invalid_text", "invalid_pointer"))
    print()
    print(f"{model}, {len(results)} answers")
    print(f"recall {totals['hits']}/{totals['expected']} = {totals['hits'] / max(1, totals['expected']):.1%}")
    print(f"links drawn {drawn}: right {totals['right']}, right but wider or narrower {totals['right_loose']}, "
          f"misattributed {totals['misattributed']}, extra {totals['extra']}, words not in the prompt "
          f"{totals['invalid_text']}, pointer to nothing {totals['invalid_pointer']}; unreadable answers {totals['unreadable']}")
    ms.sort()
    if ms:
        print(f"latency p50 {ms[len(ms) // 2]} ms, max {ms[-1]} ms; tokens in {tokens_in}, out {tokens_out}")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"model": model, "totals": totals, "records": records}, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    try:
        main()
    except Fatal as e:
        raise SystemExit(str(e))
