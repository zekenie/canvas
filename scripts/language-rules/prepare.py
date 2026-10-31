#!/usr/bin/env python3
"""Turn the fetched data into the two boards' contents, with the answer each rule should give:

    python3 -I prepare.py DATA OUT

writes OUT/cars.json and OUT/votes.json. Every value on the boards is real (the EPA's model years, Voteview's votes,
the Census Bureau's figures through Census Reporter, Wikipedia's and the CRS's words), except the cars' mileage and the
few cars planted to break a rule, which are made up and labeled so. Python 3.9 stdlib.
"""
import csv
import html
import json
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bills import BILLS  # noqa: E402

TODAY = "2026-10-27"


# ------------------------------------------------------------------------------------------------ cars

def lineup(data):
    """Each Toyota model and the model years the EPA lists it for, as runs: Venza 2009–2015, 2021–2024."""
    years = defaultdict(set)
    with open(os.path.join(data, "epa", "vehicles.csv"), encoding="latin-1") as f:
        for r in csv.DictReader(f):
            if r["make"] == "Toyota" and r["baseModel"] not in ("Van", "Cab Chassis", "Truck/T100"):
                years[r["baseModel"]].add(int(r["year"]))
    out = []
    for model, ys in years.items():
        ys = sorted(ys)
        runs, start = [], ys[0]
        for a, b in zip(ys, ys[1:] + [None]):
            if b != a + 1:
                runs.append((start, a))
                start = b
        out.append({"model": model, "runs": runs,
                    "years": ", ".join(f"{a}–{b}" if a != b else f"{a}" for a, b in runs)})
    return sorted(out, key=lambda m: (m["runs"][0][0], m["model"]))


def made(lineup_, model, year):
    m = next((m for m in lineup_ if m["model"] == model), None)
    return m is not None and any(a <= year <= b for a, b in m["runs"])


# A car: (title, type, year, make, model, miles, what each rule should say). Expected verdicts: True means the rule
# flags it, None that either answer is fair (left out of scoring). The mileage and the planted cars are made up.
CARS = [
    ("My car", "Toyota", 2021, "Toyota", "Corolla", 412000),
    ("Car 2", "Toyota", 2019, "Toyota", "Camry", 61000),
    ("Car 3", "Toyota", 2015, "Toyota", "RAV4", 118000),
    ("Car 4", "Toyota", 2010, "Toyota", "Prius", 214000),
    ("Car 5", "Toyota", 2022, "Toyota", "Tacoma", 31000),
    ("Car 6", "Toyota", 2008, "Toyota", "Highlander", 162000),
    ("Car 7", "Toyota", 2024, "Toyota", "Camry", 188000),
    ("Car 8", "Toyota", 2016, "Toyota", "Prius", 2100000),
    ("Car 9", "Toyota", 2003, "Toyota", "bZ4X", 140000),
    ("Car 10", "Toyota", 2015, "Toyota", "Celica", 70000),
    ("Car 11", "Toyota", 1999, "Toyota", "Prius", 180000),
    ("Car 12", "Toyota", 2012, "Toyota", "Supra", 64000),
    ("Car 13", "Toyota", 2018, "Toyota", "Venza", 59000),
    ("Car 14", "Toyota", 2025, "Toyota", "Crown Signia", 8000),
    ("Car 15", "Toyota", 2020, "Toyota", "GR Supra", 22000),
    ("Car 16", "Toyota", 2023, "Toyota", "Grand Highlander", 30000),
    ("Car 17", "Toyota", 2011, "Toyota", "Matrix", 97000),
    ("Car 18", "Toyota", 2006, "Toyota", "Tundra", 190000),
    ("Car 19", "Toyota", 2014, "Toyota", "FJ Cruiser", 88000),
    ("Car 20", "Toyota", 2026, "Toyota", "bZ", 1200),
    ("Car 21", "Toyota", 2009, "Toyota", "Yaris", 3100),
    ("Car 22", "Toyota", 2017, "Toyota", "86", 45000),
    ("Car 23", "Car", 2018, "Honda", "Civic", 74000),
    ("Car 24", "Car", 2023, "Ford", "F-150", 260000),
    ("Car 25", "Car", 2012, "Subaru", "Outback", 151000),
    ("Car 26", "Car", 2021, "Tesla", "Model 3", 52000),
    ("Car 27", "Car", 2005, "Honda", "Accord", 248000),
    ("Car 28", "Car", 2019, "Chevrolet", "Silverado 1500", 95000),
    ("Car 29", "Car", 2014, "Jeep", "Wrangler", 1400000),
    ("Car 30", "Car", 2022, "Hyundai", "Ioniq 5", 18000),
    ("Car 31", "Vintage", 1985, "Porsche", "911", 30),
    ("Car 32", "Vintage", 1990, "Mercedes-Benz", "300D", 2900000),
    ("Car 33", "Vintage", 1972, "Volkswagen", "Beetle", 9),
    ("Car 34", "Vintage", 1994, "Jeep", "Wrangler", 120000),
    ("Car 35", "Vintage", 2005, "Mazda", "MX-5 Miata", 40000),
    ("Car 36", "Vintage", 1967, "Ford", "Mustang", 96000),
]

