#!/usr/bin/env python3
"""Quick and dirty evals for a type's two prompts, as the app ships them: the system prompts
are read out of Sources/Types/Sync/SchemaPrompts.swift, so there's one copy.

    python3 evals.py --check                # read the prompts and settings out of the Swift, and self-test the checks; no call
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "_pylib"))
try:
    from jsonschema import Draft202012Validator
except ImportError:  # meta-validation is skipped without it, and says so
    Draft202012Validator = None

sys.path.insert(0, HERE)
from gen_cases import fmt, STARTER, ORDER  # noqa: E402
from evalkit import Fatal, block, call as kit_call, is_wrapper, literal as kit_literal, load_key, read_swift, unwrap  # noqa: E402,F401

# ------------------------------------------------------------------ the contract, read out of the Swift

SOURCES = os.path.normpath(os.path.join(HERE, "..", "..", "Sources"))
SWIFT = os.path.join(SOURCES, "Types", "Sync", "SchemaPrompts.swift")
# Each direction's system prompt and max_tokens (the Swift constants they're read from):
# `swift_settings` fills in the values, and MODEL and EFFORT, from the Swift.
CONFIG = {
    "to_schema": {"system": "toSchemaSystem", "titles": ["toSchemaTitle", "toSchemaNewTitle"], "references": "toSchemaReferences",
                  "relationship": "toSchemaRelationshipType", "max_tokens_name": "toSchemaMaxTokens"},
    "to_prompt": {"system": "toPromptSystem", "titles": ["toPromptTitle"], "references": "toPromptReferences",
                  "max_tokens_name": "toPromptMaxTokens"},
}
MODEL = None
EFFORT = None
NO_CHANGE = "NO_CHANGE"
# The tags a prompt is answered in (SchemaPrompts.answerTag): `swift_settings` reads it.
ANSWER_TAG = None
# The schema TypeSync says words that are JSON were over before they became the schema (`adopt`, `changed`):
# the previous_schema of the request that then writes the words from nothing. `swift_settings` reads it.
JSON_WORDS_OVER = None
# A prompt answer that reads as something other than the prompt (SchemaPrompts.isNotAPrompt).
PREAMBLES = ("here's ", "here’s ", "here is ", "here are ", "updated prompt", "updated description",
             "the updated prompt", "the updated description", "prompt:", "description:",
             "sure,", "sure!", "sure.", "certainly,", "certainly!", "certainly.")


def user_message(direction, prompt="", schema="", previous_prompt="", previous_schema="", schemas=""):
    if direction == "to_schema":
        parts = [block("schemas", schemas), block("previous_prompt", previous_prompt), block("prompt", prompt), block("schema", schema)]
    else:
        parts = [block("schemas", schemas), block("prompt", prompt), block("previous_schema", previous_schema), block("schema", schema)]
    return "\n\n".join(p for p in parts if p)


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


def tagged(text):
    """What's inside a prompt answer's tags and what's around them (SchemaPrompts.tagged): the last <answer>
    that a </answer> follows, up to the last </answer>; with none closed, what follows the last <answer>;
    None for an answer with no opening tag. Returns (inside, outside)."""
    open_, close = f"<{ANSWER_TAG}>", f"</{ANSWER_TAG}>"
    end = text.rfind(close)
    start = text.rfind(open_, 0, end) if end >= 0 else -1
    if start >= 0:
        return text[start + len(open_):end], text[:start] + "\n" + text[end + len(close):]
    start = text.rfind(open_)
    if start < 0:
        return None
    return text[start + len(open_):], text[:start]


def parse(direction, text, stop_reason, words=""):
    """The parse rule, as the Swift side does it (`words` is the prompt as it was: an answer that reads like a
    preamble is a prompt when the prompt it replaces read so itself). A prompt is what's inside the answer's
    tags, whatever is said around them; NO_CHANGE is judged outside them (the whole answer when it has none),
    and inside; an answer with no tags is read whole. Returns (kind, value): ("nochange", None),
    ("schema", text), ("prompt", text) or ("error", why)."""
    if stop_reason != "end_turn":
        return "error", f"stop_reason={stop_reason}"
    if direction == "to_prompt":
        pair = tagged(text)
        if pair and says_no_change(unwrap(pair[1].strip(), "prompt")):
            return "nochange", None
        t = unwrap((pair[0] if pair else text).strip(), "prompt")
    else:
        t = unwrap(text.strip(), "schema")
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
    if is_not_a_prompt(t) and not is_not_a_prompt(words):
        return "error", "not a prompt"
    return "prompt", t



# ------------------------------------------------------------------ the type's name, as TypeSync puts it in and takes it out
# (Sources/Types/Type/TypeSchema.swift `TypeNaming`, used by TypeSync.start and .apply): a type's schema is
# stored with no root "title"; its note's title goes in as the first member for the request (unless the
# person typed one in the JSON), and the model's comes out of what it writes, naming an untitled note.

def _members(text):
    """The root object's members as (key, key_start, value_start, value_end), or None."""
    dec = json.JSONDecoder()
    if not text.startswith("{"):
        return None
    i, out = 1, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text) or text[i] == "}":
            return out
        key, end = dec.raw_decode(text, i)
        j = end
        while text[j].isspace() or text[j] == ":":
            j += 1
        _, vend = dec.raw_decode(text, j)
        out.append((key, i, j, vend))
        i = vend
        while text[i].isspace():
            i += 1
        if text[i] == ",":
            i += 1


