"""The plan's running example: car listings, where a seller's words are checked against the car's own values, a
judgment no formula makes. The cars' years, makes and models are real ones (the EPA's); the sellers' words and the
mileage are written for the example, and each listing is labeled with what each rule should say of it.

Listing builds on Car; Vintage builds on Car and says, in words, how to read Listing's second rule for a car of its
kind. A listing for a vintage car is both (`is: ["Listing", "Vintage"]`), so its rules are read together. Rules are
worded as what should be true (the prototype's finding: worded as a flag, a rule that qualifies another reads as a
flag itself).
"""

LISTING_RULES = [
    {"says": "The description agrees with the car's year, model and mileage."},
    {"says": "The description mentions no damage or wear."},
]
VINTAGE_RULES = [
    {"says": "Wear and patina are expected on a vintage car."},
]

RULE_IDS = {
    "The description agrees with the car's year, model and mileage.": "listing-agrees",
    "The description mentions no damage or wear.": "listing-no-damage",
    "Wear and patina are expected on a vintage car.": "vintage-patina",
    'For a vintage car, the description may mention wear and patina.': "vintage-patina",
    "On a vintage car, wear and patina don't count as damage.": "vintage-patina",
}

# (title, types, year, make, model, mileage, the seller's words, which rules it breaks read together, and alone)
LISTINGS = [
    ("2021 Toyota Corolla LE", ["Listing"], 2021, "Toyota", "Corolla", 412000,
     "Barely driven, garage kept, like new inside and out.", {"listing-agrees"}, set()),
    ("2019 Toyota Camry SE", ["Listing"], 2019, "Toyota", "Camry", 61000,
     "One owner, dealer serviced, 61k mostly highway miles.", set(), set()),
    ("2015 Toyota RAV4 XLE", ["Listing"], 2015, "Toyota", "RAV4", 118000,
     "Runs and drives great. Small dent in the rear bumper, otherwise clean.", {"listing-no-damage"}, set()),
    ("2022 Toyota Tacoma TRD", ["Listing"], 2022, "Toyota", "Tacoma", 31000,
     "Clean 2019 Tacoma with low miles and a new set of tires.", {"listing-agrees"}, set()),
    ("2010 Toyota Prius", ["Listing"], 2010, "Toyota", "Prius", 214000,
     "High miles, but the hybrid battery was replaced in 2023. Starts every time.", set(), set()),
    ("2018 Honda Civic EX", ["Listing"], 2018, "Honda", "Civic", 74000,
     "Accident-free, 47,000 miles, new brakes.", {"listing-agrees"}, set()),
    ("2005 Honda Accord", ["Listing"], 2005, "Honda", "Accord", 248000,
     "Old but reliable at 248k. Some rust on the wheel wells and a cracked windshield.", {"listing-no-damage"}, set()),
    ("2014 Jeep Wrangler", ["Listing"], 2014, "Jeep", "Wrangler", 140000,
     "Lifted, 140k, minor scratches from trail use.", {"listing-no-damage"}, set()),
    ("2023 Ford F-150 XLT", ["Listing"], 2023, "Ford", "F-150", 26000,
     "Like new, only 2,600 miles.", {"listing-agrees"}, set()),
    ("1967 Ford Mustang Coupe", ["Listing", "Vintage"], 1967, "Ford", "Mustang", 96000,
     "Original paint with honest patina and some surface rust on the rockers. Numbers-matching 289.", set(), {"listing-no-damage"}),
    ("1985 Porsche 911 Carrera", ["Listing", "Vintage"], 1985, "Porsche", "911", 61000,
     "Collector-owned, 61,000 miles, a few stone chips on the nose, otherwise excellent.", set(), {"listing-no-damage"}),
    ("1972 Volkswagen Beetle", ["Listing", "Vintage"], 1972, "Volkswagen", "Beetle", 88000,
     "Restored in 2019: new interior, no rust, runs strong.", set(), set()),
]


def labels():
    """The evals' labels: for each listing, whether each rule should flag it (read together; `/alone` read alone)."""
    out = []
    for title, types, year, make, model, miles, words, breaks, alone in LISTINGS:
        expect = {"listing-agrees": "listing-agrees" in breaks, "listing-no-damage": "listing-no-damage" in breaks}
        if "Vintage" in types:
            expect["listing-no-damage/alone"] = "listing-no-damage" in (breaks | alone)
        out.append({"title": title, "type": types, "values": {"year": year, "make": make, "model": model, "mileage": miles},
                    "words": words, "expect": expect})
    return out
