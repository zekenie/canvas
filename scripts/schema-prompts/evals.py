#!/usr/bin/env python3
"""Quick and dirty evals for a type's two prompts, as the app ships them: the system prompts
are read out of Sources/Types/SchemaPrompts.swift, so there's one copy.

    python3 evals.py --check                # read the prompts and settings out of the Swift; no call
    python3 evals.py --round 1              # every case in cases.csv, and the chains
    python3 evals.py --round 1 --only s_rename,p_add_field --runs 3
    python3 evals.py --round 1 --no-chains

Appends to results.csv (one row per case per run) and results.jsonl (everything, not committed).
Reads the key from ~/Library/Application Support/InfiniteCanvas/anthropic-api-key (where the app's
Settings saves it), else $ANTHROPIC_API_KEY, and never prints it. Calls https://api.anthropic.com
directly. Python 3.9 stdlib; jsonschema (for the meta-validation) from ./_pylib when it's there.
"""
import argparse
import concurrent.futures
import csv
import difflib
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "_pylib"))
try:
    from jsonschema import Draft202012Validator
except ImportError:  # meta-validation is skipped without it, and says so
    Draft202012Validator = None

sys.path.insert(0, HERE)
from gen_cases import fmt, STARTER, ORDER  # noqa: E402

# ------------------------------------------------------------------ the contract, read out of the Swift

API_URL = "https://api.anthropic.com/v1/messages"
SOURCES = os.path.normpath(os.path.join(HERE, "..", "..", "Sources"))
SWIFT = os.path.join(SOURCES, "Types", "SchemaPrompts.swift")
# Each direction's system prompt and max_tokens (the Swift constants they're read from):
# `swift_settings` fills in the values, and MODEL and EFFORT, from the Swift.
CONFIG = {
    "to_schema": {"system": "toSchemaSystem", "references": "toSchemaReferences", "max_tokens_name": "toSchemaMaxTokens"},
    "to_prompt": {"system": "toPromptSystem", "references": "toPromptReferences", "max_tokens_name": "toPromptMaxTokens"},
}
MODEL = None
EFFORT = None
NO_CHANGE = "NO_CHANGE"
# A prompt answer that reads as something other than the prompt (SchemaPrompts.isNotAPrompt).
PREAMBLES = ("here's ", "here’s ", "here is ", "here are ", "updated prompt", "updated description",
             "the updated prompt", "the updated description", "prompt:", "description:",
             "sure,", "sure!", "sure.", "certainly,", "certainly!", "certainly.")


def block(tag, text):
    text = (text or "").strip()
    return f"<{tag}>\n{text}\n</{tag}>" if text else ""


def user_message(direction, prompt="", schema="", previous_prompt="", previous_schema="", schemas=""):
    if direction == "to_schema":
        parts = [block("schemas", schemas), block("previous_prompt", previous_prompt), block("prompt", prompt), block("schema", schema)]
    else:
        parts = [block("schemas", schemas), block("prompt", prompt), block("previous_schema", previous_schema), block("schema", schema)]
    return "\n\n".join(p for p in parts if p)


def is_wrapper(line):
    """A fence line, or a line of one tag alone (<answer>, </output>)."""
    line = line.strip()
    return line.startswith("```") or re.fullmatch(r"</?[A-Za-z_-]+>", line) is not None


def unwrap(t, tag):
    """Strips what the model sometimes wraps an answer in, from either end: a code-fence line (one that
    starts with three backticks), a line of one tag alone (</output>), and the block's own tags
    (<schema>, </schema>). Repeats until nothing changes."""
    while True:
        before = t
        lines = t.split("\n")
        if lines and is_wrapper(lines[0]):
            lines = lines[1:]
        if lines and is_wrapper(lines[-1]):
            lines = lines[:-1]
        t = "\n".join(lines).strip()
        if t.startswith(f"<{tag}>"):
            t = t[len(tag) + 2:].strip()
        if t.endswith(f"</{tag}>"):
            t = t[: -(len(tag) + 3)].strip()
        if t == before:
            return t