def naming_title(text):
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    t = obj.get("title") if isinstance(obj, dict) else None
    return t if isinstance(t, str) else None


def titled(text, name):
    """TypeNaming.titled: `name` first, as the root "title", laid out as the first member is."""
    try:
        obj = json.loads(text)
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None
    if "title" in obj or not name.strip():
        return text
    lit = json.dumps(name, ensure_ascii=False)
    members = _members(text)
    if not members:
        return "{ \"title\": " + lit + " }"
    i = members[0][1]
    space = text[1:i]
    member = f'"title":{lit},' if not space else f'"title": {lit},{space}'
    return text[:i] + member + text[i:]


def untitled(text):
    """TypeNaming.untitled: (text without its root "title", what it said or None), or None for none."""
    members = _members(text)
    if members is None:
        return None
    idx = [k for k, m in enumerate(members) if m[0] == "title"]
    if not idx:
        return None
    i = idx[-1]
    key, kstart, vstart, vend = members[i]
    title = json.loads(text[vstart:vend])
    title = title if isinstance(title, str) and title.strip() else None
    if i + 1 < len(members):
        return text[:kstart] + text[members[i + 1][1]:], title
    if i > 0:
        return text[:members[i - 1][3]] + text[vend:], title
    return text[:1] + text[len(text) - 1:], title


def prepare(case):
    """The case as TypeSync sends it: the note's name as each schema's root title, unless the schema
    has one. `named` is whether the answer's title comes out (the schema as stored has none)."""
    c = dict(case)
    name = c.get("name") or ""
    c["named"] = naming_title(c["schema"]) is None
    for k in ("schema", "previous_schema"):
        if c[k] and name:
            c[k] = titled(c[k], name) or c[k]
    return c


# ------------------------------------------------------------------ calling

SYSTEMS = {}


def swift_source():
    return read_swift(SWIFT)


def literal(name):
    """A prompt's raw string literal out of SchemaPrompts.swift, read once (evalkit.literal)."""
    if name not in SYSTEMS:
        SYSTEMS[name] = kit_literal(swift_source(), name, SWIFT)
    return SYSTEMS[name]


def system_prompt(direction, schemas="", relationship=False):
    """The direction's system prompt, what it says of titles after it on every request, for the words of a
    relationship type (to-schema only) what it says of such a type, and, for a request that names other schemas,
    what it says of them after that, each a blank line apart (SchemaPrompts.system(_:schemas:relationship:))."""
    cfg = CONFIG[direction]
    text = literal(cfg["system"]) + "".join("\n" + literal(name) for name in cfg["titles"])
    if relationship and cfg.get("relationship"):
        text += "\n" + literal(cfg["relationship"])
    return text + "\n" + literal(cfg["references"]) if (schemas or "").strip() else text


def swift_settings():
    """Reads each direction's max_tokens, the model, its effort and the tags a prompt is answered in
    out of the Swift, so the evals send what the app does and read what it reads."""
    global MODEL, EFFORT, ANSWER_TAG, JSON_WORDS_OVER
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
    ANSWER_TAG = text("answerTag")
    asked = f"<{ANSWER_TAG}> and </{ANSWER_TAG}>"
    if asked not in literal(CONFIG["to_prompt"]["system"]) or f"<{ANSWER_TAG}>" in literal(CONFIG["to_schema"]["system"]):
        raise Fatal(f"toPromptSystem, and it alone, should ask for {asked}")
    sync = os.path.join(os.path.dirname(SWIFT), "TypeSync.swift")
    with open(sync, encoding="utf-8") as f:
        over = set(re.findall(r'TypeSyncSides\(words: [\w.]+, schema: "([^"]*)"\)', f.read()))
    if len(over) != 1:
        raise Fatal(f"no one schema that JSON words are said to have been over in {sync}: {sorted(over)}")
    JSON_WORDS_OVER = over.pop()


def call(key, direction, user, schemas="", relationship=False):
    cfg = CONFIG[direction]
    return kit_call(key, MODEL, cfg["max_tokens"], system_prompt(direction, schemas, relationship), user,
                    effort=os.environ.get("EVAL_EFFORT") or EFFORT)


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
    if is_pointer_like(obj):
        failed.append("pointer-like")
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


def auto_prompt_checks(text, words=""):
    failed = []
    low = text.lower()
    if text.startswith(('"', "'", "“")) and text.endswith(('"', "'", "”")):
        failed.append("quoted")
    if ("```" in text or low.startswith(("here", "updated prompt", "prompt:", "sure"))) and not is_not_a_prompt(words):
        failed.append("preamble")
    if NO_CHANGE in text and not is_not_a_prompt(words):
        failed.append("no-change-inside-text")
    return failed


