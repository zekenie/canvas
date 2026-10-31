#!/usr/bin/env python3
"""Fetch the public data the prototype's boards are drawn from, into a data folder of its own:

    python3 -I fetch.py DATA

- DATA/H118_*.csv: Voteview's 118th Congress (members, roll calls, votes), downloaded beforehand.
- DATA/epa/vehicles.csv: the EPA's fuel-economy data (every car model and year sold in the US since 1984).
- DATA/census/pa.json: the Census Bureau's ACS 2022 1-year profile of Pennsylvania's 17 districts.
- DATA/wiki/PA-N.json: Wikipedia's summary of each district.
- DATA/crs/<bill>.json: the Congressional Research Service's summaries of each bill on the board (congress.gov,
  DEMO_KEY, which allows a few calls a minute), else Wikipedia's summary of it.

Each source is fetched once; a file already there is kept. Python 3.9 stdlib.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bills import BILLS  # noqa: E402

UA = {"User-Agent": "infinite-canvas-language-rules-prototype/0.1 (research)"}


def get(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


# The Census Bureau's American Community Survey, through Census Reporter (api.census.gov now wants a key): income,
# age, veterans, schooling, birthplace, poverty and the share of workers in each industry.
ACS_TABLES = ["B19013", "B01002", "B21001", "B15003", "B05012", "B17001", "C24050"]


def census(data):
    path = os.path.join(data, "census", "pa.json")
    if os.path.exists(path):
        return
    geos = ",".join("50000US42%02d" % n for n in range(1, 18))
    got = json.loads(get(f"https://api.censusreporter.org/1.0/data/show/latest?table_ids={','.join(ACS_TABLES)}&geo_ids={geos}"))
    save(path, json.dumps(got, indent=1).encode())
    print("census: %d districts, %s" % (len(got["data"]), got["release"]["name"]))


def ordinal(n):
    return "%d%s" % (n, "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


def wiki_summary(title):
    url = "https://en.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_"))
    for attempt in range(6):
        try:
            return json.loads(get(url))
        except urllib.error.HTTPError as e:
            if e.code != 429:
                raise
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"Wikipedia kept refusing {title}")


def districts(data):
    for n in range(1, 18):
        path = os.path.join(data, "wiki", f"PA-{n}.json")
        if os.path.exists(path):
            continue
        s = wiki_summary(f"Pennsylvania's {ordinal(n)} congressional district")
        save(path, json.dumps({"title": s.get("title"), "extract": s.get("extract"), "url": s.get("content_urls", {}).get("desktop", {}).get("page")}, indent=1).encode())
        time.sleep(1.5)
    print("wikipedia: 17 districts")


def bills(data):
    for b in BILLS:
        path = os.path.join(data, "crs", f"{b['bill']}.json")
        if os.path.exists(path):
            continue
        kind, number = b["bill"][:2].lower(), b["bill"][2:]
        url = f"https://api.congress.gov/v3/bill/118/{kind}/{number}/summaries?api_key=DEMO_KEY&format=json"
        got = None
        for attempt in range(4):
            try:
                got = json.loads(get(url))
                if got.get("error"):
                    raise urllib.error.URLError(got["error"].get("code"))
                break
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
                print(f"  {b['bill']}: {e}; waiting", file=sys.stderr)
                got = None
                time.sleep(20)
        if got is None and b.get("wiki"):
            s = wiki_summary(b["wiki"])
            got = {"wikipedia": {"title": s.get("title"), "extract": s.get("extract")}}
        save(path, json.dumps(got or {}, indent=1).encode())
        time.sleep(4)
    print("bills: %d" % len(BILLS))


if __name__ == "__main__":
    data = sys.argv[1]
    census(data)
    districts(data)
    bills(data)