def says_no_change(t):
    """NO_CHANGE as the first word, or the last line: nothing after it, or something that isn't a
    letter, digit or _."""
    def starts(t):
        if not t.startswith(NO_CHANGE):
            return False
        rest = t[len(NO_CHANGE):]
        return not rest or not (rest[0].isalnum() or rest[0] == "_")
    last = ([line for line in t.split("\n") if line] or [""])[-1].strip()
    return starts(t) or (len(last) < len(NO_CHANGE) + 3 and starts(last))


def unquoted(t):
    """Without one pair of quotes around the whole of it, if it has them and none inside."""
    for open_, close in (('"', '"'), ("“", "”"), ("'", "'")):
        if len(t) >= 2 and t.startswith(open_) and t.endswith(close):
            inner = t[1:-1]
            return t if (open_ in inner or close in inner) else inner.strip()
    return t


def is_not_a_prompt(t):
    return NO_CHANGE in t or "```" in t or t.lower().startswith(PREAMBLES)


def parse(direction, text, stop_reason):
    """The parse rule, as the Swift side does it. Returns (kind, value): ("nochange", None),
    ("schema", text), ("prompt", text) or ("error", why)."""
    if stop_reason != "end_turn":
        return "error", f"stop_reason={stop_reason}"
    t = unwrap(text.strip(), "schema" if direction == "to_schema" else "prompt")
    if says_no_change(t):
        return "nochange", None
    if direction == "to_schema":
        if not (t.startswith("{") and t.endswith("}")):
            return "error", "not a JSON object"
        try:
            obj = json.loads(t)
        except ValueError as e:
            return "error", f"invalid JSON: {e}"
        if not isinstance(obj, dict):
            return "error", "not a JSON object"
        return "schema", t
    t = unquoted(t)
    if not t:
        return "error", "empty"
    if is_not_a_prompt(t):
        return "error", "not a prompt"
    return "prompt", t


# ------------------------------------------------------------------ calling

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


SYSTEMS = {}


class Fatal(Exception):
    pass


def swift_source():
    with open(SWIFT, encoding="utf-8") as f:
        return f.read()


def literal(name):
    """The raw string literal `public static let <name> = #\"\"\"` ... `\"\"\"#`, flush left, as Swift
    reads it: the lines between the delimiters, without the last line break."""
    if name not in SYSTEMS:
        m = re.search(r'static let ' + name + r' = #"""\n(.*?)\n"""#', swift_source(), re.S)
        if not m:
            raise Fatal(f"no {name} in {SWIFT}")
        SYSTEMS[name] = m.group(1)
    return SYSTEMS[name]


def system_prompt(direction, schemas=""):
    """The direction's system prompt and, for a request that names other schemas, what it says of
    them after it, a blank line apart (SchemaPrompts.system)."""
    base = literal(CONFIG[direction]["system"])
    return base + "\n" + literal(CONFIG[direction]["references"]) if (schemas or "").strip() else base


def swift_settings():
    """Reads each direction's max_tokens, the model and its effort out of the Swift, so the evals
    send what the app does."""
    global MODEL, EFFORT
    src = swift_source()

    def text(name):
        m = re.search(r'static let ' + name + r' = "([^"]+)"', src)
        if not m:
            raise Fatal(f"no {name} in {SWIFT}")
        return m.group(1)

    def number(name):
        m = re.search(r'static let ' + name + r' = ([0-9_.]+)', src)
        if not m:
            raise Fatal(f"no {name} in {SWIFT}")
        return float(m.group(1).replace("_", ""))

    for cfg in CONFIG.values():
        cfg["max_tokens"] = int(number(cfg["max_tokens_name"]))
    MODEL = text("model")
    EFFORT = text("effort")