# Mileage a person would call implausible for the age: far past what any car is driven a year, or none at all for a
# car years old. The two Yaris-like cases (very low but possible) are left to either answer.
def mileage_flag(year, miles):
    age = max(2026 - year, 0.5)
    per_year = miles / age
    if per_year > 45000:
        return True
    if per_year < 400 and age >= 5:
        return None  # a garage queen: odd, not impossible
    return False


def cars(data):
    line = lineup(data)
    out = []
    for title, typ, year, make, model, miles in CARS:
        age = 2026 - year
        expect = {}
        if typ == "Vintage":
            # Car's rule, read alone, may flag an extreme; Vintage's own words say mileage doesn't matter for it.
            expect["car-mileage"] = False
            expect["car-mileage/alone"] = mileage_flag(year, miles)
            expect["vintage-age"] = age < 25
        else:
            expect["car-mileage"] = mileage_flag(year, miles)
        if typ == "Toyota":
            expect["toyota-lineup"] = not made(line, model, year)
        out.append({"title": title, "type": typ, "values": {"year": year, "make": make, "model": model, "mileage": miles},
                    "expect": expect, "planted": expect.get("car-mileage") is True or expect.get("toyota-lineup") is True
                    or expect.get("vintage-age") is True or expect.get("car-mileage/alone") is True})
    return {"today": TODAY, "lineup": line, "cars": out}


# ------------------------------------------------------------------------------------------------ votes

def ordinal(n):
    return "%d%s" % (n, "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th"))


def short_name(bioname):
    """Voteview's "CARTWRIGHT, Matthew Alton" as the name a reporter writes: Matt Cartwright."""
    last, first = bioname.split(",", 1)
    first = re.sub(r"\(([^)]+)\)", r"\1", first).split()
    nick = re.search(r"\(([^)]+)\)", bioname)
    given = nick.group(1) if nick else first[0]
    last = " ".join(w.capitalize() if not w.startswith("MC") else "Mc" + w[2:].capitalize() for w in last.split())
    return f"{given} {last}"


NAMES = {  # the names the members go by, where Voteview's first name isn't it
    "FITZPATRICK": "Brian Fitzpatrick", "BOYLE": "Brendan Boyle", "EVANS": "Dwight Evans", "DEAN": "Madeleine Dean",
    "SCANLON": "Mary Gay Scanlon", "HOULAHAN": "Chrissy Houlahan", "WILD": "Susan Wild", "CARTWRIGHT": "Matt Cartwright",
    "MEUSER": "Dan Meuser", "PERRY": "Scott Perry", "SMUCKER": "Lloyd Smucker", "LEE": "Summer Lee",
    "JOYCE": "John Joyce", "RESCHENTHALER": "Guy Reschenthaler", "THOMPSON": "Glenn Thompson", "KELLY": "Mike Kelly",
    "DELUZIO": "Chris Deluzio",
}


def clean(text):
    text = html.unescape(re.sub(r"<[^>]+>", " ", text or ""))
    return re.sub(r"\s+", " ", text).strip()


def overview(summary_text, title, limit=520):
    """The CRS summary's overview (from "This bill" or "This act"), else its opening after the bill's name, cut to
    whole sentences within `limit`."""
    t = clean(summary_text)
    m = re.search(r"\bThis (bill|act|joint resolution)\b", t)
    if m and m.start() < 400:
        t = t[m.start():]
        t = re.split(r"\s(?=DIVISION [A-Z]+\b|TITLE [IVX]+\b|Sec\. \d)", t)[0]
    elif re.search(r"DIVISION [A-Z]+--", t):
        heads = re.findall(r"DIVISION [A-Z]+--(.+?)(?=\s+(?:[A-Z][a-z]|\(Sec|TITLE ))", t)
        parts = [re.sub(r"\bamerican\b", "American", h.strip().rstrip(",").capitalize()) for h in heads]
        t = "Its divisions: " + "; ".join(parts) + "." if parts else t
    elif t.lower().startswith(title.lower()):
        t = t[len(title):].strip()
        t = re.sub(r"\s*\(Sec\. \d+\)\s*", " ", t)
    sentences = re.split(r"(?<=[.;])\s+", t)
    out = ""
    for s_ in sentences:
        if len(out) + len(s_) + 1 > limit:
            break
        out = (out + " " + s_).strip()
    return out or t[:limit].rsplit(" ", 1)[0] + "…"


