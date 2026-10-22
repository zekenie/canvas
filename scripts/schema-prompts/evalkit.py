"""What the lite evals of the app's model calls share, so each has one copy: the key, the Swift their prompts and
settings are read out of, the call, and taking an answer out of what a model wraps it in. Each eval copies the
request and the parse rule of the call it tests from its Swift, and scores what it reads (evals.py: a type's sync;
highlight_evals.py: its highlights; fill_evals.py: a note's fields filled from its words).

Reads the key from ~/Library/Application Support/InfiniteCanvas/anthropic-api-key (where the app's Settings saves
it), else $ANTHROPIC_API_KEY, and never prints it. Calls https://api.anthropic.com directly. Python 3.9 stdlib.
"""
import json
import os
import re
import time
import urllib.error
import urllib.request

API_URL = "https://api.anthropic.com/v1/messages"
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.normpath(os.path.join(HERE, "..", "..", "Sources"))


class Fatal(Exception):
    pass


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


def read_swift(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def literal(src, name, path):
    """The raw string literal `static let <name> = #\"\"\"` ... `\"\"\"#` in `src` (read from `path`), flush left,
    as Swift reads it: the lines between the delimiters, without the last line break."""
    m = re.search(r'static let ' + name + r' = #"""\n(.*?)\n"""#', src, re.S)
    if not m:
        raise Fatal(f"no {name} in {path}")
    return m.group(1)


def setting(src, name, pattern, path):
    """The value `static let <name> = ` is followed by in `src`, as `pattern`'s first group reads it."""
    m = re.search(r'static let ' + name + r' = ' + pattern, src)
    if not m:
        raise Fatal(f"no {name} in {path}")
    return m.group(1)


def text_setting(src, name, path):
    return setting(src, name, r'"([^"]+)"', path)


def number_setting(src, name, path):
    return float(setting(src, name, r'([0-9_.]+)', path).replace("_", ""))


def block(tag, text):
    """`<tag>\\n{text}\\n</tag>`, the text trimmed; nothing for no text."""
    text = (text or "").strip()
    return f"<{tag}>\n{text}\n</{tag}>" if text else ""


def is_wrapper(line):
    """A fence line, or a line of one tag alone (<answer>, </output>)."""
    line = line.strip()
    return line.startswith("```") or re.fullmatch(r"</?[A-Za-z_-]+>", line) is not None


def unwrap(t, tag=None):
    """ModelAnswer.unwrapped: the text trimmed, without a fence line or a lone tag's line at either end and, with a
    tag, without the block's own tags (<schema>, </schema>), again until nothing changes."""
    t = t.strip()
    while True:
        before = t
        lines = t.split("\n")
        if lines and is_wrapper(lines[0]):
            lines = lines[1:]
        if lines and is_wrapper(lines[-1]):
            lines = lines[:-1]
        t = "\n".join(lines).strip()
        if tag and t.startswith(f"<{tag}>"):
            t = t[len(tag) + 2:].strip()
        if tag and t.endswith(f"</{tag}>"):
            t = t[: -(len(tag) + 3)].strip()
        if t == before:
            return t


def call(key, model, max_tokens, system, user, effort=None, temperature=None):
    """One request, as AnthropicModel sends it: what's nil left out (Haiku 5.5 and Sonnet 5.5 take no temperature but
    their default, Haiku 4.5 no effort), waiting a minute and a second for every 100 tokens it may write. Retries what's
    transient, twice the wait each time; the rest is Fatal. Returns the answer's text, why it stopped, how long it took
    and its tokens in and out."""
    body = {"model": model, "max_tokens": max_tokens, "system": system, "messages": [{"role": "user", "content": user}]}
    if effort is not None:
        body["output_config"] = {"effort": effort}
    if temperature is not None:
        body["temperature"] = temperature
    data = json.dumps(body).encode("utf-8")
    headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}
    delay = 2.0
    for attempt in range(6):
        req = urllib.request.Request(API_URL, data=data, headers=headers, method="POST")
        started = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=60 + max_tokens / 100) as resp:
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