def call(key, direction, user, schemas=""):
    cfg = CONFIG[direction]
    body = json.dumps({
        "model": MODEL,
        "max_tokens": cfg["max_tokens"],
        "output_config": {"effort": os.environ.get("EVAL_EFFORT") or EFFORT},
        "system": system_prompt(direction, schemas),
        "messages": [{"role": "user", "content": user}],
    }).encode("utf-8")
    headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}
    delay = 2.0
    for attempt in range(6):
        req = urllib.request.Request(API_URL, data=body, headers=headers, method="POST")
        started = time.monotonic()
        try:
            # As AnthropicModel waits: a minute, and a second for every 100 tokens it may write.
            with urllib.request.urlopen(req, timeout=60 + cfg["max_tokens"] / 100) as resp:
                data = json.load(resp)
            ms = int((time.monotonic() - started) * 1000)
            text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
            usage = data.get("usage", {})
            return {"text": text, "stop_reason": data.get("stop_reason"), "ms": ms,
                    "in": usage.get("input_tokens", 0), "out": usage.get("output_tokens", 0)}
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = json.load(e).get("error", {}).get("message", "")
            except Exception:
                pass
            if e.code in (401, 403):
                raise Fatal(f"HTTP {e.code}: {detail}")
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


# ------------------------------------------------------------------ checks

def resolve(obj, pointer):
    """JSON pointer where '/' is the root and a segment may list alternatives: /properties/a|b/items."""
    segs = [s for s in pointer.split("/") if s != ""]

    def walk(node, i):
        if i == len(segs):
            return True, node
        for alt in segs[i].split("|"):
            alt = alt.replace("~1", "/").replace("~0", "~")
            if isinstance(node, dict) and alt in node:
                ok, v = walk(node[alt], i + 1)
                if ok:
                    return True, v
            elif isinstance(node, list) and alt.isdigit() and int(alt) < len(node):
                ok, v = walk(node[int(alt)], i + 1)
                if ok:
                    return True, v
        return False, None

    return walk(obj, 0)


def names_ok(keys, spec):
    """spec 'a,b|c': every comma item present (any of its | alternatives)."""
    missing = [item for item in spec.split(",") if not any(a in keys for a in item.split("|"))]
    return missing


def any_in(text, spec):
    return any(a.lower() in text.lower() for a in spec.split("|"))


def auto_schema_checks(text, obj, inp):
    failed, warn = [], []
    if Draft202012Validator is not None:
        try:
            Draft202012Validator.check_schema(obj)
        except Exception as e:
            failed.append(f"metaschema:{str(e).splitlines()[0][:80]}")
    if obj.get("type") != "object" or not isinstance(obj.get("properties"), dict):
        failed.append("root-not-object")
    title = obj.get("title")
    if not isinstance(title, str) or not title.strip():
        failed.append("no-title")

    def walk(node):
        if isinstance(node, dict):
            props, req = node.get("properties"), node.get("required")
            if isinstance(props, dict) and isinstance(req, list):
                for r in req:
                    if r not in props:
                        failed.append(f"required-undefined:{r}")
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(obj)
    lines = text.split("\n")
    if len(lines) < 3 or not lines[1].startswith('  "') or lines[1].startswith('   '):
        failed.append("indent")
    for k in ("$schema", "additionalProperties", "$id"):
        if f'"{k}"' in text and f'"{k}"' not in (inp or ""):
            warn.append(f"added-{k}")
    return failed, warn


