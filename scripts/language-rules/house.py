#!/usr/bin/env python3
"""The whole House in the app: every member of the 118th House and how they voted on the prototype's 16 bills, a board
per state, with the votes checked by language rules: a trial of the feature on a board of real data at scale, beside
the prototype's Cars and Listings, which carry labels by construction.

    python3 -I house.py fetch DATA                 # Census Reporter and Wikipedia, every district (each file once)
    python3 -I house.py prepare DATA OUT           # OUT/house.json: states, members, districts, bills, votes, labels
    python3 house.py draw OUT CANVAS FOLDER        # FOLDER/House votes.canvasboard, Cars.canvasboard, Listings.canvasboard
    python3 house.py rules OUT CANVAS FOLDER       # the votes' rules, last, so the checks start once
    python3 house.py score OUT CANVAS FOLDER       # what the rules flagged, against Voteview's labels and the planted ones

DATA holds Voteview's H118_*.csv, and fetch.py's crs/ and epa/ (the prototype's data folder). CANVAS is this worktree's
build/canvas, with CANVAS_SOCKET pointing at a test copy of the app (README, Running it).

Every value is real but the cars' mileage and the listings' words: Voteview's members and votes, Wikipedia's words for
each district, the Census Bureau's figures through Census Reporter, the CRS's summaries of the bills. Census Reporter
serves only the latest release, ACS 2024, drawn on the 119th Congress's districts: AL, GA, LA, NC and NY were redrawn
for 2024, so their figures describe the new lines, which each district's description says. The rules are drawn last,
so the checks start once, on a board that's all there. Python 3.9 stdlib.
"""
import csv
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import boards  # noqa: E402
import evals  # noqa: E402
import fetch  # noqa: E402
import listings  # noqa: E402
import prepare  # noqa: E402
from bills import BILLS  # noqa: E402

STATES = {
    "AL": ("Alabama", "01"), "AK": ("Alaska", "02"), "AZ": ("Arizona", "04"), "AR": ("Arkansas", "05"),
    "CA": ("California", "06"), "CO": ("Colorado", "08"), "CT": ("Connecticut", "09"), "DE": ("Delaware", "10"),
    "FL": ("Florida", "12"), "GA": ("Georgia", "13"), "HI": ("Hawaii", "15"), "ID": ("Idaho", "16"),
    "IL": ("Illinois", "17"), "IN": ("Indiana", "18"), "IA": ("Iowa", "19"), "KS": ("Kansas", "20"),
    "KY": ("Kentucky", "21"), "LA": ("Louisiana", "22"), "ME": ("Maine", "23"), "MD": ("Maryland", "24"),
    "MA": ("Massachusetts", "25"), "MI": ("Michigan", "26"), "MN": ("Minnesota", "27"), "MS": ("Mississippi", "28"),
    "MO": ("Missouri", "29"), "MT": ("Montana", "30"), "NE": ("Nebraska", "31"), "NV": ("Nevada", "32"),
    "NH": ("New Hampshire", "33"), "NJ": ("New Jersey", "34"), "NM": ("New Mexico", "35"), "NY": ("New York", "36"),
    "NC": ("North Carolina", "37"), "ND": ("North Dakota", "38"), "OH": ("Ohio", "39"), "OK": ("Oklahoma", "40"),
    "OR": ("Oregon", "41"), "PA": ("Pennsylvania", "42"), "RI": ("Rhode Island", "44"), "SC": ("South Carolina", "45"),
    "SD": ("South Dakota", "46"), "TN": ("Tennessee", "47"), "TX": ("Texas", "48"), "UT": ("Utah", "49"),
    "VT": ("Vermont", "50"), "VA": ("Virginia", "51"), "WA": ("Washington", "53"), "WV": ("West Virginia", "54"),
    "WI": ("Wisconsin", "55"), "WY": ("Wyoming", "56"),
}
REDRAWN = {"AL", "GA", "LA", "NC", "NY"}