# The media type of the pointer the app no longer has: an answer that holds it, or a "contentSchema" with a "$ref", is
# `pointer-like`, and fails every to-schema case (the prompts say no word of a link to a note).
POINTER_MEDIA_TYPE = "text/x-canvas-link"


def schemas_in(node, inside_content=False):
    """Every dict of the answer, at any depth, and whether it is a "contentSchema" (a pointer's, not a property's)."""
    if isinstance(node, dict):
        yield node, inside_content
        for k, v in node.items():
            yield from schemas_in(v, k == "contentSchema")
    elif isinstance(node, list):
        for v in node:
            yield from schemas_in(v, False)


def is_pointer_like(obj):
    """Whether an answer holds a pointer to a note: the old link media type anywhere, or a "contentSchema" that is, or has, a "$ref"."""
    for node, _ in schemas_in(obj):
        if node.get("contentMediaType") == POINTER_MEDIA_TYPE:
            return True
        content = node.get("contentSchema")
        if isinstance(content, dict) and any(True for _ in refs_in(content)):
            return True
    return False


def plain_refs_to(obj, word):
    """The schemas that are exactly `{"$ref": word}`, a contentSchema not among them."""
    for node, inside_content in schemas_in(obj):
        if node == {"$ref": word} and not inside_content:
            yield node


def conditions(obj):
    """Every dict that has an "if", at any depth."""
    return [node for node, _ in schemas_in(obj) if "if" in node]


def differs_only_at(answer, original, pointers):
    """Whether `answer` is `original` (as parsed, the root "title" aside) except at and under `pointers`, which may differ, appear or go."""
    def without(root, pointer):
        segs = [x.replace("~1", "/").replace("~0", "~") for x in pointer.split("/") if x != ""]
        node = root
        for seg in segs[:-1]:
            if isinstance(node, dict) and seg in node:
                node = node[seg]
            elif isinstance(node, list) and seg.isdigit() and int(seg) < len(node):
                node = node[int(seg)]
            else:
                return
        if not segs:
            return
        last = segs[-1]
        if isinstance(node, dict):
            node.pop(last, None)
        elif isinstance(node, list) and last.isdigit() and int(last) < len(node):
            node[int(last)] = None

    a, b = json.loads(json.dumps(answer)), json.loads(json.dumps(original))
    for root in (a, b):
        if isinstance(root, dict):
            root.pop("title", None)
        for pointer in pointers:
            without(root, pointer)
    return a == b


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
            return None if any_in(str(obj.get("title", "")), arg) else f"title {obj.get('title')!r}"
        if name == "has":
            return None if resolve(obj, ptr)[0] else f"missing {ptr}"
        if name == "absent":
            return None if not resolve(obj, ptr)[0] else f"present {ptr}"
        if name in ("props", "anyprop", "noprop", "propsexact", "count", "order"):
            ok, node = resolve(obj, ptr)
            keys = list(node.keys()) if ok and isinstance(node, dict) else []
            if [s for s in ptr.split("/") if s][-1:] == ["properties"]:
                # A `$`-key under `properties` is a setting (`$title`), never a field (SchemaDocument.fields).
                keys = [k for k in keys if not k.startswith("$")]
            if name == "props":
                m = names_ok(keys, spec)
                return None if not m else f"missing {m} in {keys}"
            if name == "anyprop":
                return None if any(a in keys for a in spec.split("|")) else f"none of {spec} in {keys}"
            if name == "noprop":
                found = [k for k in keys if k in spec.split("|")]
                return None if not found else f"{found} in {keys}"
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
        if name == "titleis":
            # A member's "title" is one of the alternatives (case-insensitive, trimmed); an empty one accepts no title at all.
            ok, v = resolve(obj, ptr)
            if not ok or not isinstance(v, dict):
                return f"missing {ptr}"
            t = v.get("title", "")
            got = t.strip().lower() if isinstance(t, str) else None
            return None if got in {a.strip().lower() for a in spec.split("|")} else f"{ptr} title {v.get('title')!r}"
        if name == "plainref":
            word, _, n = arg.partition("=")
            count = sum(1 for _ in plain_refs_to(obj, word))
            return None if count == int(n) else f"{count} bare $ref {word}"
        if name == "titlefrom":
            got = (obj.get("properties") or {}).get("$title") if isinstance(obj.get("properties"), dict) else None
            return None if got == {"x-canvas-from": arg} else f"$title {json.dumps(got)}"
        if name == "notitle":
            props = obj.get("properties")
            return None if not (isinstance(props, dict) and "$title" in props) else f"$title {json.dumps(props['$title'])}"
        if name == "lastkey":
            ok, v = resolve(obj, ptr)
            last = list(v.keys())[-1] if ok and isinstance(v, dict) and v else None
            return None if last == spec else f"last key {last!r} in {ptr}"
        if name == "onlydiff":
            return None if differs_only_at(obj, in_obj, arg.split(",")) else f"differs beyond {arg}"
        if name == "condtests":
            bad = [c for c in conditions(obj) if not (isinstance(c.get("if"), dict) and isinstance(c["if"].get("properties"), dict) and c["if"]["properties"])]
            return None if not bad else f"an if with no properties: {json.dumps(bad[0].get('if'))[:80]}"
        if name == "condthen":
            key, _, spec = arg.partition("=")
            for c in conditions(obj):
                tested = c["if"].get("properties") if isinstance(c.get("if"), dict) else None
                then = c.get("then")
                if isinstance(tested, dict) and key in tested and isinstance(then, dict) \
                        and any(a in (then.get("required") or []) for a in spec.split("|")):
                    return None
            return f"no if on {key} whose then requires {spec}"
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


