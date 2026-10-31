#!/usr/bin/env python3
"""Draw the prototype's two boards into a running app with `canvas draw`, as an agent or a lens would:

    python3 boards.py BOARDS CANVAS [--dry-run]

BOARDS is the folder prepare.py wrote (cars.json, votes.json); CANVAS the `canvas` to run (this worktree's
build/canvas, with CANVAS_SOCKET pointing at a test copy of the app). Makes BOARDS/Cars.canvasboard and
BOARDS/Votes.canvasboard (`canvas new`) and draws each in runs of one board each. The rules are written into the
types' schemas as `$rules`, each a sentence and, for a phrase that reaches further than one step, its query: what the
feature would store, written the way `canvas draw` writes any schema.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import listings  # noqa: E402

# The rules as stored. A chip is a phrase of the sentence and the query that finds it, with :scope for the shape
# being checked and :scope-start / :scope-end for an arrow's ends.
CAR_RULES = [{"says": "The mileage is implausible for the car's age."}]
TOYOTA_RULES = [{"says": "This model wasn't made in this year, per the Toyota lineup.",
                 "find": {"the Toyota lineup": "subboard\"Toyota lineup\" *"}}]
VINTAGE_RULES = [{"says": "Mileage doesn't matter for a vintage car."},
                 {"says": "It's less than 25 years old."}]
VOTE_RULES = [{"says": "Unusual for the member's record."},
              {"says": "Unusual for someone representing the member's district.",
               "find": {"the member's district": "subboard:edge-from(:scope-start) *"}}]


def q(text):
    """A draw string: quoted, with a backslash and a quote escaped."""
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def schema(properties, required=(), rules=None):
    props = {}
    if rules:
        props["$rules"] = {"const": rules}
    props.update(properties)
    s = {"type": "object", "properties": props}
    if required:
        s["required"] = list(required)
    return json.dumps(s, ensure_ascii=False)


def values(v):
    return json.dumps(v, ensure_ascii=False)


# ------------------------------------------------------------------------------------------------ cars

def cars_runs(c):
    runs = []
    car = schema({"year": {"type": "integer"}, "make": {"type": "string"}, "model": {"type": "string"},
                  "mileage": {"type": "integer", "minimum": 0}}, ("year", "make", "model"), CAR_RULES)
    toyota = schema({}, rules=TOYOTA_RULES)
    vintage = schema({}, rules=VINTAGE_RULES)
    model = schema({"years": {"type": "string"}}, ("years",))
    runs.append(("types", "\n".join([
        f'sticky-note "Car" schema: {q(car)} text: "A car: its year, make, model and the miles on it."',
        f'sticky-note "Toyota" below-left of "Car" (gap: wide) is: "Car" schema: {q(toyota)} text: "A car Toyota made."',
        f'sticky-note "Vintage" below-right of "Car" (gap: wide) is: "Car" schema: {q(vintage)} text: "A collector\'s car, at least 25 years old."',
        f'subboard "Toyota lineup" right of "Car" (gap: 600) description: "Every Toyota model sold in the US and its model years, from the EPA\'s fuel economy data (fueleconomy.gov)."',
        f'sticky-note "Model" right of "Toyota lineup" (gap: wide) schema: {q(model)} text: "A Toyota model and the years it was sold in the US."',
    ])))
    lines = []
    for i, m in enumerate(c["lineup"]):
        place = "" if i == 0 else (f'below "{c["lineup"][i - 1]["model"]}"' if i % 10 else f'right of "{c["lineup"][i - 10]["model"]}"')
        lines.append(f'sticky-note {q(m["model"])} in "Toyota lineup" {place} is: "Model" fieldValues: {values({"years": m["years"]})}')
    runs.append(("lineup", "\n".join(lines)))
    lines = []
    for i, car_ in enumerate(c["cars"]):
        if i == 0:
            place = 'below "Toyota" (gap: 160)'
        elif i % 6:
            place = f'right of {q(c["cars"][i - 1]["title"])}'
        else:
            place = f'below {q(c["cars"][i - 6]["title"])}'
        lines.append(f'sticky-note {q(car_["title"])} {place} is: {q(car_["type"])} fieldValues: {values(car_["values"])}')
    runs.append(("cars", "\n".join(lines)))
    return runs


# ------------------------------------------------------------------------------------------------ votes

def votes_runs(v):
    runs = []
    member = schema({"party": {"type": "string", "enum": ["D", "R"]}, "district": {"type": "string"}}, ("party", "district"))
    vote = schema({"position": {"type": "string", "enum": ["Yea", "Nay"]}}, ("position",), VOTE_RULES)
    bill = schema({"number": {"type": "string"}, "date": {"type": "string", "format": "date"}, "result": {"type": "string"}}, ("number", "date"))
    figure = schema({"value": {"type": "string"}, "source": {"type": "string"}}, ("value",))
    place = schema({})
    runs.append(("types", "\n".join([
        f'sticky-note "Member" schema: {q(member)} text: "A member of the House from Pennsylvania: their party and district."',
        f'sticky-note "Vote" right of "Member" (gap: 360) relationship: true schema: {q(vote)} text: "How a member voted on a bill: Yea or Nay."',
        f'sticky-note "Bill" right of "Vote" (gap: 360) schema: {q(bill)} text: "A bill the House voted on, in a sentence or two."',
        f'sticky-note "Figure" right of "Bill" (gap: wide) schema: {q(figure)} text: "A figure about a district, and where it comes from."',
        f'sticky-note "Place" right of "Figure" schema: {q(place)} text: "Where a district is, and what\'s in it."',
        'edge "Member" -> "Vote"',
        'edge "Vote" -> "Bill"',
    ])))
    lines = []
    for i, m in enumerate(v["members"]):
        place = 'below "Member" (gap: 200)' if i == 0 else f'below {q(v["members"][i - 1]["title"])}'
        lines.append(f'sticky-note {q(m["title"])} {place} is: "Member" fieldValues: {values({"party": m["party"], "district": m["district"]})}')
    for i, b in enumerate(v["bills"]):
        place = 'below "Bill" (gap: 200)' if i == 0 else f'below {q(v["bills"][i - 1]["title"])}'
        vals = {"number": b["number"], "date": b["date"], "result": b["result"]}
        text = f' text: {q(b["words"])}' if b.get("words") else ""
        lines.append(f'sticky-note {q(b["title"])} {place} is: "Bill" fieldValues: {values(vals)}{text}')
    runs.append(("members and bills", "\n".join(lines)))
    lines = []
    for m in v["members"]:
        lines.append(f'subboard {q(m["district"])} left of {q(m["title"])} (gap: wide) description: {q("Pennsylvania congressional district. Figures: " + m["figuresSource"] + ". Description: Wikipedia.")}')
    for m in v["members"]:
        lines.append(f'edge {q(m["title"])} -> {q(m["district"])}')
    runs.append(("districts", "\n".join(lines)))
    for m in v["members"]:
        lines = [f'sticky-note "About {m["district"]}" in {q(m["district"])} is: "Place" text: {q(m["place"])}']
        prev = f'About {m["district"]}'
        for j, (measure, value) in enumerate(m["figures"]):
            place = f'right of {q(prev)}' if j == 0 else (f'below {q(m["figures"][j - 1][0])}' if j % 6 else f'right of {q(m["figures"][j - 6][0])}')
            lines.append(f'sticky-note {q(measure)} in {q(m["district"])} {place} is: "Figure" fieldValues: {values({"value": value, "source": "ACS 2024 1-year"})}')
        runs.append((f"cards of {m['district']}", "\n".join(lines)))
    lines = [f'edge {q(x["member"])} -> {q(x["bill"])} is: "Vote" fieldValues: {values({"position": x["position"]})}' for x in v["votes"]]
    runs.append(("votes", "\n".join(lines)))
    return runs


# ------------------------------------------------------------------------------------------------ listings

def listings_runs():
    car = schema({"year": {"type": "integer"}, "make": {"type": "string"}, "model": {"type": "string"},
                  "mileage": {"type": "integer", "minimum": 0}}, ("year", "make", "model"))
    listing = schema({}, rules=listings.LISTING_RULES)
    vintage = schema({}, rules=listings.VINTAGE_RULES)
    runs = [("types", "\n".join([
        f'sticky-note "Car" schema: {q(car)} text: "A car: its year, make, model and the miles on it."',
        f'sticky-note "Listing" below-left of "Car" (gap: wide) is: "Car" schema: {q(listing)} text: "A car for sale, described by its seller."',
        f'sticky-note "Vintage" below-right of "Car" (gap: wide) is: "Car" schema: {q(vintage)} text: "A collector\'s car, at least 25 years old."',
    ]))]
    lines = []
    rows = listings.LISTINGS
    for i, (title, types, year, make, model, miles, words, _, _) in enumerate(rows):
        if i == 0:
            place = 'below "Listing" (gap: 160)'
        elif i % 4:
            place = f'right of {q(rows[i - 1][0])}'
        else:
            place = f'below {q(rows[i - 4][0])}'
        is_ = q(types[0]) if len(types) == 1 else json.dumps(types)
        vals = {"year": year, "make": make, "model": model, "mileage": miles}
        lines.append(f'sticky-note {q(title)} {place} size: 300x is: {is_} fieldValues: {values(vals)} text: {q(words)}')
    runs.append(("listings", "\n".join(lines)))
    return runs


# ------------------------------------------------------------------------------------------------ running

def canvas(cli, *args, stdin=None):
    p = subprocess.run([cli, *args], input=stdin, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"canvas {' '.join(args[:2])} failed ({p.returncode}): {p.stderr.strip()[:2000]}")
    return json.loads(p.stdout) if p.stdout.strip() else None


def board(cli, path):
    for b in canvas(cli, "boards"):
        if b.get("file") == path or b.get("name") == os.path.splitext(os.path.basename(path))[0]:
            return b["id"]
    return canvas(cli, "new", path)["id"]


def draw(cli, board_id, runs, dry):
    for name, script in runs:
        args = ["draw", "--board", str(board_id), "--timeout", "120"] + (["--dry-run"] if dry else []) + ["-"]
        out = canvas(cli, *args, stdin=script)
        warnings = out.get("warnings") or []
        did = {}
        for c in out.get("changes", []):
            did[c["did"]] = did.get(c["did"], 0) + 1
        print(f"  {name}: {did}" + (f", {len(warnings)} warnings: {warnings[:3]}" if warnings else ""))


if __name__ == "__main__":
    folder, cli = sys.argv[1], sys.argv[2]
    dry = "--dry-run" in sys.argv
    only = [a for a in sys.argv[3:] if not a.startswith("--")]
    with open(os.path.join(folder, "cars.json")) as f:
        cars = json.load(f)
    with open(os.path.join(folder, "votes.json")) as f:
        votes = json.load(f)
    for title, runs in (("Cars", cars_runs(cars)), ("Votes", votes_runs(votes)), ("Listings", listings_runs())):
        if only and title not in only:
            continue
        bid = board(cli, os.path.join(folder, f"{title}.canvasboard"))
        print(f"{title} (board {bid})")
        draw(cli, bid, runs, dry)