# The rules, as what should be true of a vote (the shipped words read them so: round 1's "hold" wording), the district
# rule's phrase a chip that finds the member's district subboard, which brings the cards it holds.
VOTE_RULES = [
    {"says": "In line with the member's record."},
    {"says": "Fits someone representing the member's district.",
     "find": [{"phrase": "the member's district", "query": "subboard:edge-from(:scope-start, arrow)"}]},
]
CAR_RULES = [{"says": evals.HOLD[r["says"]]} for r in boards.CAR_RULES]
TOYOTA_RULES = [{"says": "This model was made in this year, per the Toyota lineup.",
                 "find": [{"phrase": "the Toyota lineup", "query": "subboard\"Toyota lineup\""}]}]
VINTAGE_RULES = [{"says": evals.HOLD[r["says"]]} for r in boards.VINTAGE_RULES]


# ------------------------------------------------------------------------------------------------ fetching

def members_by_state(data):
    """Voteview's House members of the 118th in the fifty states (delegates cast no final-passage votes)."""
    rows = [r for r in csv.DictReader(open(os.path.join(data, "H118_members.csv")))
            if r["chamber"] == "House" and r["state_abbrev"] in STATES]
    out = defaultdict(list)
    for r in rows:
        out[r["state_abbrev"]].append(r)
    return out


def at_large(state, members):
    return {m["district_code"] for m in members} == {"1"} and state in ("AK", "DE", "ND", "SD", "VT", "WY")


def district_codes(state, members):
    """Each district of a state: its board title, its number (0 at large) and its Census geo id."""
    fips = STATES[state][1]
    if at_large(state, members):
        return [(f"{state}-AL", 0, f"50000US{fips}00")]
    numbers = sorted({int(m["district_code"]) for m in members})
    return [(f"{state}-{n}", n, f"50000US{fips}{n:02d}") for n in numbers]


def census_all(data):
    for state, members in sorted(members_by_state(data).items()):
        path = os.path.join(data, "census", f"{state.lower()}.json")
        if os.path.exists(path) and os.path.getsize(path) > 0:
            continue
        geos = ",".join(g for _, _, g in district_codes(state, members))
        got = json.loads(fetch.get(f"https://api.censusreporter.org/1.0/data/show/latest?table_ids={','.join(fetch.ACS_TABLES)}&geo_ids={geos}"))
        fetch.save(path, json.dumps(got, indent=1).encode())
        time.sleep(0.5)
    print("census: every state")


def wiki_all(data):
    """Each district's first paragraph, twenty pages a request through the Action API: the REST summary fetch.py uses,
    a page a call, is throttled past a couple of hundred."""
    wanted = []
    for state, members in sorted(members_by_state(data).items()):
        name = STATES[state][0]
        for title, n, _ in district_codes(state, members):
            if not os.path.exists(os.path.join(data, "wiki", f"{title}.json")):
                page = f"{name}'s at-large congressional district" if n == 0 else f"{name}'s {fetch.ordinal(n)} congressional district"
                wanted.append((title, page))
    for i in range(0, len(wanted), 20):
        batch = wanted[i:i + 20]
        params = {"action": "query", "format": "json", "prop": "extracts|info", "inprop": "url", "exintro": "1",
                  "explaintext": "1", "exlimit": "20", "redirects": "1", "titles": "|".join(p for _, p in batch)}
        url = "https://en.wikipedia.org/w/api.php?" + fetch.urllib.parse.urlencode(params)
        for attempt in range(10):
            try:
                got = json.loads(fetch.get(url))
                break
            except fetch.urllib.error.HTTPError as e:
                if e.code != 429 or attempt == 9:
                    raise
                wait = int(e.headers.get("Retry-After") or 0) or 30 * (attempt + 1)
                print(f"  wikipedia: throttled, waiting {wait}s", file=sys.stderr, flush=True)
                time.sleep(wait)
        query = got.get("query", {})
        moved = {r["from"]: r["to"] for r in query.get("normalized", []) + query.get("redirects", [])}
        pages = {p.get("title"): p for p in query.get("pages", {}).values()}
        for title, page in batch:
            name = page
            while name in moved:
                name = moved[name]
            p = pages.get(name, {})
            extract = (p.get("extract") or "").strip().split("\n")[0]
            fetch.save(os.path.join(data, "wiki", f"{title}.json"),
                       json.dumps({"title": p.get("title"), "extract": extract, "url": p.get("fullurl")}, indent=1).encode())
        time.sleep(1)
    print(f"wikipedia: {len(wanted)} districts fetched")