def known_check(direction, name):
    """Whether run_check has a check of this name for the direction (a check that raises on an empty argument is known)."""
    kind = "schema" if direction == "to_schema" else "prompt"
    try:
        why = run_check(name + ":", direction, kind, "{}" if kind == "schema" else "", {} if kind == "schema" else None,
                        {"schema": "{}", "prompt": ""})
    except Exception:
        return True
    return not (isinstance(why, str) and why.startswith("unknown check"))


def check_cases_file():
    """Every check named in cases.csv is one run_check knows, so a mistyped one is found here and not when a case runs.
    A case that says it is a relationship type's is a to-schema case, and the Swift has the literal it is sent."""
    unknown = []
    flagged = []
    with open(os.path.join(HERE, "cases.csv"), newline="", encoding="utf-8") as f:
        for c in csv.DictReader(f):
            for check in [x for x in c["checks"].split("\n") if x.strip()]:
                if not known_check(c["direction"], check.partition(":")[0]):
                    unknown.append(f"{c['id']}: {check}")
            if c.get("relationship"):
                flagged.append(c["id"])
                if c["direction"] != "to_schema":
                    unknown.append(f"{c['id']}: a relationship type's words are only sent to-schema")
    if unknown:
        raise Fatal("cases.csv names checks run_check doesn't have: " + "; ".join(unknown))
    # The literal is sent for the cases that say so and for none other: `s_reltype_*` all say so.
    missing = [i for i in ("s_reltype_ends", "s_reltype_vague", "s_reltype_vague_friend") if i not in flagged]
    if missing:
        raise Fatal("these cases are a relationship type's words and don't say so: " + ", ".join(missing))
    relationship = literal(CONFIG["to_schema"]["relationship"])
    if system_prompt("to_schema", relationship=True) != system_prompt("to_schema") + "\n" + relationship \
            or system_prompt("to_prompt", relationship=True) != system_prompt("to_prompt") \
            or system_prompt("to_schema", "@A", True) != system_prompt("to_schema") + "\n" + relationship + "\n" + literal(CONFIG["to_schema"]["references"]):
        raise Fatal("the relationship type's literal is not sent as SchemaPrompts.system(_:schemas:relationship:) sends it")
    print(f"{len(flagged)} cases are a relationship type's: {', '.join(flagged)}; {CONFIG['to_schema']['relationship']}, {len(relationship)} characters, after the titles and before the references")


