"""Infinite Canvas drawn as its module graph: the default lens, with the root laid out as Package.swift lays the graph out.

The root holds the graph's three rungs as bands stacked top to bottom (product, platform, core). The platform band holds
a frame for each group Package.swift heads its platform modules with, and the core band is one row. Every module's board is
the default lens's: its files as notes in frames by folder, and which file uses which as an arrow or a pill.

What its conventions don't read:
- A platform module's group is the last heading comment above its line in Package.swift (`// Engines: ...`) that is one
  of PLATFORM_GROUPS's. A platform module under no such heading stays loose in the platform band, and is warned.
- A module's rung is its `// layer:` tag, as the scanner reads it. A module whose tag is none of RUNGS goes where the
  default lens puts a module the bands leave out (its tag's band, else "Other modules" at the bottom), and is warned.
"""
import re

from lenskit import default

# Rule "rungs-stacked-in-order": the root's bands are the module graph's rungs, top to bottom product, platform, core:
# a rung imports only from those below it (the window and the programs are the core's private modules, so core's). Why:
# "the layers should be stacked atop each other in order" (the owner, round 1); the default lens orders bands by how deep
# their imports go, which for this graph puts platform above product. That the bands run as rows is the `ranks` setting
# in .canvas/ingest.json.
RUNGS = ("product", "platform", "core")

# Rule "platform-in-groups": the platform band holds a frame for each group Package.swift heads its platform modules with,
# titled as below. Why: platform is the biggest band (33 cards in one frame) and "would benefit from frames inside it"
# (the owner, round 1). The groups are the code's own: the headings over the platform targets in Package.swift.
PLATFORM = "platform"
PLATFORM_GROUPS = (
    ("Horizontals, in the window", "Horizontals: in the window"),
    ("Horizontals, shape traits", "Horizontals: shape traits"),
    ("Things you do", "Things you do"),
    ("Engines", "Engines"),
    ("For agents", "For agents"),
)

# Rule "core-in-a-row": the core band's cards lie in one row, left to right by title. Why: "the core layer should be more
# horizontal" (the owner, round 2): laid out by its few arrows, core came out a block of three by three in the middle of a
# band as wide as platform's. Only core: the other bands' cards are the layout's to arrange, in a line or not ("abandoning
# the linear nature of the sub-boards, they could have other configurations", the owner, round 3, who took back round 2's
# frame for each card).
IN_A_ROW = ("core",)

PACKAGE = "Package.swift"
HEADING = re.compile(r"^\s*//\s*([^:]+):")
TARGET = re.compile(r'^\s*\.(?:executableTarget|target)\(name:\s*"([^"]+)"')


def band_title(rung):
    return f"{rung[0].upper()}{rung[1:]} layer"


def headings(package):
    """{module: heading} for each target line under one of PLATFORM_GROUPS's headings: the last such heading above it,
    until a rung's own heading (`// PRODUCT: ...`, in capitals) ends it. Other comments (a module's own) change nothing."""
    known = {heading for heading, _ in PLATFORM_GROUPS}
    out, current = {}, None
    for line in package.splitlines():
        comment = HEADING.match(line)
        if comment:
            lead = comment.group(1).strip()
            if lead in known:
                current = lead
            elif lead.isupper():
                current = None
            continue
        target = TARGET.match(line)
        if target and current:
            out[target.group(1)] = current
    return out


def digest(scan, repo):
    layer = {m: scan.modules[m].get('layer') for m in scan.production}
    bands = [(band_title(rung), [m for m in scan.production if layer[m] == rung]) for rung in RUNGS]
    bands = [band for band in bands if band[1]]
    d = default.build(scan, repo, bands=bands)       # unfinished: the ids finish() gives, below, say where the cards ended up
    nodes = d.nodes

    # each rung's band: the frame on the root whose rank is the band's place among them (the default lens's), and the
    # module cards in it, by module (a card's source is its module's folder)
    band = {}
    for rank, (title, _) in enumerate(bands):
        rung = next(r for r in RUNGS if band_title(r) == title)
        band[rung] = next((n for n in nodes if n.get('kind') == 'frame' and 'in' not in n and n.get('rank') == rank), None)
    module_at = {scan.modules[m].get('path'): m for m in scan.production}
    card = {module_at[n['source']]: n for n in nodes if n.get('kind') == 'subboard' and n.get('source') in module_at}

    def frames(into, wanted):
        """New frames in the frame `into`, [(what, title)] in order, placed after it in the node list."""
        made = [{'title': title, 'kind': 'frame', 'in': into} for _, title in wanted]
        at = next(i for i, n in enumerate(nodes) if n is into) + 1
        nodes[at:at] = made
        return made

    # platform-in-groups
    if band.get(PLATFORM):
        into = band[PLATFORM]
        platform = [m for m in scan.production if layer[m] == PLATFORM and m in card]
        group_of = headings(repo.read(PACKAGE))
        wanted = [(h, d.claim(f"the group {h}", t, f"{t} ({into['title']})", within=into))
                  for h, t in PLATFORM_GROUPS if any(group_of.get(m) == h for m in platform)]
        frame = dict(zip([h for h, _ in wanted], frames(into, wanted)))
        for m in platform:
            if m in group_of:
                card[m]['in'] = frame[group_of[m]]
            else:
                d.warn(f"{m} is under no heading of {PACKAGE} that names a group: it stays loose in {into['title']}")

    # core-in-a-row
    for rung in IN_A_ROW:
        if band.get(rung):
            for node in nodes:
                if node.get('in') is band[rung]:
                    node['rank'] = 0
    return d.finish()