# ------------------------------------------------------------------------------------------------ preparing

def proper(word):
    """A surname as it's written: OCASIO-CORTEZ → Ocasio-Cortez, O'CONNOR → O'Connor, McCARTHY → McCarthy,
    DeLAURO → DeLauro, MCCLINTOCK → McClintock."""
    def part(p):
        if not p:
            return p
        lower = [i for i, c in enumerate(p) if c.islower()]
        if lower:  # Voteview writes a mixed-case prefix as it is: Mc, De, La, Des
            cut = lower[-1] + 1
            return p[:cut] + p[cut:].capitalize()
        if p.startswith("MC") and len(p) > 2:
            return "Mc" + p[2:].capitalize()
        return p.capitalize()
    return re.sub(r"[^\-' ]+", lambda m: part(m.group(0)), word)


def name_of(bioname):
    last, first = bioname.split(",", 1)
    nick = re.search(r"\(([^)]+)\)", first)
    given = [w for w in re.sub(r"\([^)]*\)", " ", first).replace(",", " ").split() if w not in ("Jr.", "Sr.", "II", "III", "IV")]
    if nick:
        first_name = nick.group(1)
    else:
        first_name = next((w for w in given if not re.fullmatch(r"[A-Z]\.", w)), given[0] if given else "")
    return f"{first_name} {proper(last.strip())}"


def figures(tables):
    e = {t: v["estimate"] for t, v in tables.items()}
    def share(t, num, den):
        return 100.0 * sum(e[t][c] for c in num) / e[t][den]
    ind = e["C24050"]
    total = ind["C24050001"]
    cards = [
        ("Median household income", "${:,.0f}".format(e["B19013"]["B19013001"])),
        ("Median age", "{:.1f}".format(e["B01002"]["B01002001"])),
        ("Adults who are veterans", "{:.1f}%".format(share("B21001", ["B21001002"], "B21001001"))),
        ("Adults 25+ with a bachelor's degree or more", "{:.1f}%".format(share("B15003", ["B15003022", "B15003023", "B15003024", "B15003025"], "B15003001"))),
        ("People born abroad", "{:.1f}%".format(share("B05012", ["B05012003"], "B05012001"))),
        ("People below the poverty line", "{:.1f}%".format(share("B17001", ["B17001002"], "B17001001"))),
    ]
    for col, name in [("C24050002", "farming, forestry, fishing and mining"), ("C24050003", "construction"),
                      ("C24050004", "manufacturing"), ("C24050007", "transportation, warehousing and utilities"),
                      ("C24050011", "education, health care and social help"), ("C24050014", "public administration")]:
        cards.append((f"Workers in {name}", "{:.1f}%".format(100.0 * ind[col] / total)))
    return cards