def selftest():
    """Each check added for the types cut, shown able to fail before a model is asked: for each, answers it passes and answers it
    fails, hand-written. Nothing is called."""
    pointer = {"type": "string", "contentMediaType": POINTER_MEDIA_TYPE, "contentSchema": {"$ref": "@Customer"}}
    contact = {"type": "object", "properties": {
        "email": {"type": "string"}, "phone": {"type": "string", "pattern": "^x$"}, "description": {"type": "string"}}, "required": ["email", "phone"]}

    def props(**members):
        return {"type": "object", "properties": members}

    def with_phone(**extra):
        o = json.loads(json.dumps(contact))
        o["properties"]["phone"].update(extra)
        return o

    pet = props(name={"type": "string"}, age={"type": "integer"})
    pet_title = props(name={"type": "string"}, age={"type": "integer"}, **{"$title": {"x-canvas-from": "name"}})
    when = {"if": {"properties": {"gift": {"const": True}}}, "then": {"required": ["giftNote"]}}
    rows = [
        # (check, the input the case holds, answers it passes, answers it fails)
        ("titleis:/properties/phone=mobile number", contact, [with_phone(title="Mobile Number ")], [contact, with_phone(title="cell")]),
        ("titleis:/properties/phone=cell|mobile|", contact, [with_phone(title="cell"), contact], [with_phone(title="work")]),
        ("titleis:/properties/phone=", contact, [contact], [with_phone(title="phone")]),
        ("noprop:/properties=layer|layers", {}, [pet, props(purpose={"type": "string"})], [props(layer={"type": "string"}), props(purpose={}, layers={})]),
        ("noprop:/properties=layer", {}, [props(**{"$title": {"x-canvas-from": "name"}, "name": {}})], [props(name={}, layer={})]),
        ("plainref:@Customer=1", {}, [props(customer={"$ref": "@Customer"})], [props(customer=pointer), props(a={"$ref": "@Customer"}, b={"$ref": "@Customer"})]),
        ("titlefrom:name", {}, [pet_title], [pet, props(name={"type": "string"}, **{"$title": {"x-canvas-from": "age"}})]),
        ("notitle", {}, [pet], [pet_title]),
        ("lastkey:/properties=$title", {}, [pet_title], [props(**{"$title": {"x-canvas-from": "name"}, "name": {"type": "string"}}), pet]),
        ("onlydiff:/properties/phone/title", contact, [with_phone(title="mobile"), contact],
         [with_phone(title="mobile", pattern="^y$"), dict(contact, required=["email"]),
          with_phone(title="mobile", maxLength=5)]),
        ("onlydiff:/properties/phone/title,/properties/phone/pattern", contact, [with_phone(title="mobile", pattern="^y$")],
         [dict(contact, required=["email"])]),
        ("condtests", {}, [dict(props(gift={"type": "boolean"}), allOf=[when]), props(a={"type": "string"})],
         [dict(props(gift={"type": "boolean"}), allOf=[{"if": {"required": ["gift"]}, "then": {"required": ["giftNote"]}}]),
          dict(props(gift={"type": "boolean"}), allOf=[{"if": {"properties": {}}, "then": {}}])]),
        ("condthen:gift=giftNote|giftMessage", {}, [dict(props(gift={"type": "boolean"}), allOf=[when])],
         [dict(props(gift={"type": "boolean"}), allOf=[{"if": {"properties": {"gift": {"const": True}}}, "then": {"required": ["other"]}}]),
          dict(props(gift={"type": "boolean"}), allOf=[{"if": {"properties": {"method": {"const": "x"}}}, "then": {"required": ["giftNote"]}}]),
          props(gift={"type": "boolean"})]),
        # the listing checks leave a `$`-key out, as SchemaDocument.fields does; `same:` does not
        ("propsexact:/properties=name,age", {}, [pet, pet_title], [props(name={"type": "string"}, age={}, extra={})]),
        ("count:/properties=2..2", {}, [pet_title], [props(name={}, age={}, extra={})]),
        ("order:/properties=name,age", {}, [pet_title], [props(age={}, name={})]),
        ("anyprop:/properties=name", {}, [pet_title], [props(**{"$title": {}})]),
        ("same:/properties", pet, [pet], [pet_title]),
    ]
    failures = []
    # The global check: an answer that holds a pointer to a note, in any form, fails every case; a bare `$ref` and a plain text field pass.
    pointer_like = [props(customer=pointer), props(customers={"type": "array", "items": pointer}),
                    props(customer={"type": "string", "contentMediaType": POINTER_MEDIA_TYPE}),
                    props(customer={"type": "string", "contentSchema": {"$ref": "@Customer"}})]
    for answer in pointer_like:
        failed, _ = auto_schema_checks(json.dumps(answer), answer, "")
        if "pointer-like" not in failed:
            failures.append(f"pointer-like should fail {json.dumps(answer)[:100]}")
    for answer in [props(customer={"$ref": "@Customer"}), props(customer={"type": "string"}), props(note={"type": "string", "contentMediaType": "text/plain"})]:
        failed, _ = auto_schema_checks(json.dumps(answer), answer, "")
        if "pointer-like" in failed:
            failures.append(f"pointer-like should pass {json.dumps(answer)[:100]}")
    for check, original, passes, fails in rows:
        case = {"schema": json.dumps(original), "prompt": ""}
        for answer in passes:
            why = run_check(check, "to_schema", "schema", json.dumps(answer), answer, case)
            if why is not None:
                failures.append(f"{check} should pass {json.dumps(answer)[:100]}: {why}")
        for answer in fails:
            if run_check(check, "to_schema", "schema", json.dumps(answer), answer, case) is None:
                failures.append(f"{check} should fail {json.dumps(answer)[:100]}")
    # A prompt is read as the app reads it (`parse`): what's inside the answer's tags, whatever is said around
    # them, so a remark before a tagged prompt costs `maxlen` and `lacks` nothing, and the same answer without
    # the tags still fails them. (answer, the prompt it replaces, the kind read, the prompt read)
    remark = ("There is no <prompt>, so I write one. Fields: number (string), customer (@Customer), total (number). "
              "None are listed as required...")
    order = "An order: number, customer (a @Customer), total"
    a = f"<{ANSWER_TAG}>"
    z = f"</{ANSWER_TAG}>"
    reads = [
        (f"{remark}\n\n{a}\n{order}\n{z}", "", "prompt", order),
        (f"{remark}\n\n{a}{order}{z}", "", "prompt", order),
        (f"{remark}\n\n{order}", "", "prompt", f"{remark}\n\n{order}"),
        (f"{a}\n{order}\n{z}\n\nI kept it to one line.", "", "prompt", order),
        (f"{a}a pet{z}\nOr, shorter:\n{a}pet{z}", "", "prompt", "pet"),
        (f"I put it in {a} tags.\n{a}a pet{z}", "", "prompt", "a pet"),
        (f"{a}a pet{z}\nThen, cut off: {a}a p", "", "prompt", "a pet"),
        (f"{remark}\n\n{a}\n{order}", "", "prompt", order),
        (f"{a}a {a}pet", "", "prompt", "pet"),
        (f"{order}\n{z}", "", "prompt", order),
        ("NO_CHANGE", "", "nochange", None),
        (f"{a}NO_CHANGE{z}", "", "nochange", None),
        (f"The prompt still says it.\n\n{a}NO_CHANGE.{z}", "", "nochange", None),
        (f"NO_CHANGE: the prompt never named the title.\n{a}a pet{z}", "", "nochange", None),
        (f"{a}a pet{z}\n\nNO_CHANGE", "", "nochange", None),
        (f"A $title alone would be NO_CHANGE, but there is no <prompt>, so I write one.\n\n{a}A pet: name{z}", "", "prompt", "A pet: name"),
        ("A $title alone would be NO_CHANGE, but there is no <prompt>, so I write one.\n\nA pet: name", "", "error", "not a prompt"),
        (f"{a}{z}", "", "error", "empty"),
        (f"{a}\n \n{z}", "", "error", "empty"),
        (f"{order}\n{a}{z}", "", "error", "empty"),
        (f"{remark}\n{a}", "", "error", "empty"),
        (f"```\n{a}\na pet\n{z}\n```", "", "prompt", "a pet"),
        (f"{a}\n```\na pet\n```\n{z}", "", "prompt", "a pet"),
        (f"{a}<prompt>a pet</prompt>{z}", "", "prompt", "a pet"),
        (f'{a}"a pet, with its weight"{z}', "", "prompt", "a pet, with its weight"),
        (f"{a}Here's the updated prompt: a pet{z}", "", "error", "not a prompt"),
        (f"{a}Here are the fields: name, email, role, phone.{z}", "Here are the fields: name, email, role.", "prompt",
         "Here are the fields: name, email, role, phone."),
        ("<prompt>\nemail required, phone\n</prompt>", "", "prompt", "email required, phone"),
        ("a pet in my household\n\nNO_CHANGE", "", "nochange", None),
    ]
    for answer, words, kind, value in reads:
        got = parse("to_prompt", answer, "end_turn", words)
        if got != (kind, value):
            failures.append(f"parse should read {answer[:80]!r} as {(kind, value)!r}, not {got!r}")
    if parse("to_prompt", reads[0][0], "max_tokens")[0] != "error":
        failures.append("a tagged prompt cut off should be an error")
    if parse("to_schema", f"Sure.\n{a}{{}}{z}", "end_turn")[0] != "error" or parse("to_schema", f"{a}\n{{}}\n{z}", "end_turn") != ("schema", "{}"):
        failures.append("a schema is read as it was: no tags but a wrapper's lines")
    # (check, the answer with its tags: passes; the same without them: fails), as `evaluate` runs a case's checks.
    scored = [("maxlen:120", "A contact: email (required), phone (required), description.",
               "There is no <prompt>, so I write one. Fields: email (string, required), phone (string, required), description (string)."),
              ("lacks:schema|json|string", "A contact: email (required), phone (required), description.",
               "There is no <prompt>, so I write one. Fields: email (string, required), phone (string, required), description (string)."),
              ("maxlen:200", order, remark + " The customer is a $ref to @Customer, the type itself."),
              ("lacks_re:link|point|refer", order, "The customer is a bare $ref, not a link, so I name the type by its word.")]
    for check, words, said in scored:
        for answer, passes in ((f"{said}\n\n{a}\n{words}\n{z}", True), (f"{said}\n\n{words}", False)):
            kind, value, failed, warn = evaluate({"direction": "to_prompt", "prompt": "", "checks": check}, {"text": answer, "stop_reason": "end_turn"})
            if (not failed) != passes or kind != "prompt":
                failures.append(f"{check} should {'pass' if passes else 'fail'} {answer[:80]!r}: {kind}, {failed}")
            if ("untagged" in warn) == passes or ("remark" in warn) != passes:
                failures.append(f"{answer[:80]!r} should warn {'remark' if passes else 'untagged'}, not {warn}")
    tested = {row[0].partition(":")[0] for row in rows}
    for name in ("titleis", "noprop", "plainref", "titlefrom", "notitle", "lastkey", "onlydiff", "condtests", "condthen"):
        if name not in tested:
            failures.append(f"{name} has no self-test")
        if not known_check("to_schema", name):
            failures.append(f"{name} is not a check")
    if failures:
        raise Fatal("the checks' self-test failed:\n  " + "\n  ".join(failures))
    return len(rows), len(reads) + 3, len(scored)