def bill_words(data, b, date):
    path = os.path.join(data, "crs", f"{b['bill']}.json")
    if not os.path.exists(path):
        return None, None
    with open(path) as f:
        got = json.load(f)
    sums = sorted(got.get("summaries") or [], key=lambda s: s.get("actionDate", ""))
    before = [s for s in sums if s.get("actionDate", "") <= date] or sums
    if before:
        return overview(before[-1]["text"], b["title"]), "CRS summary (congress.gov)"
    wiki = got.get("wikipedia")
    if wiki and wiki.get("extract"):
        return overview(wiki["extract"], b["title"]), "Wikipedia"
    return None, None


def census_cards(data):
    with open(os.path.join(data, "census", "pa.json")) as f:
        got = json.load(f)
    release = got["release"]["name"]
    out = {}
    for geo, tables in got["data"].items():
        n = int(geo[-2:])
        e = {t: v["estimate"] for t, v in tables.items()}
        def share(t, num, den):
            nums = [e[t][c] for c in num]
            return 100.0 * sum(nums) / e[t][den]
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
        out[n] = {"cards": cards, "source": f"Census Bureau, American Community Survey ({release}), via Census Reporter"}
    return out


def votes(data):
    roll = {r["rollnumber"]: r for r in csv.DictReader(open(os.path.join(data, "H118_rollcalls.csv")))}
    members = {r["icpsr"]: r for r in csv.DictReader(open(os.path.join(data, "H118_members.csv")))
               if r["chamber"] == "House" and r["state_abbrev"] == "PA"}
    wanted = {b["roll"] for b in BILLS}
    cast = defaultdict(dict)
    for v in csv.DictReader(open(os.path.join(data, "H118_votes.csv"))):
        if v["rollnumber"] in wanted and v["icpsr"] in members:
            cast[v["rollnumber"]][v["icpsr"]] = (int(v["cast_code"]), float(v["prob"]) if v["prob"] else None)
    census = census_cards(data)
    out_members = []
    for icpsr, m in sorted(members.items(), key=lambda kv: int(kv[1]["district_code"])):
        n = int(m["district_code"])
        last = m["bioname"].split(",")[0]
        with open(os.path.join(data, "wiki", f"PA-{n}.json")) as f:
            wiki = json.load(f)
        out_members.append({"icpsr": icpsr, "title": NAMES.get(last, short_name(m["bioname"])),
                            "party": "D" if m["party_code"] == "100" else "R", "district": f"PA-{n}",
                            "districtTitle": f"PA-{n}", "place": clean(wiki["extract"]), "placeSource": wiki.get("url"),
                            "figures": census[n]["cards"], "figuresSource": census[n]["source"]})
    out_bills, out_votes = [], []
    for b in BILLS:
        r = roll[b["roll"]]
        words, source = bill_words(data, b, r["date"])
        result = ("Passed" if r["vote_result"] in ("Passed", "Agreed to") else "Failed") + f" {r['yea_count']}–{r['nay_count']}"
        number = re.sub(r"^HR", "H.R. ", b["bill"])
        out_bills.append({"title": b["title"], "number": number, "date": r["date"], "result": result,
                          "words": words, "wordsSource": source, "roll": b["roll"]})
        for m in out_members:
            c = cast[b["roll"]].get(m["icpsr"])
            if not c or c[0] not in (1, 2, 3, 4, 5, 6):
                continue
            position = "Yea" if c[0] <= 3 else "Nay"
            out_votes.append({"member": m["title"], "bill": b["title"], "position": position,
                              "nominate": c[1], "expect": {"vote-record": (c[1] < 50) if c[1] is not None else None}})
    return {"members": out_members, "bills": out_bills, "votes": out_votes}


if __name__ == "__main__":
    data, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    c = cars(data)
    with open(os.path.join(out, "cars.json"), "w") as f:
        json.dump(c, f, indent=1, ensure_ascii=False)
    v = votes(data)
    with open(os.path.join(out, "votes.json"), "w") as f:
        json.dump(v, f, indent=1, ensure_ascii=False)
    flagged = sum(1 for x in v["votes"] if x["expect"]["vote-record"])
    print(f"cars: {len(c['cars'])} ({sum(x['planted'] for x in c['cars'])} planted), lineup {len(c['lineup'])} models")
    print(f"votes: {len(v['members'])} members, {len(v['bills'])} bills ({sum(1 for b in v['bills'] if b['words'])} with words), "
          f"{len(v['votes'])} votes, {flagged} unusual for the record by Voteview")