def prepare_all(data):
    rolls = {r["rollnumber"]: r for r in csv.DictReader(open(os.path.join(data, "H118_rollcalls.csv")))}
    by_state = members_by_state(data)
    everyone = {m["icpsr"]: m for ms in by_state.values() for m in ms}
    wanted = {b["roll"] for b in BILLS}
    cast = defaultdict(dict)
    for v in csv.DictReader(open(os.path.join(data, "H118_votes.csv"))):
        if v["rollnumber"] in wanted and v["icpsr"] in everyone and v["cast_code"] in ("1", "2", "3", "4", "5", "6"):
            cast[v["icpsr"]][v["rollnumber"]] = ("Yea" if int(v["cast_code"]) <= 3 else "Nay", float(v["prob"]) if v["prob"] else None)
    bills = []
    for b in BILLS:
        r = rolls[b["roll"]]
        words, source = prepare.bill_words(data, b, r["date"])
        result = ("Passed" if r["vote_result"] in ("Passed", "Agreed to") else "Failed") + f" {r['yea_count']}–{r['nay_count']}"
        bills.append({"title": b["title"], "number": re.sub(r"^HR", "H.R. ", b["bill"]), "date": r["date"],
                      "result": result, "words": words, "wordsSource": source, "roll": b["roll"]})
    names = {}
    for icpsr, m in everyone.items():
        last = m["bioname"].split(",")[0]
        names[icpsr] = prepare.NAMES[last] if m["state_abbrev"] == "PA" and last in prepare.NAMES else name_of(m["bioname"])
    twice = {n for n in names.values() if list(names.values()).count(n) > 1}
    states, votes = [], []
    for state, members in sorted(by_state.items(), key=lambda kv: STATES[kv[0]][0]):
        name = STATES[state][0]
        with open(os.path.join(data, "census", f"{state.lower()}.json")) as f:
            census = json.load(f)
        release = census["release"]["name"]
        codes = district_codes(state, members)
        districts = []
        for title, n, geo in codes:
            with open(os.path.join(data, "wiki", f"{title}.json")) as f:
                wiki = json.load(f)
            where = f"{name}'s at-large congressional district" if n == 0 else f"{name}'s {fetch.ordinal(n)} congressional district"
            lines = " The figures describe its lines as redrawn for 2024." if state in REDRAWN else ""
            districts.append({"title": title, "place": prepare.clean(wiki.get("extract") or ""), "placeSource": wiki.get("url"),
                              "figures": figures(census["data"][geo]),
                              "description": f"{where}. Figures: Census Bureau, American Community Survey ({release}), via Census Reporter.{lines} Description: Wikipedia."})
        out_members = []
        for m in sorted(members, key=lambda m: (int(m["district_code"]), m["bioname"])):
            if not cast.get(m["icpsr"]):
                continue  # none of the 16 votes cast: gone before the first, or came after the last
            title = names[m["icpsr"]]
            district = codes[0][0] if codes[0][1] == 0 else f"{state}-{int(m['district_code'])}"
            if title in twice:
                title = f"{title} ({district})"
            party = {"100": "D", "200": "R"}.get(m["party_code"], "I")
            out_members.append({"icpsr": m["icpsr"], "title": title, "party": party, "district": district})
            for b in bills:
                c = cast[m["icpsr"]].get(b["roll"])
                if c:
                    votes.append({"state": name, "member": title, "bill": b["title"], "position": c[0], "nominate": c[1],
                                  "expect": {"vote-record": (c[1] < 50) if c[1] is not None else None}})
        used = {m["district"] for m in out_members}
        states.append({"abbrev": state, "name": name, "members": out_members, "districts": [d for d in districts if d["title"] in used]})
    return {"states": states, "bills": bills, "votes": votes}


# ------------------------------------------------------------------------------------------------ drawing

q, schema, values = boards.q, boards.schema, boards.values

MEMBER = schema({"party": {"type": "string", "enum": ["D", "R", "I"]}, "district": {"type": "string"}}, ("party", "district"))
VOTE_FIELDS = {"position": {"type": "string", "enum": ["Yea", "Nay"]}}
BILL = schema({"number": {"type": "string"}, "date": {"type": "string", "format": "date"}, "result": {"type": "string"}}, ("number", "date"))
FIGURE = schema({"value": {"type": "string"}, "source": {"type": "string"}}, ("value",))
PLACE = schema({})