def evaluate(case, result):
    direction = case["direction"]
    kind, value = parse(direction, result["text"], result["stop_reason"], case.get("prompt", "") if direction == "to_prompt" else "")
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
        # As TypeSync.apply reads it: the title comes out of what's written when it went in as the
        # note's name (or the note had none); an untitled note is named by it.
        if case.get("named", True):
            got = untitled(value)
            if got is None:
                warn.append("no-title-to-take-out")
            else:
                stored_text, title = got
                try:
                    stored_obj = json.loads(stored_text)
                except ValueError as e:
                    failed.append(f"stripped-invalid:{e}")
                else:
                    if not isinstance(stored_obj, dict) or "title" in stored_obj:
                        failed.append("stripped-not-an-object-or-still-titled")
                    if not case.get("name") and not title:
                        failed.append("untitled-note-got-no-name")
                    if case.get("name") and title != case["name"]:
                        warn.append(f"title-changed:{title!r}")
        # A "$ref" to an @ word is only ever to one <schemas> lists, as the app reads them back.
        listed = {line.strip() for line in (case.get("schemas") or "").split("\n") if line.strip()}
        for ref in refs_in(out_obj):
            if ref.startswith("@") and ref.split("#")[0] not in listed:
                failed.append(f"unlisted-ref:{ref}")
    elif kind == "prompt":
        failed += auto_prompt_checks(value, case.get("prompt", ""))
        # How the model used the tags it is asked for (warnings: the app reads either): none at all, or
        # something said around them, which the tags kept out of the prompt.
        pair = tagged(result["text"])
        if pair is None:
            warn.append("untagged")
        elif unwrap(pair[1].strip(), "prompt"):
            warn.append("remark")
    if kind != "error":
        for check in [c for c in case["checks"].split("\n") if c.strip()]:
            why = run_check(check, direction, kind, value or "", out_obj, case)
            if why:
                failed.append(f"{check.split(':')[0]}({why})")
    return kind, value, failed, warn