def refs_in(node):
    """Every "$ref" value, at any depth."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "$ref" and isinstance(v, str):
                yield v
            else:
                yield from refs_in(v)
    elif isinstance(node, list):
        for v in node:
            yield from refs_in(v)


def auto_prompt_checks(text):
    failed = []
    low = text.lower()
    if text.startswith(('"', "'", "“")) and text.endswith(('"', "'", "”")):
        failed.append("quoted")
    if "```" in text or low.startswith(("here", "updated prompt", "prompt:", "sure")):
        failed.append("preamble")
    if NO_CHANGE in text:
        failed.append("no-change-inside-text")
    return failed


def run_check(check, direction, kind, out_text, out_obj, case):
    """Returns None when the check passes, else a short reason."""
    name, _, arg = check.partition(":")
    in_schema_text = case.get("schema", "")
    try:
        in_obj = json.loads(in_schema_text) if in_schema_text else {}
    except ValueError:
        in_obj = {}
    old_prompt = (case.get("prompt") or "").strip()

    if name == "changed":
        return None if kind != "nochange" else "was NO_CHANGE"
    if name == "nochange":
        return None if kind == "nochange" else "expected NO_CHANGE"
    if name == "nochange_or_same":
        if kind == "nochange":
            return None
        if direction == "to_schema":
            return None if out_obj == in_obj else "changed the schema"
        return None if out_text.strip() == old_prompt else "changed the prompt"

    if direction == "to_schema":
        obj = out_obj if kind == "schema" else in_obj
        text = out_text if kind == "schema" else in_schema_text
        ptr, _, spec = arg.partition("=")
        if name == "title":
            t = obj.get("title")
            return None if isinstance(t, str) and 0 < len(t) <= 40 and len(t.split()) <= 5 else f"title {t!r}"
        if name == "titlesame":
            return None if obj.get("title") == in_obj.get("title") else f"title {obj.get('title')!r}"
        if name == "titlehas":
            return None if arg.lower() in str(obj.get("title", "")).lower() else f"title {obj.get('title')!r}"
        if name == "has":
            return None if resolve(obj, ptr)[0] else f"missing {ptr}"
        if name == "absent":
            return None if not resolve(obj, ptr)[0] else f"present {ptr}"
        if name in ("props", "anyprop", "propsexact", "count", "order"):
            ok, node = resolve(obj, ptr)
            keys = list(node.keys()) if ok and isinstance(node, dict) else []
            if name == "props":
                m = names_ok(keys, spec)
                return None if not m else f"missing {m} in {keys}"
            if name == "anyprop":
                return None if any(a in keys for a in spec.split("|")) else f"none of {spec} in {keys}"
            if name == "propsexact":
                return None if set(keys) == set(spec.split(",")) else f"props {keys}"
            if name == "count":
                lo, hi = (int(x) for x in spec.split(".."))
                return None if lo <= len(keys) <= hi else f"{len(keys)} props"
            if name == "order":
                idx = []
                for item in spec.split(","):
                    found = [keys.index(a) for a in item.split("|") if a in keys]
                    if not found:
                        return f"missing {item} in {keys}"
                    idx.append(found[0])
                return None if idx == sorted(idx) else f"order {keys}"
        if name in ("req", "reqexact", "reqcount", "noreq", "notreq"):
            ok, node = resolve(obj, ptr)
            req = node.get("required", []) if ok and isinstance(node, dict) else []
            if name == "req":
                m = names_ok(req, spec)
                return None if not m else f"required {req}"
            if name == "reqexact":
                return None if set(req) == set(spec.split(",")) else f"required {req}"
            if name == "reqcount":
                return None if len(req) == int(spec) else f"required {req}"
            if name == "noreq":
                return None if not req else f"required {req}"
            if name == "notreq":
                bad = [r for r in spec.split(",") if r in req]
                return None if not bad else f"required {req}"
        if name == "eq":
            ok, v = resolve(obj, ptr)
            want = json.loads(spec)
            return None if ok and v == want else f"{ptr} = {json.dumps(v) if ok else 'missing'}"
        if name == "type":
            ok, v = resolve(obj, ptr)
            t = v.get("type") if ok and isinstance(v, dict) else None
            return None if t == spec or (isinstance(t, list) and spec in t) else f"{ptr} type {t}"
        if name == "same":
            ok_in, v_in = resolve(in_obj, arg)
            ok, v = resolve(obj, arg)
            return None if ok and ok_in and v == v_in else f"{arg} changed: {json.dumps(v)[:80] if ok else 'missing'}"
        if name == "text":
            return None if any(a in text for a in arg.split("|")) else f"no {arg}"
        if name == "lacks_text":
            return None if not any_in(text, arg) else f"has {arg}"
        if name == "refs":
            word, _, n = arg.partition("=")
            count = sum(1 for ref in refs_in(obj) if ref == word)
            return None if count == int(n) else f"{count} $ref {word}"
        return f"unknown check {name}"

    # to_prompt
    new = out_text.strip() if kind == "prompt" else old_prompt
    if name == "contains":
        return None if any_in(new, arg) else f"lacks {arg!r}"
    if name == "lacks":
        return None if not any_in(new, arg) else f"has {arg!r}"
    if name == "lacks_re":
        m = re.search(arg, new, re.I)
        return None if not m else f"has {m.group(0)!r}"
    if name == "maxlen":
        return None if len(new) <= int(arg) else f"{len(new)} chars"
    if name == "growmax":
        return None if len(new) - len(old_prompt) <= int(arg) else f"grew {len(new) - len(old_prompt)}"
    if name == "startswith":
        return None if new.lower().startswith(arg.lower()) else "start changed"
    if name == "startswith_or_nochange":
        return None if kind == "nochange" or new.lower().startswith(arg.lower()) else "start changed"
    if name == "keeps":
        sm = difflib.SequenceMatcher(None, old_prompt, new, autojunk=False)
        kept = sum(b.size for b in sm.get_matching_blocks()) / max(1, len(old_prompt))
        return None if kept >= float(arg) else f"kept {kept:.2f}"
    return f"unknown check {name}"


def evaluate(case, result):
    direction = case["direction"]
    kind, value = parse(direction, result["text"], result["stop_reason"])
    failed, warn = [], []
    out_obj = None
    if direction == "to_schema" and result["text"].lstrip().startswith("```"):
        warn.append("fenced")
    if kind == "error":
        failed.append(f"parse:{value}")
    elif kind == "schema":
        out_obj = json.loads(value)
        f, w = auto_schema_checks(value, out_obj, case.get("schema"))
        failed += f
        warn += w
        # A "$ref" to an @ word is only ever to one <schemas> lists, as the app reads them back.
        listed = {line.strip() for line in (case.get("schemas") or "").split("\n") if line.strip()}
        for ref in refs_in(out_obj):
            if ref.startswith("@") and ref.split("#")[0] not in listed:
                failed.append(f"unlisted-ref:{ref}")
    elif kind == "prompt":
        failed += auto_prompt_checks(value)
    if kind != "error":
        for check in [c for c in case["checks"].split("\n") if c.strip()]:
            why = run_check(check, direction, kind, value or "", out_obj, case)
            if why:
                failed.append(f"{check.split(':')[0]}({why})")
    return kind, value, failed, warn


# ------------------------------------------------------------------ chains

def step(key, direction, **kw):
    user = user_message(direction, **kw)
    r = call(key, direction, user)
    kind, value = parse(direction, r["text"], r["stop_reason"])
    if kind == "error":
        value = f"{value} | raw: {r['text'][:400]}"
    return kind, value, r


def chain_hand_edit(key):
    """prompt -> schema; a hand edit; a prompt edit about something else -> the hand edit survives."""
    p0 = "a contact: email required, phone required, description"
    log, calls, fails = [], [], []
    k, s1, r = step(key, "to_schema", prompt=p0, schema=STARTER)
    calls.append(r)
    log.append(("s1", s1))
    if k != "schema":
        return ["step1 no schema"], log, calls
    o = json.loads(s1)
    props = o["properties"]
    phone = next((n for n in props if "phone" in n.lower()), None)
    desc = next((n for n in props if "desc" in n.lower()), None)
    if not phone or not desc:
        return [f"step1 props {list(props)}"], log, calls
    props[phone]["pattern"] = "^\\+?[0-9 ()-]{7,20}$"
    props[desc]["maxLength"] = 500
    props["linkedin"] = {"type": "string", "format": "uri"}
    s1e = fmt(o)
    p1 = p0 + ", company"
    k, s2, r = step(key, "to_schema", previous_prompt=p0, prompt=p1, schema=s1e)
    calls.append(r)
    log.append(("s2", s2))
    if k != "schema":
        return ["step2 no schema"], log, calls
    o2 = json.loads(s2)
    for n in (phone, desc, "linkedin"):
        if o2["properties"].get(n) != o["properties"][n]:
            fails.append(f"hand edit lost on {n}")
    if not any("company" in n.lower() for n in o2["properties"]):
        fails.append("no company")
    if set(o2.get("required", [])) != set(o.get("required", [])):
        fails.append(f"required {o2.get('required')}")
    return fails, log, calls


def chain_roundtrip(key):
    """schema -> prompt (from nothing) -> schema: no drift."""
    log, calls, fails = [], [], []
    s0 = fmt(ORDER)
    k, p1, r = step(key, "to_prompt", schema=s0)
    calls.append(r)
    log.append(("p1", p1))
    if k != "prompt":
        return ["step1 no prompt"], log, calls
    # a new card from that prompt
    k, s2, r = step(key, "to_schema", prompt=p1, schema=STARTER)
    calls.append(r)
    log.append(("s2", s2))
    if k != "schema":
        fails.append("step2 no schema")
    else:
        o2 = json.loads(s2)
        want = {n.lower() for n in ORDER["properties"]}
        got = {n.lower() for n in o2["properties"]}
        overlap = len(want & got) / len(want)
        if overlap < 0.66:
            fails.append(f"rebuilt props {sorted(got)}")
        if len(o2.get("required", [])) != len(ORDER["required"]):
            fails.append(f"rebuilt required {o2.get('required')}")
        cust = o2["properties"].get("customer", {})
        if isinstance(cust, dict) and cust.get("required") != ORDER["properties"]["customer"]["required"]:
            fails.append(f"rebuilt customer required {cust.get('required')}")
    # the same prompt against the schema it came from: nothing to do
    k, s3, r = step(key, "to_schema", prompt=p1, schema=s0)
    calls.append(r)
    log.append(("s3", s3))
    if k == "schema" and json.loads(s3) != ORDER:
        fails.append("drift: re-syncing the written prompt changed the schema")
    elif k == "error":
        fails.append("step3 error")
    # the app's own next step: the user edits that prompt about something else
    k, s4, r = step(key, "to_schema", previous_prompt=p1, prompt=p1 + " And a coupon code.", schema=s0)
    calls.append(r)
    log.append(("s4", s4))
    if k != "schema":
        fails.append(f"step4 {k}")
    else:
        o4 = json.loads(s4)
        added = [n for n in o4["properties"] if n not in ORDER["properties"]]
        if len(added) != 1 or "coupon" not in added[0].lower():
            fails.append(f"step4 added {added}")
        rest = dict(o4, properties={n: v for n, v in o4["properties"].items() if n in ORDER["properties"]})
        if rest != ORDER:
            fails.append("step4 drift: a prompt edit about something else changed the rest")
    return fails, log, calls


def chain_pet_both_ways(key):
    """vague prompt -> schema; hand edit (remove a field, add one with a pattern) -> prompt -> schema: no drift."""
    p0 = "a pet in my household"
    log, calls, fails = [], [], []
    k, s1, r = step(key, "to_schema", prompt=p0, schema=STARTER)
    calls.append(r)
    log.append(("s1", s1))
    if k != "schema":
        return ["step1 no schema"], log, calls
    o = json.loads(s1)
    props = o["properties"]
    removed = next((n for n in props if "color" in n.lower() or "colour" in n.lower()), list(props)[-1])
    del props[removed]
    o["required"] = [x for x in o.get("required", []) if x != removed] or None
    if o["required"] is None:
        del o["required"]
    props["microchipId"] = {"type": "string", "pattern": "^[0-9]{15}$"}
    s2 = fmt(o)
    k, p2, r = step(key, "to_prompt", prompt=p0, previous_schema=s1, schema=s2)
    calls.append(r)
    log.append(("p2", p2))
    if k != "prompt":
        return [f"step2 {k}"], log, calls
    if not p2.lower().startswith(p0) or "microchip" not in p2.lower():
        fails.append(f"prompt {p2!r}")
    k, s3, r = step(key, "to_schema", previous_prompt=p0, prompt=p2, schema=s2)
    calls.append(r)
    log.append(("s3", s3))
    if k == "schema":
        o3 = json.loads(s3)
        if removed in o3["properties"]:
            fails.append(f"re-added {removed}")
        if o3["properties"].get("microchipId", {}).get("pattern") != "^[0-9]{15}$":
            fails.append("lost microchip pattern")
        if set(o3["properties"]) - set(props):
            fails.append(f"added {sorted(set(o3['properties']) - set(props))}")
    elif k == "error":
        fails.append("step3 error")
    return fails, log, calls


def chain_contact_both_ways(key):
    """terse prompt; hand edits (add company, phone optional) -> prompt -> schema: no drift."""
    from gen_cases import CONTACT, with_props
    p0 = "email required, phone required, description"
    s1 = fmt(CONTACT)
    s2o = with_props(CONTACT, add={"company": {"type": "string"}}, required=["email"])
    s2 = fmt(s2o)
    log, calls, fails = [], [], []
    k, p1, r = step(key, "to_prompt", prompt=p0, previous_schema=s1, schema=s2)
    calls.append(r)
    log.append(("p1", p1))
    if k != "prompt":
        return [f"step1 {k}"], log, calls
    if "company" not in p1.lower() or "phone required" in p1.lower() or len(p1) > len(p0) + 25:
        fails.append(f"prompt {p1!r}")
    k, s3, r = step(key, "to_schema", previous_prompt=p0, prompt=p1, schema=s2)
    calls.append(r)
    log.append(("s3", s3))
    if k == "schema" and json.loads(s3) != s2o:
        fails.append("drift")
    elif k == "error":
        fails.append("step2 error")
    return fails, log, calls


CHAINS = [chain_hand_edit, chain_roundtrip, chain_pet_both_ways, chain_contact_both_ways]


# ------------------------------------------------------------------ main

def one_line(s, n=160):
    s = (s or "").replace("\n", " ")
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int)
    ap.add_argument("--check", action="store_true", help="read the prompts and settings out of the Swift, and stop")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--only", default="")
    ap.add_argument("--no-chains", action="store_true")
    ap.add_argument("--chains-only", action="store_true")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args()

    swift_settings()
    print(f"model {MODEL}, effort {EFFORT}; a new type's schema {STARTER!r}")
    for d in CONFIG:
        text = system_prompt(d)
        print(f"{d}: {CONFIG[d]['system']}, {len(text)} characters, {len(text.splitlines())} lines, "
              f"and {CONFIG[d]['references']}, {len(literal(CONFIG[d]['references']))} characters, for other schemas; "
              f"max_tokens {CONFIG[d]['max_tokens']}")
    if Draft202012Validator is None:
        print("metaschema check skipped: no jsonschema in _pylib (see README.md)")
    if args.check:
        return
    if args.round is None:
        ap.error("--round is required")

    key = load_key()
    if not key:
        print("no key: add one in Settings, or set ANTHROPIC_API_KEY")
        sys.exit(2)

    with open(os.path.join(HERE, "cases.csv"), newline="", encoding="utf-8") as f:
        cases = list(csv.DictReader(f))
    only = {x for x in args.only.split(",") if x}
    if only:
        cases = [c for c in cases if c["id"] in only]
    if args.chains_only:
        cases = []

    jobs = [(c, run) for c in cases for run in range(1, args.runs + 1)]
    rows, records = [], []

    def work(job):
        c, run = job
        user = user_message(c["direction"], prompt=c["prompt"], schema=c["schema"],
                            previous_prompt=c["previous_prompt"], previous_schema=c["previous_schema"], schemas=c.get("schemas", ""))
        r = call(key, c["direction"], user, c.get("schemas", ""))
        kind, value, failed, warn = evaluate(c, r)
        return c, run, r, kind, value, failed, warn

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        for c, run, r, kind, value, failed, warn in ex.map(work, jobs):
            ok = not failed
            rows.append({
                "round": args.round, "id": c["id"], "direction": c["direction"], "core": c["core"], "run": run,
                "pass": int(ok), "failed": "; ".join(failed + [f"warn:{w}" for w in warn]),
                "latency_ms": r["ms"], "input_tokens": r["in"], "output_tokens": r["out"],
                "output": one_line(r["text"]),
            })
            records.append({"round": args.round, "id": c["id"], "direction": c["direction"], "run": run,
                            "pass": ok, "failed": failed, "warn": warn, "kind": kind, "output": r["text"],
                            "stop_reason": r["stop_reason"], "latency_ms": r["ms"],
                            "input_tokens": r["in"], "output_tokens": r["out"]})
            mark = "PASS" if ok else "FAIL"
            print(f"{mark} {c['id']:<30} {r['ms']:>6} ms {r['out']:>5} tok  {'; '.join(failed)[:150]}")

    if not args.no_chains and not only:
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(CHAINS)) as ex:
            futures = {ex.submit(ch, key): ch.__name__ for ch in CHAINS}
            for fut in concurrent.futures.as_completed(futures):
                name = futures[fut]
                fails, log, calls = fut.result()
                ok = not fails
                ms = sum(x["ms"] for x in calls)
                rows.append({
                    "round": args.round, "id": name, "direction": "chain", "core": 1, "run": 1, "pass": int(ok),
                    "failed": "; ".join(fails), "latency_ms": ms,
                    "input_tokens": sum(x["in"] for x in calls), "output_tokens": sum(x["out"] for x in calls),
                    "output": one_line(" | ".join(f"{k}: {v}" for k, v in log if k.startswith("p"))),
                })
                records.append({"round": args.round, "id": name, "direction": "chain", "pass": ok, "failed": fails,
                                "steps": log, "latencies_ms": [x["ms"] for x in calls]})
                print(f"{'PASS' if ok else 'FAIL'} {name:<30} {ms:>6} ms  {'; '.join(fails)[:150]}")

    path = os.path.join(HERE, "results.csv")
    new_file = not os.path.exists(path)
    with open(path, "a", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        if new_file:
            w.writeheader()
        w.writerows(sorted(rows, key=lambda r: (r["direction"], r["id"], r["run"])))
    with open(os.path.join(HERE, "results.jsonl"), "a", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print()
    for d in ("to_schema", "to_prompt", "chain"):
        rs = [r for r in rows if r["direction"] == d]
        if not rs:
            continue
        core = [r for r in rs if str(r["core"]) == "1"]
        lat = sorted(r["latency_ms"] for r in rs)
        line = (f"{d:<10} {sum(r['pass'] for r in rs)}/{len(rs)} pass "
                f"(core {sum(r['pass'] for r in core)}/{len(core)})")
        if d != "chain":
            p90 = lat[min(len(lat) - 1, int(len(lat) * 0.9))]
            line += (f"  latency p50 {int(statistics.median(lat))} ms, p90 {p90} ms, max {lat[-1]} ms; "
                     f"out tokens mean {int(statistics.mean(r['output_tokens'] for r in rs))}")
        print(line)


if __name__ == "__main__":
    try:
        main()
    except Fatal as e:
        print(f"stopped: {e}")
        sys.exit(1)