def root_runs(h):
    vote = schema(VOTE_FIELDS, ("position",))
    runs = [("types", "\n".join([
        f'sticky-note "Member" schema: {q(MEMBER)} text: "A member of the 118th House: their party and their district."',
        f'sticky-note "Vote" right of "Member" (gap: 360) relationship: true schema: {q(vote)} text: "How a member voted on a bill: Yea or Nay."',
        f'sticky-note "Bill" right of "Vote" (gap: 360) schema: {q(BILL)} text: "A bill the House voted on, in a sentence or two."',
        f'sticky-note "Figure" right of "Bill" (gap: wide) schema: {q(FIGURE)} text: "A figure about a district, and where it comes from."',
        f'sticky-note "Place" right of "Figure" schema: {q(PLACE)} text: "Where a district is, and what\'s in it."',
        'edge "Member" -> "Vote"',
        'edge "Vote" -> "Bill"',
    ]))]
    lines = []
    for i, b in enumerate(h["bills"]):
        place = 'below "Place" (gap: 200)' if i == 0 else f'below {q(h["bills"][i - 1]["title"])}'
        text = f' text: {q(b["words"])}' if b.get("words") else ""
        # Public, as every shape is, so a state's board can stand for it.
        lines.append(f'sticky-note {q(b["title"])} {place} is: "Bill" fieldValues: '
                     f'{values({"number": b["number"], "date": b["date"], "result": b["result"]})}{text}')
    runs.append(("bills", "\n".join(lines)))
    lines = []
    names = [s["name"] for s in h["states"]]
    for i, s in enumerate(h["states"]):
        place = 'below "Member" (gap: 200)' if i == 0 else (f'right of {q(names[i - 1])}' if i % 4 else f'below {q(names[i - 4])}')
        lines.append(f'subboard {q(s["name"])} {place} description: '
                     f'{q(s["name"] + "’s members of the 118th House, their districts, and how each voted on the 16 bills.")}')
    runs.append(("states", "\n".join(lines)))
    return runs


def state_run(s, votes):
    lines = []
    ms = s["members"]
    for i, m in enumerate(ms):
        place = "" if i == 0 else f' below {q(ms[i - 1]["title"])}'
        lines.append(f'sticky-note {q(m["title"])} in {q(s["name"])}{place} is: "Member" '
                     f'fieldValues: {values({"party": m["party"], "district": m["district"]})}')
    placed = set()
    for m in ms:
        if m["district"] in placed:
            continue
        placed.add(m["district"])
        d = next(d for d in s["districts"] if d["title"] == m["district"])
        lines.append(f'subboard {q(d["title"])} in {q(s["name"])} left of {q(m["title"])} (gap: wide) description: {q(d["description"])}')
    for m in ms:
        lines.append(f'edge {q(m["title"])} -> {q(m["district"])}')
    # One pill a bill, shared by every vote on it, the sixteen spread down the members' column (a member is about 280
    # tall with its rows) so the arrows fan out rather than knot at the first member.
    order = [b for b in dict.fromkeys(v["bill"] for v in votes)]
    step = max(48, round(len(ms) * 280 / max(len(order), 1)))
    placed_bills = set()
    for v in votes:
        where = ""
        if v["bill"] not in placed_bills:
            placed_bills.add(v["bill"])
            first = q(ms[0]["title"])
            where = f' via: reference right of {first} (gap: 700) below {first} top (gap: {order.index(v["bill"]) * step})'
        lines.append(f'edge {q(v["member"])} -> {q(v["bill"])} is: "Vote" fieldValues: {values({"position": v["position"]})}{where} share: true')
    return "\n".join(lines)