# ------------------------------------------------------------------ chains

def step(key, direction, **kw):
    user = user_message(direction, **kw)
    r = call(key, direction, user, kw.get("schemas", ""))
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
    """schema -> prompt (from nothing) -> schema: no drift. And a schema sent alone gets words too."""
    from gen_cases import PET
    log, calls, fails = [], [], []
    s0 = fmt(ORDER)
    # Words that are JSON made a type: TypeSync says the pair was those words over an empty schema, and sends
    # that as previous_schema.
    k, p1, r = step(key, "to_prompt", previous_schema=JSON_WORDS_OVER, schema=s0)
    calls.append(r)
    log.append(("p1", p1))
    if k != "prompt":
        return ["step1 no prompt"], log, calls
    # The schema alone, no <prompt> and no <previous_schema>: what the app sends for a type it first saw with
    # no words and a blank schema, once its JSON is typed. Words all the same, never NO_CHANGE (the pet's is
    # the schema that most often got it).
    for name, alone in (("order", s0), ("pet", fmt(PET))):
        k, words, r = step(key, "to_prompt", schema=alone)
        calls.append(r)
        log.append((f"p1 {name} alone", words))
        if k != "prompt":
            fails.append(f"{name} schema alone: {k}")
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


def chain_rename_roundtrip(key):
    """to-schema renames a field (its key kept, its title the new name); a hand edit adds a description to it; to-prompt must still
    call it by the new name; to-schema again with those words changes nothing."""
    from gen_cases import CONTACT_HAND
    p0 = "email required, phone required, description"
    p1 = "email required, mobile number required, description"
    log, calls, fails = [], [], []
    k, s1, r = step(key, "to_schema", previous_prompt=p0, prompt=p1, schema=fmt(CONTACT_HAND))
    calls.append(r)
    log.append(("s1", s1))
    if k != "schema":
        return [f"step1 {k}"], log, calls
    o = json.loads(s1)
    phone = o["properties"].get("phone")
    if not isinstance(phone, dict) or str(phone.get("title", "")).strip().lower() != "mobile number":
        return [f"step1 phone {json.dumps(phone)[:120]}"], log, calls
    phone["description"] = "Cell preferred."
    s2 = fmt(o)
    k, p2, r = step(key, "to_prompt", prompt=p1, previous_schema=s1, schema=s2)
    calls.append(r)
    log.append(("p2", p2))
    if k == "prompt":
        if "mobile number" not in p2.lower():
            fails.append(f"step2 prompt lost the name: {p2!r}")
        words = p2
    elif k == "nochange":
        words = p1
    else:
        return [f"step2 {k}"], log, calls
    k, s3, r = step(key, "to_schema", previous_prompt=p1, prompt=words, schema=s2)
    calls.append(r)
    log.append(("s3", s3))
    if k == "schema" and json.loads(s3) != o:
        fails.append("step3 drift: the same words changed the schema")
    elif k == "error":
        fails.append("step3 error")
    return fails, log, calls