def district_run(d):
    lines = [f'sticky-note {q("About " + d["title"])} in {q(d["title"])} is: "Place" text: {q(d["place"] or "No description.")}']
    prev = "About " + d["title"]
    for j, (measure, value) in enumerate(d["figures"]):
        place = f'right of {q(prev)}' if j == 0 else (f'below {q(d["figures"][j - 1][0])}' if j % 6 else f'right of {q(d["figures"][j - 6][0])}')
        lines.append(f'sticky-note {q(measure)} in {q(d["title"])} {place} is: "Figure" fieldValues: {values({"value": value, "source": "ACS 2024 1-year"})}')
    return "\n".join(lines)


def rules_run():
    return f'sticky-note "Vote" schema: {q(schema(VOTE_FIELDS, ("position",), VOTE_RULES))}'


def run(cli, board_id, name, script, log):
    started = time.time()
    p = subprocess.run([cli, "draw", "--board", str(board_id), "--timeout", "300", "-"], input=script, capture_output=True, text=True)
    took = time.time() - started
    if p.returncode != 0:
        raise SystemExit(f"{name}: canvas draw failed ({p.returncode}) after {took:.1f}s: {p.stderr.strip()[:3000]}")
    out = json.loads(p.stdout)
    did = defaultdict(int)
    for c in out.get("changes", []):
        did[c["did"]] += 1
    warnings = out.get("warnings") or []
    line = f"{name}: {took:.1f}s {dict(did)}" + (f", {len(warnings)} warnings: {json.dumps(warnings[:2])[:600]}" if warnings else "")
    print(line, flush=True)
    log.write(json.dumps({"run": name, "seconds": round(took, 2), "did": did, "warnings": len(warnings)}) + "\n")
    log.flush()
    return out


def draw_all(out, cli, folder, only=None):
    os.makedirs(folder, exist_ok=True)
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "draw-log.jsonl"), "a")
    started = time.time()
    if not only or "house" in only:
        with open(os.path.join(out, "house.json")) as f:
            h = json.load(f)
        bid = boards.board(cli, os.path.join(folder, "House votes.canvasboard"))
        for name, script in root_runs(h):
            run(cli, bid, name, script, log)
        by_state = defaultdict(list)
        for v in h["votes"]:
            by_state[v["state"]].append(v)
        for s in h["states"]:
            run(cli, bid, s["name"], state_run(s, by_state[s["name"]]), log)
        for s in h["states"]:
            for d in s["districts"]:
                run(cli, bid, d["title"], district_run(d), log)
        print(f"house drawn in {time.time() - started:.0f}s", flush=True)
    if not only or "cars" in only:
        with open(os.path.join(out, "cars.json")) as f:
            cars = json.load(f)
        bid = boards.board(cli, os.path.join(folder, "Cars.canvasboard"))
        saved = (boards.CAR_RULES, boards.TOYOTA_RULES, boards.VINTAGE_RULES)
        boards.CAR_RULES, boards.TOYOTA_RULES, boards.VINTAGE_RULES = CAR_RULES, TOYOTA_RULES, VINTAGE_RULES
        try:
            for name, script in boards.cars_runs(cars):
                run(cli, bid, "cars: " + name, script, log)
        finally:
            boards.CAR_RULES, boards.TOYOTA_RULES, boards.VINTAGE_RULES = saved
    if not only or "listings" in only:
        bid = boards.board(cli, os.path.join(folder, "Listings.canvasboard"))
        for name, script in boards.listings_runs():
            run(cli, bid, "listings: " + name, script, log)


def rules_all(out, cli, folder):
    """The rules last, so the checks start once, on a board that's all there."""
    log = open(os.path.join(out, "draw-log.jsonl"), "a")
    bid = boards.board(cli, os.path.join(folder, "House votes.canvasboard"))
    run(cli, bid, "rules", rules_run(), log)
    print(f"rules written at {time.strftime('%H:%M:%S')}", flush=True)


# ------------------------------------------------------------------------------------------------ scoring