def chain_relate_stays(key):
    """Five edits around a standing 'is in a @Layer': the words that relate the thing to Layer write no property for it, and no
    rewrite, by the model or by hand, takes them out of the words or puts Layer in the schema (the ratchet's measure).
    1. words -> schema; 2. an edit about something else -> schema; 3. a field added by hand -> words; 4. another words edit ->
    schema; 5. a field taken out by hand -> words. After every schema no property is named for Layer, none is a `$ref` to it and
    none is a pointer; after steps 3 and 5 the words still say 'is in a @Layer'."""
    from gen_cases import FEATURE
    schemas = "@Layer"
    p0 = "a feature: a purpose, and is in a @Layer"
    log, calls, fails = [], [], []

    def schema_violations(step_name, text):
        try:
            obj = json.loads(text)
        except ValueError:
            return [f"{step_name} not JSON"]
        out = []
        if any(ref == "@Layer" for ref in refs_in(obj)):
            out.append(f"{step_name} $ref to @Layer")
        if is_pointer_like(obj):
            out.append(f"{step_name} pointer-like")
        if any("layer" in k.lower() for k in (obj.get("properties") or {})):
            out.append(f"{step_name} a property for Layer")
        return out

    def words_violations(step_name, text):
        return [] if "is in a @Layer" in text else [f"{step_name} lost 'is in a @Layer': {text[:120]!r}"]

    k, s1, r = step(key, "to_schema", prompt=p0, schema=STARTER, schemas=schemas)
    calls.append(r)
    log.append(("s1", s1))
    if k != "schema":
        return [f"step1 {k}"], log, calls
    fails += schema_violations("step1", s1)
    p1 = p0 + ", a priority (1 to 5)"
    k, s2, r = step(key, "to_schema", previous_prompt=p0, prompt=p1, schema=s1, schemas=schemas)
    calls.append(r)
    log.append(("s2", s2))
    if k != "schema":
        return fails + [f"step2 {k}"], log, calls
    fails += schema_violations("step2", s2)
    o2 = json.loads(s2)
    o3 = json.loads(json.dumps(o2))
    o3["properties"]["estimate"] = {"type": "integer", "minimum": 0}
    s3 = fmt(o3)
    k, p3, r = step(key, "to_prompt", prompt=p1, previous_schema=s2, schema=s3, schemas=schemas)
    calls.append(r)
    log.append(("p3", p3))
    if k == "prompt":
        fails += words_violations("step3", p3)
        words = p3
    elif k == "nochange":
        fails.append("step3 NO_CHANGE for a field added by hand")
        words = p1
    else:
        return fails + [f"step3 {k}"], log, calls
    p4 = words + ", an owner"
    k, s4, r = step(key, "to_schema", previous_prompt=words, prompt=p4, schema=s3, schemas=schemas)
    calls.append(r)
    log.append(("s4", s4))
    if k != "schema":
        return fails + [f"step4 {k}"], log, calls
    fails += schema_violations("step4", s4)
    o5 = json.loads(s4)
    o5["properties"].pop("estimate", None)
    s5 = fmt(o5)
    k, p5, r = step(key, "to_prompt", prompt=p4, previous_schema=s4, schema=s5, schemas=schemas)
    calls.append(r)
    log.append(("p5", p5))
    if k == "prompt":
        fails += words_violations("step5", p5)
    elif k == "nochange":
        fails.append("step5 NO_CHANGE for a field taken out by hand")
    else:
        fails.append(f"step5 {k}")
    return fails, log, calls


CHAINS = [chain_hand_edit, chain_roundtrip, chain_pet_both_ways, chain_contact_both_ways, chain_rename_roundtrip, chain_relate_stays]


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
    print(f"model {MODEL}, effort {EFFORT}; a new type's schema {STARTER!r}; JSON words are said to have been over {JSON_WORDS_OVER!r}")
    for d in CONFIG:
        text = system_prompt(d)
        print(f"{d}: {CONFIG[d]['system']} and {' and '.join(CONFIG[d]['titles'])}, {len(text)} characters, {len(text.splitlines())} lines, "
              f"and {CONFIG[d]['references']}, {len(literal(CONFIG[d]['references']))} characters, for other schemas; "
              f"max_tokens {CONFIG[d]['max_tokens']}")
    if Draft202012Validator is None:
        print("metaschema check skipped: no jsonschema in _pylib (see README.md)")
    if args.check:
        check_cases_file()
        checks, reads, scored = selftest()
        print(f"cases.csv: every check it names is one run_check has; the new checks' self-test: {checks} rows; "
              f"a prompt read from its <{ANSWER_TAG}> tags: {reads} answers, {scored} checks a remark fails only without them; "
              f"{len(CHAINS)} chains")
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
        c = prepare(c)
        user = user_message(c["direction"], prompt=c["prompt"], schema=c["schema"],
                            previous_prompt=c["previous_prompt"], previous_schema=c["previous_schema"], schemas=c.get("schemas", ""))
        r = call(key, c["direction"], user, c.get("schemas", ""), c.get("relationship") == "1")
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
        if d == "to_prompt":
            # Of the answers read as a prompt (NO_CHANGE and errors aside): how many had no tags, and how many
            # said something around them.
            prompts = [r for r in records if r["direction"] == d and r.get("kind") == "prompt"]
            print(f"{'':<10} {len(prompts)} prompts: {sum('untagged' in r['warn'] for r in prompts)} with no <{ANSWER_TAG}> tags, "
                  f"{sum('remark' in r['warn'] for r in prompts)} with a remark around them")


if __name__ == "__main__":
    try:
        main()
    except Fatal as e:
        print(f"stopped: {e}")
        sys.exit(1)