def warned(cli, board, query):
    """The rows of `query` that a rule warns, by what each warning says. A row says its problems only for a query with a
    word that reads them, and `:warned` waits for the checks still out."""
    p = subprocess.run([cli, "query", "--board", board, "--limit", "10000", "-"], input=query + ":warned",
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"canvas query failed: {p.stderr.strip()[:2000]}")
    return json.loads(p.stdout)["rows"]


def score_labeled(cli, out, folder):
    """Cars and Listings, whose planted mistakes are their labels."""
    cars = {c["title"]: c for c in json.load(open(os.path.join(out, "cars.json")))["cars"]}
    flagged = {r["title"] for r in warned(cli, os.path.join(folder, "Cars.canvasboard"), "sticky-note")}
    planted = {t for t, c in cars.items() if c["planted"]}
    print(f"cars: {len(flagged & planted)} of {len(planted)} planted caught, {len(flagged - planted)} false alarms "
          f"({', '.join(sorted(flagged - planted)) or 'none'})")
    flagged = {r["title"] for r in warned(cli, os.path.join(folder, "Listings.canvasboard"), "sticky-note")}
    bad = {row[0] for row in listings.LISTINGS if row[7]}  # a rule it breaks, read together
    print(f"listings: {len(flagged & bad)} of {len(bad)} caught ({', '.join(sorted(bad - flagged)) or 'none'} missed), "
          f"{len(flagged - bad)} false alarms ({', '.join(sorted(flagged - bad)) or 'none'})")


def score_house(cli, out, folder):
    """The votes the rules warn, against Voteview's label for the record rule (its model rated the vote under 50% likely);
    the district rule has none."""
    h = json.load(open(os.path.join(out, "house.json")))
    votes = {(v["member"], v["bill"]): v for v in h["votes"]}
    rows = warned(cli, os.path.join(folder, "House votes.canvasboard"), 'arrow:is-a("Vote")')
    by_rule = defaultdict(set)
    for r in rows:
        key = (r["connection"]["from"]["title"], r["connection"]["to"]["title"])
        for p in r["problems"]:
            by_rule[p["message"]].add(key)
    unusual = {k for k, v in votes.items() if v["expect"]["vote-record"]}
    record = by_rule.get(VOTE_RULES[0]["says"], set())
    print(f"house: {len(rows)} of {len(votes)} votes warned; the record rule {len(record)}, {len(record & unusual)} of them "
          f"among Voteview's {len(unusual)} unlikely votes; the district rule {len(by_rule.get(VOTE_RULES[1]['says'], set()))}")


if __name__ == "__main__":
    what = sys.argv[1]
    if what == "fetch":
        census_all(sys.argv[2])
        wiki_all(sys.argv[2])
    elif what == "prepare":
        data, out = sys.argv[2], sys.argv[3]
        os.makedirs(out, exist_ok=True)
        h = prepare_all(data)
        with open(os.path.join(out, "house.json"), "w") as f:
            json.dump(h, f, indent=1, ensure_ascii=False)
        with open(os.path.join(out, "cars.json"), "w") as f:
            json.dump(prepare.cars(data), f, indent=1, ensure_ascii=False)
        flagged = sum(1 for v in h["votes"] if v["expect"]["vote-record"])
        print(f"house: {len(h['states'])} states, {sum(len(s['members']) for s in h['states'])} members, "
              f"{sum(len(s['districts']) for s in h['states'])} districts, {len(h['bills'])} bills, {len(h['votes'])} votes, "
              f"{flagged} unusual for the record by Voteview")
    elif what == "draw":
        draw_all(sys.argv[2], sys.argv[3], sys.argv[4], only=sys.argv[5:] or None)
    elif what == "rules":
        rules_all(sys.argv[2], sys.argv[3], sys.argv[4])
    elif what == "score":
        score_house(sys.argv[3], sys.argv[2], sys.argv[4])
        score_labeled(sys.argv[3], sys.argv[2], sys.argv[4])
    else:
        raise SystemExit(__doc__)
