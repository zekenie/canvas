"""Infinite Canvas drawn as its module graph, with its plugin system in types.

The root holds the graph's three rungs as bands stacked top to bottom (product, platform, core). The platform band holds
a frame for each group Package.swift heads its platform modules with, and the core band is two rows, its libraries above its
private modules. Every module's board is the default lens's: its files as notes in frames by folder, and which file uses which
as an arrow or a pill.

The plugin system is drawn in types, the guide's nouns (docs/plugin-system.md): every plugin, extension point, kind and added
property is a note of its type, in the type's color, in a frame on the board that holds the note of the file it is declared
in. A plugin declares the extension points it owns, the kinds it defines and the properties it adds, and fills extension
points; a kind holds properties: each an arrow of its relationship type, in that type's color. The types are a frame at the
bottom of the root. Which plugin declares, fills and holds what is read from the registry's report in the guide, which
ShippedTests holds to the registry as it is; what each thing is, from the Swift declarations.

What its conventions don't read:
- A platform module's group is the last heading comment above its line in Package.swift (`// Engines: ...`) that is one
  of PLATFORM_GROUPS's. A platform module under no such heading stays loose in the platform band, and is warned.
- A module's rung is its `// layer:` tag, as the scanner reads it. A module whose tag is none of RUNGS goes where the
  default lens puts a module the bands leave out (its tag's band, else "Other modules" at the bottom), and is warned.
- A core module is private when its target's line in Package.swift tags it so (`// layer: core private`). A tag on a line
  of its own is not read, and its module goes in the libraries' row.
- A thing is found by how this code declares one: a plugin by its line in `let ships` and its type's `var id`, an extension
  point by a conformance to `ExtensionPoint` or `KeyedExtensionPoint`, a kind by its props' `static let kind`, a property by
  a conformance to `ShapeProperty` and its `static let key`. One declared another way (through a typealias, a macro, a
  declaration split over lines) is not found; a line of the report that names a kind, a property or a plugin the code
  doesn't declare so is warned. Which kinds a property opted into every shape reaches is its `where:` condition read as
  capabilities a kind's definition adopts or doesn't (`!($0 is any NeverPublic)`); a condition of another form is warned, and
  every kind holds the property on the board.
- Which point a line of the report fills is read from how each point words its contributions: the first string of its
  `summary` (an interpolation in it matching anything), the core's words for its own points in Registry.swift, else its
  name. A line no point's words fit, or two points' fit as well, is warned and drawn nowhere.
- A thing in a file the scan doesn't draw (a test module's) is warned and left out.
"""
import re

from lenskit import default
from lenskit.text import as_text

# ---- the rules -----------------------------------------------------------------------------------------------------------

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

# Rule "core-in-rows": the core band's cards lie in two rows, each left to right by title: its libraries, then below them its
# private modules (the window and the programs, whose `// layer:` tag says `private`). Why: "the core layer should be more
# horizontal" (the owner, round 2): laid out by its few arrows, core came out a block of three by three in the middle of a
# band as wide as platform's. Then the private modules joined the core (7696847f), and in one row of twelve their arrows to
# the libraries ran along it, through the cards between: "private on bottom makes a lot more sense visually" (the owner,
# round 5). Only core: the other bands' cards are the layout's to arrange, in a line or not ("abandoning the linear nature
# of the sub-boards, they could have other configurations", the owner, round 3, who took back round 2's frame for each card).
IN_ROWS = ("core",)

# Rule "plugin-system-in-types": the plugin system's things are notes of four types, Plugin, Extension point, Kind and
# Property (the guide's nouns, a kind's definition among its values, and the added properties kinds opt into), and how
# they connect is arrows of three relationship types: a plugin declares (an extension point it owns, a kind it defines, a
# property it adds), a plugin fills (an extension point), a kind holds (a property). Why: "make use of types (with colors)
# to describe things and the relationship between them" (the owner, round 4). The types are TYPES, RELATIONSHIPS and ENDS.

# Rule "a-color-a-type": each type and relationship type has a color of its own, written in its schema (`$color`), which its
# notes and its arrows are drawn in. Why: "types (with colors)" (the owner, round 4); which color is which is the lens's
# pick, each kind of thing apart from the yellow of a file's note. The colors are TYPES' and RELATIONSHIPS' second members.

# Rule "the-report-says-who-adds-what": which plugin declares, fills and holds what is read from the registry's report,
# the block of docs/plugin-system.md that ShippedTests holds to the registry as it is, never worked out from which file
# uses which. A line of it fills the point whose words fit it best: the first string of the point's `summary`, the core's
# words for its own points (Registry.swift), else the point's name. Why: the report is exact, and most plugins fill a
# point through sugar, which the files' uses would only approximate (round 4's plan).
REPORT = "docs/plugin-system.md"
REPORT_LEAD = "`registry.report` prints who contributes what: the runtime half of the graph, pinned by a test.\n\n```\n"
CORE_WORDS = "Sources/Canvas/Plugins/Registry.swift"

# Rule "registrations-are-declares-and-holds": a line of the report that registers a kind (the core's Shapes point) or a
# property (PropertyDeclarations) is its plugin's declares, and one that opts a kind into a property (PropertyOptIns) is
# the kind's holds, its plugin the arrow's value; neither is drawn as a fills. A property opted into every shape is held by
# every kind its opt-in admits (`optInEveryShape(to:where:)`: the capabilities its condition says a kind adopts or doesn't). Why: a kind and a property are things on the board, and the point a plugin fills to make one is how the code
# says it (round 4's plan).
DECLARING = ("Shapes", "PropertyDeclarations")
HOLDING = "PropertyOptIns"

# Rule "one-fills-a-point": a plugin fills a point with one arrow, however many lines of the report it has there, and the
# lines are the arrow's values. Why: a plugin's eighteen shortcuts are one thing it does to Keyboard's point (round 4's plan).

# Rule "things-where-they-are-declared": a thing's note is in a frame, THINGS_FRAME, on the board that holds the note of the
# file it is declared in: a plugin's type, a point's type, a kind's props, a property's type; the core, which is no type, is
# where its registry is (CORE_AT). A relationship to a thing on another board is a pill there, as a use of its file is. The
# types are a frame at the bottom of the root (TYPES_FRAME: the module Types has the title "Types"). Why: a module's board
# shows what the module adds to the registry, and the 210 things and their 400 arrows on one board of their own wouldn't
# read (round 4's plan).
THINGS_FRAME = "Plugin system"
TYPES_FRAME = "Plugin system types"
CORE_AT = "Sources/Canvas/Plugins/Registry.swift"

# The longest a thing's note says of its doc comment, in characters: its first sentence, cut at a word past this.
DOC_MOST = 160

# ---- the types -------------------------------------------------------------------------------------------------------------

STRING = {"type": "string"}
STRINGS = {"type": "array", "items": STRING}
TYPES = {
    "Plugin": ("A plugin: a value that says what it adds when it registers. Its id is what the registry calls it.",
               "blue", {"id": STRING}),
    "Extension point": ("An extension point: a typed slot one plugin declares and others fill. Keyed when no two contributions "
                        "may claim one thing; its scope says which shapes its contributions may be for.",
                        "orange", {"keyed": {"type": "boolean"}, "scope": {"enum": ["anything", "scoped", "kinds"]}}),
    "Kind": ("A kind of shape: its props, named once, the definition that says how its shapes draw and behave, its version on a "
             "board, and the capabilities its definition adopts.",
             "green", {"props": STRING, "definition": STRING, "version": {"type": "integer"}, "capabilities": STRINGS}),
    "Property": ("An added property: a value the shapes of a kind hold once a plugin opts the kind in. Its type is the Swift type "
                 "that declares it.", "purple", {"type": STRING}),
}
RELATIONSHIPS = {
    "declares": ("A plugin declares an extension point it owns, a kind it defines, or a property it adds.", "indigo", {}),
    "fills": ("A plugin fills an extension point: what it adds there, as the registry's report says it.", "teal", {"adds": STRINGS}),
    "holds": ("A kind holds an added property, opted in by a plugin: its id.", "pink", {"by": STRING}),
}
# Each end: (from, to, the row it gives the notes at its far side, its rule)
ENDS = [("Plugin", "declares", "declares", None),
        ("declares", "Extension point", "declared by", {"needed": True, "onlyOne": True}),
        ("declares", "Kind", "declared by", {"needed": True, "onlyOne": True}),
        ("declares", "Property", "declared by", {"needed": True, "onlyOne": True}),
        ("Plugin", "fills", "fills", None),
        ("fills", "Extension point", "filled by", None),
        ("Kind", "holds", "holds", None),
        ("holds", "Property", "held by", None)]


def schema(color, properties):
    return {"type": "object", "properties": {"$color": {"const": color}, **properties}}


# ---- the root ----------------------------------------------------------------------------------------------------------------

PACKAGE = "Package.swift"
HEADING = re.compile(r"^\s*//\s*([^:]+):")
TARGET = re.compile(r'^\s*\.(?:executableTarget|target)\(name:\s*"([^"]+)"')
PRIVATE = re.compile(r"//\s*layer:\s*\w+\s+private\b")


def band_title(rung):
    return f"{rung[0].upper()}{rung[1:]} layer"


def private_modules(package):
    """The targets whose `// layer:` tag marks them private (`core private`, `core private of InfiniteCanvas`), which the
    scanner, reading a tag's first word, doesn't say."""
    out = set()
    for line in package.splitlines():
        target = TARGET.match(line)
        if target and PRIVATE.search(line):
            out.add(target.group(1))
    return out


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


# ---- reading Swift -------------------------------------------------------------------------------------------------------------

DECLARATION = re.compile(
    r"^(?P<indent>[ \t]*)(?:@\w+(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|internal|fileprivate|private|open|final|nonisolated|indirect)[ \t]+)*"
    r"(?P<what>enum|struct|class|actor|extension|protocol)[ \t]+(?P<name>[A-Za-z_][\w.]*)(?:<[^>\n]*>)?"
    r"(?:[ \t]*:[ \t]*(?P<conforms>[^{\n]*?))?[ \t]*(?:where[^{\n]*)?\{", re.M)
PLUGIN_ID = re.compile(r"static let (\w+)\s*:\s*PluginID\s*=\s*\"([^\"]+)\"")
PROPERTY_KEY = re.compile(r"static let (\w+)\s*:\s*PropertyKey\s*=\s*\"([^\"]+)\"")
ID = re.compile(r"var id\s*:\s*PluginID\s*\{\s*([^}]*?)\s*\}")
OWNER = re.compile(r"static (?:var|let) owner\s*:\s*PluginID\s*(?:\{\s*([^}]*?)\s*\}|=\s*([^\n]+))")
SCOPE = re.compile(r"static (?:var|let) scope\s*:\s*PointScope\s*(?:\{\s*\.(\w+)\s*\}|=\s*\.(\w+))")
CONTRIBUTION = re.compile(r"typealias Contribution\s*=\s*([^\n]+)")
KIND = re.compile(r"static let kind\s*:\s*ShapeKind\s*=\s*\"([^\"]+)\"")
KEY = re.compile(r"static let key\s*:\s*PropertyKey\s*=\s*(?:\"([^\"]+)\"|([\w.]+))")
DESCRIPTION = re.compile(r"\.description\(\"((?:[^\"\\]|\\.)*)\"")
REGISTERS = re.compile(r"registrar\.shape\(\s*(\w+)\s*\(")
EVERY_SHAPE = re.compile(r"optInEveryShape\(\s*to:\s*(\w+)\.self\s*(?:,\s*where:\s*\{(.*?)\}\s*)?\)", re.S)
SUMMARY = re.compile(r"static func summary\(of[^{]*?->\s*String\s*\{")


def skip_string(text, i):
    """The index after the one-line string literal that opens at text[i] (a quote), its interpolations skipped whole."""
    i += 1
    while i < len(text) and text[i] != "\n":
        if text.startswith("\\(", i):
            i = skip_parens(text, i + 2)
        elif text[i] == "\\":
            i += 2
        elif text[i] == '"':
            return i + 1
        else:
            i += 1
    return i


def skip_parens(text, i):
    """The index after the `)` that closes a parenthesis opened before text[i]."""
    depth = 1
    while i < len(text):
        if text[i] == '"':
            i = skip_string(text, i)
            continue
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def body_end(text, i):
    """The index after the `}` that closes a brace opened before text[i], with comments and strings passed over."""
    depth = 1
    while i < len(text):
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
            continue
        if text.startswith('"""', i):
            end = text.find('"""', i + 3)
            i = len(text) if end < 0 else end + 3
            continue
        if text[i] == '"':
            i = skip_string(text, i)
            continue
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def conformances(written):
    """The protocols a declaration's `:` list names, each by its last name: `@MainActor`, `any` and generic arguments off."""
    out, depth, part = [], 0, ""
    for ch in (written or "") + ",":
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        if ch == "," and depth == 0:
            name = re.sub(r"^(?:@\w+\s+|any\s+|some\s+)+", "", part.strip())
            name = name.split("<")[0].split(".")[-1].strip()
            if name:
                out.append(name)
            part = ""
        else:
            part += ch
    return out


def first_sentence(lines):
    """The first sentence of a doc comment's first paragraph, cut at a word past DOC_MOST characters."""
    words = []
    for line in lines:
        if not line:
            if words:
                break
            continue
        if line.startswith("- ") or line.startswith("```"):
            break
        words.append(line)
    text = " ".join(words)
    m = re.match(r"(.+?[.!?])(?:\s|$)", text)
    text = m.group(1) if m else text
    if len(text) > DOC_MOST:
        text = text[:DOC_MOST].rsplit(" ", 1)[0] + "…"
    return text


class Swift:
    """The declarations of the drawn files, read through `repo` (the commit): each type's and extension's name, what it
    conforms to, where it is, its body, and the doc comment over it."""

    def __init__(self, scan, repo):
        self.decls = []                 # in the files' order, then the text's
        self.texts = {}
        self.constants = {}             # a PluginID constant's name: {module: its value}
        self.keys = {}                  # a PropertyKey constant's name: its value
        for (module, _), f in sorted(scan.files.items()):
            path = f.get("path") or ""
            if not path.endswith(".swift"):
                continue
            text = repo.read(path)
            self.texts[path] = text
            lines = text.split("\n")
            for m in DECLARATION.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                self.decls.append({
                    "name": m.group("name").split(".")[-1], "what": m.group("what"), "conforms": conformances(m.group("conforms")),
                    "module": module, "path": path, "line": line, "body": text[m.end():body_end(text, m.end())],
                    "doc": self.doc(lines, line - 1)})
            for name, value in PLUGIN_ID.findall(text):
                self.constants.setdefault(name, {}).setdefault(module, value)
            for name, value in PROPERTY_KEY.findall(text):
                self.keys.setdefault(name, value)
        self.named = {}
        for decl in self.decls:
            self.named.setdefault(decl["name"], []).append(decl)

    @staticmethod
    def doc(lines, at):
        """The `///` comment over the declaration on lines[at], attributes on lines of their own between them."""
        j = at - 1
        while j >= 0 and re.match(r"\s*@\w", lines[j]):
            j -= 1
        block = []
        while j >= 0 and lines[j].strip().startswith("///"):
            block.append(lines[j].strip()[3:].strip())
            j -= 1
        return list(reversed(block))

    def of(self, name, module=None):
        """A type's declarations, its own and its extensions', in a module or in any."""
        return [d for d in self.named.get(name, []) if module is None or d["module"] == module]

    def primary(self, decls):
        """The declaration that makes the type (not an extension), else the first; and the first doc comment among them."""
        own = next((d for d in decls if d["what"] != "extension"), decls[0])
        doc = own["doc"] or next((d["doc"] for d in decls if d["doc"]), [])
        return own, first_sentence(doc)

    def plugin_id(self, expression, module):
        """A `PluginID` as code writes one: `.stickyNotes` (a constant), `"sticky-notes"`, `PluginID.core`. A constant is the one
        `module` declares, else the one module of any that does; one several other modules declare is none (it can't be told)."""
        expression = expression.strip()
        literal = re.fullmatch(r"\"([^\"]+)\"", expression)
        if literal:
            return literal.group(1)
        constant = re.fullmatch(r"(?:PluginID)?\.(\w+)", expression)
        found = self.constants.get(constant.group(1), {}) if constant else {}
        if module in found:
            return found[module]
        return next(iter(found.values())) if len(found) == 1 else None


def literal(text, i, name):
    """The one-line string literal that opens at text[i]: (a pattern of it, how many of its characters are fixed). An
    interpolation matches anything, but `\\(Self.self)`, which is the point's name."""
    out, fixed, i = [], 0, i + 1
    while i < len(text) and text[i] != "\n":
        if text.startswith("\\(", i):
            end = skip_parens(text, i + 2)
            if text[i + 2:end - 1].strip() == "Self.self":
                out.append(re.escape(name))
                fixed += len(name)
            else:
                out.append(".+?")
            i = end
            continue
        if text[i] == "\\":
            out.append(re.escape({"n": "\n", "t": "\t"}.get(text[i + 1:i + 2], text[i + 1:i + 2])))
            fixed, i = fixed + 1, i + 2
            continue
        if text[i] == '"':
            break
        out.append(re.escape(text[i]))
        fixed, i = fixed + 1, i + 1
    return "".join(out), fixed


def first_literal(text, name):
    """The pattern and fixed characters of the first string literal of `text`, comments left out; None for none, or one
    that starts with an interpolation (it fits anything)."""
    at, i = -1, 0
    while i < len(text):                  # the first quote that isn't in a `//` comment
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = len(text) if end < 0 else end
        elif text[i] == '"':
            at = i
            break
        else:
            i += 1
    if at < 0 or text.startswith("\\(", at + 1) and not text.startswith("\\(Self.self)", at + 1):
        return None
    return literal(text, at, name)


# ---- the plugin system -----------------------------------------------------------------------------------------------------------

class System:
    """The plugin system at the commit: its plugins, extension points, kinds and properties, and what declares, fills and
    holds what, from the report and the declarations. Whatever can't be read is said through `warn`."""

    def __init__(self, scan, repo, warn):
        self.warn = warn
        self.swift = Swift(scan, repo)
        self.report = self.read_report(repo)
        self.plugins = self.read_plugins(repo)                # plugin id: {title, decl, doc, path, line}
        self.points = self.read_points()                      # name: {decl, doc, owner, keyed, scope, path, line}
        self.words = self.read_words(repo)                    # [(pattern, fixed, point name)]
        self.kinds, self.properties = {}, {}                  # kind id / property key: their facts
        self.declares, self.fills, self.holds = [], {}, []    # (plugin, kind of thing, its key); (plugin, point): lines; (kind, key, plugin)
        self.read_lines()

    # -- the report: who contributes what --

    def read_report(self, repo):
        guide = repo.read(REPORT)
        start = guide.find(REPORT_LEAD)
        if start < 0:
            self.warn(f"{REPORT} has no registry report (\"{REPORT_LEAD.strip()[:40]}...\"): no plugin system is drawn")
            return []
        start += len(REPORT_LEAD)
        out = []
        for line in guide[start:guide.find("\n```", start)].split("\n"):
            head, _, rest = line.strip().partition(" ")
            if head:
                out.append((head, [item.strip() for item in rest.split(" · ") if item.strip()]))
        return out

    # -- the plugins: what ships, and the core --

    def read_plugins(self, repo):
        package = repo.read(PACKAGE)
        ships = re.search(r"^let ships = \[(.*?)^\]", package, re.M | re.S)
        listed = re.findall(r"\"([\w]+)\.([\w]+)\"", re.sub(r"//[^\n]*", "", ships.group(1))) if ships else []
        if not listed:
            self.warn(f"{PACKAGE} lists no plugin in `let ships`: no plugin is drawn")
        out = {}
        if CORE_AT in self.swift.texts:
            out["core"] = {"title": "core", "path": CORE_AT, "line": 1,
                           "doc": "The canvas itself: its registry, its hand tool and commands, and the extension points every plugin builds on."}
        for module, name in listed:
            decls = [d for d in self.swift.of(name, module) if d["what"] in ("struct", "class", "enum", "extension")]
            if not decls:
                self.warn(f"{PACKAGE} ships {module}.{name}, which no file of {module} the scan draws declares: left out")
                continue
            own, doc = self.swift.primary(decls)
            written = next((m.group(1) for d in decls for m in [ID.search(d["body"])] if m), None)
            pid = self.swift.plugin_id(written, module) if written else None
            if not pid:
                self.warn(f"{name} ({own['path']}) has no `var id: PluginID` this lens reads: left out")
                continue
            out[pid] = {"title": name, "path": own["path"], "line": own["line"], "doc": doc}
        reported = [pid for pid, _ in self.report]
        for pid in sorted(set(out) - set(reported)):
            self.warn(f"{out[pid]['title']} (id {pid}) is not in the registry report: it fills nothing on the board")
        for pid in [p for p in reported if p not in out]:
            self.warn(f"the registry report has a plugin {pid} that the code doesn't ship: its lines are left out")
        return out

    # -- the extension points --

    def read_points(self):
        out = {}
        for decl in self.swift.decls:
            if decl["what"] == "protocol" or not ({"ExtensionPoint", "KeyedExtensionPoint"} & set(decl["conforms"])):
                continue
            name = decl["name"]
            decls = self.swift.of(name, decl["module"])
            if name in out:
                if out[name]["decl"]["module"] != decl["module"]:
                    self.warn(f"two extension points are called {name} ({out[name]['path']}, {decl['path']}): the second is left out")
                continue
            own, doc = self.swift.primary(decls)
            owner = next((m.group(1) or m.group(2) for d in decls for m in [OWNER.search(d["body"])] if m), None)
            scope = next((m.group(1) or m.group(2) for d in decls for m in [SCOPE.search(d["body"])] if m), "anything")
            out[name] = {"decl": decl, "path": own["path"], "line": own["line"], "doc": doc, "decls": decls,
                         "owner": self.swift.plugin_id(owner, decl["module"]) if owner else None, "scope": scope,
                         "keyed": any("KeyedExtensionPoint" in d["conforms"] for d in decls)}
            if out[name]["owner"] is None:
                self.warn(f"the extension point {name} ({own['path']}) has an owner this lens doesn't read: no plugin declares it")
        return out

    # -- how each point words a contribution --

    def read_words(self, repo):
        words = []
        aliases = {}                     # a point's Contribution type, as written: the point
        for name, point in sorted(self.points.items()):
            for d in point["decls"]:
                m = CONTRIBUTION.search(d["body"])
                if m:
                    aliases.setdefault(" ".join(m.group(1).split()), name)
            bodies = "".join(x["body"] for x in point["decls"])
            constants = {m.group(1): m.end() - 1 for m in re.finditer(r"static let (\w+)\s*=\s*\"", bodies)}
            for d in point["decls"]:
                at = SUMMARY.search(d["body"])
                if not at:
                    continue
                body = re.sub(r"//[^\n]*", "", d["body"][at.end():body_end(d["body"], at.end())])
                # a constant named before any string (`{ label }`, `members.isEmpty ? label : label + ...`) is its words
                before = body.split('"')[0]
                named = next((m.group(1) for m in re.finditer(r"\b(\w+)\b", before) if m.group(1) in constants), None)
                found = first_literal(bodies[constants[named]:], name) if named else first_literal(body, name)
                if found:
                    words.append((found[0], found[1], name))
                else:
                    self.warn(f"the extension point {name} words its contributions in a way this lens doesn't read: only lines that start with its name fill it")
                break
        # the core's words for its own points' contributions, in RawContribution's switch
        text = repo.read(CORE_WORDS) if CORE_WORDS in self.swift.texts else ""
        start = text.find("summary = switch value {")
        switch = text[start:body_end(text, start + len("summary = switch value {"))] if start >= 0 else ""
        cases = list(re.finditer(r"^\s*case (?:let \w+ as ([^:\n]+)|is ([\w.]+?)(\.Type)?):", switch, re.M))
        for n, case in enumerate(cases):
            said = switch[case.end():cases[n + 1].start() if n + 1 < len(cases) else len(switch)]
            said = said.split("default:")[0]
            point = case.group(2).split(".")[-1] if case.group(3) else aliases.get(" ".join((case.group(1) or case.group(2)).split()))
            found = first_literal(said, point or "")
            if point in self.points and found:
                words.append((found[0], found[1], point))
            else:
                self.warn(f"{CORE_WORDS}: the core words a contribution (case {case.group(0).strip()}) for no point this lens reads")
        return [(re.compile("^" + pattern), fixed, name) for pattern, fixed, name in words]

    def point_of(self, line, plugin):
        """The point a line of the report fills: the one it starts with the name of, else the one whose words fit it with
        the most characters fixed. None, warned, for none or a tie."""
        head = line.split(" ")[0]
        if head in self.points:
            return head
        fits = sorted(((fixed, name) for pattern, fixed, name in self.words if pattern.match(line)), reverse=True)
        if not fits:
            self.warn(f"{plugin}'s \"{line}\" fills no extension point whose words this lens reads: left out")
            return None
        if len(fits) > 1 and fits[1][0] == fits[0][0] and fits[1][1] != fits[0][1]:
            self.warn(f"{plugin}'s \"{line}\" fits the words of {fits[0][1]} and {fits[1][1]} alike: left out")
            return None
        return fits[0][1]

    # -- the report's lines: declares, fills, holds --

    def read_lines(self):
        for pid, lines in self.report:
            if pid not in self.plugins:
                continue
            for line in lines:
                point = self.point_of(line, pid)
                if point is None:
                    continue
                if point == "Shapes":
                    m = re.fullmatch(r"shape (\S+)(?: v(\d+))?", line)
                    if m:
                        self.kinds.setdefault(m.group(1), {"by": pid, "version": int(m.group(2) or 0)})
                        self.declares.append((pid, "kind", m.group(1)))
                        continue
                elif point == "PropertyDeclarations":
                    m = re.fullmatch(r"property (\S+)(?: v\d+)?", line)
                    if m:
                        self.properties.setdefault(m.group(1), {"by": pid})
                        self.declares.append((pid, "property", m.group(1)))
                        continue
                elif point == HOLDING:
                    m = re.fullmatch(r"property (\S+) → (.+)", line)
                    if m:
                        self.holds.append((m.group(2), m.group(1), pid))
                        continue
                self.fills.setdefault((pid, point), []).append(line)
        for name, point in sorted(self.points.items()):
            if point["owner"] in self.plugins:
                self.declares.append((point["owner"], "point", name))
            elif point["owner"] is not None:
                self.warn(f"the extension point {name} is owned by {point['owner']}, which doesn't ship: no plugin declares it")
        self.read_kinds()
        self.read_properties()
        kinds = sorted(self.kinds)
        expanded = []
        for target, key, pid in self.holds:
            if key not in self.properties:
                self.warn(f"{pid} opts {target} into {key}, which no plugin declares: left out")
                continue
            reaches = self.every_shape(pid, key) if target == "every shape" else (lambda kind: True)
            for kind in (kinds if target == "every shape" else [target]):
                if kind not in self.kinds:
                    self.warn(f"{pid} opts {target} into {key}, and the code declares no such kind: left out")
                elif reaches(kind):
                    expanded.append((kind, key, pid))
        self.holds = expanded

    def every_shape(self, pid, key):
        """Which kinds a property opted into every shape reaches: those its `optInEveryShape(to:where:)` admits, read as the
        capabilities its condition says a kind's definition adopts or doesn't (`!($0 is any NeverPublic) && ...`); every kind
        when there is no condition, and when there is one this lens can't read (warned)."""
        plugin = self.plugins[pid]
        module = next((d["module"] for d in self.swift.of(plugin["title"])), None)
        paths = {d["path"] for d in self.swift.decls if d["module"] == module}
        texts = "".join(t for path, t in sorted(self.swift.texts.items()) if path in paths)
        clause = next((m for m in EVERY_SHAPE.finditer(texts) if m.group(1) == self.properties[key]["type"]), None)
        if clause is None:
            self.warn(f"{plugin['title']} opts every shape into {key}, and no `optInEveryShape(to: {self.properties[key]['type']}.self)` of its module says which kinds: every kind holds it on the board")
            return lambda kind: True
        if clause.group(2) is None:
            return lambda kind: True
        need, refuse = [], []
        for term in clause.group(2).split("&&"):
            m = re.fullmatch(r"\s*(!?)\s*\(?\s*\$0 is (?:any )?(\w+)\s*\)?\s*", term)
            if m is None:
                self.warn(f"{self.plugins[pid]['title']} opts every shape into {key} where {clause.group(2).strip()}, which this lens doesn't read: every kind holds it on the board")
                return lambda kind: True
            (refuse if m.group(1) else need).append(m.group(2))
        caps = lambda kind: set(self.kinds[kind].get("capabilities") or [])
        return lambda kind: not (caps(kind) & set(refuse)) and set(need) <= caps(kind)

    def read_kinds(self):
        for kind, facts in sorted(self.kinds.items()):
            props = next((d for d in self.swift.decls if d["what"] != "extension" and KIND.search(d["body"])
                          and KIND.search(d["body"]).group(1) == kind), None)
            if props is None:
                self.warn(f"no type of the drawn files says `static let kind: ShapeKind = \"{kind}\"`: the kind {kind} is left out")
                del self.kinds[kind]
                continue
            plugin = self.plugins[facts["by"]]
            bodies = "".join(d["body"] for d in self.swift.of(plugin["title"]))
            definitions = REGISTERS.findall(bodies)
            mine = [k for k, f in self.kinds.items() if f["by"] == facts["by"]]
            # the definition that draws these props (`ShapeRecord<StickyNote>`), else the one when the plugin registers one kind
            draws = [x for x in definitions if re.search(r"ShapeRecord<\s*" + re.escape(props["name"]) + r"\s*>", "".join(d["body"] for d in self.swift.of(x, props["module"])))]
            definition = draws[0] if len(set(draws)) == 1 else definitions[0] if len(definitions) == 1 and len(mine) == 1 else None
            if definition is None:
                self.warn(f"{plugin['title']} registers {len(definitions)} definitions for {len(mine)} kinds: the kind {kind}'s definition isn't said")
            capabilities = sorted(set(c for d in self.swift.of(definition or "", props["module"]) for c in d["conforms"]) - {"ShapeDefinition"})
            _, doc = self.swift.primary([props])
            facts.update({"props": props["name"], "definition": definition, "capabilities": capabilities,
                          "path": props["path"], "line": props["line"], "doc": doc})

    def read_properties(self):
        declared = [d for d in self.swift.decls if "ShapeProperty" in d["conforms"]]
        for key, facts in sorted(self.properties.items()):
            found = None
            for d in declared:
                m = KEY.search(d["body"])
                if m and (m.group(1) or self.swift.keys.get((m.group(2) or "").split(".")[-1])) == key:
                    found = d
                    break
            if found is None:
                self.warn(f"no `ShapeProperty` of the drawn files has the key {key}: the property {key} is left out")
                del self.properties[key]
                continue
            decls = self.swift.of(found["name"], found["module"])
            own, doc = self.swift.primary(decls)
            if not doc:
                described = DESCRIPTION.search(found["body"])
                doc = first_sentence([described.group(1)]) if described else ""
            facts.update({"type": found["name"], "path": own["path"], "line": own["line"], "doc": doc})


# ---- the digest ---------------------------------------------------------------------------------------------------------------

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

    # core-in-rows
    private = private_modules(repo.read(PACKAGE))
    for rung in IN_ROWS:
        if band.get(rung):
            for node in nodes:
                if node.get('in') is band[rung]:
                    node['rank'] = 1 if module_at.get(node.get('source')) in private else 0

    plugin_system(d, scan, repo, len(bands))
    return d.finish()


def plugin_system(d, scan, repo, below):
    """The plugin system in types: the types in a frame on the root, ranked `below` the bands, and each thing's note in a
    frame of the board its file is on, with the arrows of what declares, fills and holds what (plugin-system-in-types)."""
    system = System(scan, repo, d.warn)
    if not system.report:
        return

    # the types first: `is` names a type by its title, so each is unique among the types
    types = d.frame(d.claim("the frame of the types", TYPES_FRAME), rank=below)
    title = {t: d.claim(f"the type {t}", t, within=types, type=True) for t in list(TYPES) + list(RELATIONSHIPS)}
    type_note = {}
    for t, (words, color, properties) in TYPES.items():
        type_note[t] = d.note(title[t], types, words, schema=schema(color, properties))
    for t, (words, color, properties) in RELATIONSHIPS.items():
        type_note[t] = d.note(title[t], types, words, schema=schema(color, properties), relationship=True)
    for a, b, row, rule in ENDS:
        d.edge(type_note[a], type_note[b], text=row, **({"endRule": rule} if rule else {}))

    # the board each thing's file is on: the card its file's note is in, however deep in frames
    note_at = {n['source']: n for n in d.nodes if n.get('kind') == 'sticky-note' and isinstance(n.get('source'), str)}

    def board(path):
        node, at = note_at.get(path), path
        while node is None and "/" in at:     # a file of a folder drawn as one note: that note's board
            at = at.rpartition("/")[0]
            node = note_at.get(at)
        while node is not None and node.get('kind') != 'subboard':
            node = node.get('in') if isinstance(node.get('in'), dict) else None
        return node

    frame_on = {}                         # a board's card (by id): its frame of things

    def frame(card):
        if id(card) not in frame_on:
            frame_on[id(card)] = d.frame(d.claim(f"the plugin system of {card['title']}", THINGS_FRAME,
                                                 f"{THINGS_FRAME} ({card['title']})", within=card), card)
        return frame_on[id(card)]

    def thing(what, wanted, path, line, doc, kind, values):
        card = board(path)
        if card is None:
            d.warn(f"{what} is declared in {path}, which no board of the drawing holds: left out")
            return None
        holder = frame(card)
        return d.note(d.claim(what, wanted, f"{wanted} ({kind})", within=holder), holder, as_text(doc) if doc else None,
                      source={"path": path, "line": line},
                      **{"is": title[kind], "fieldValues": {k: v for k, v in values.items() if v not in (None, "", [])}})

    note = {}                             # (kind of thing, key): its note
    for pid, p in system.plugins.items():
        note[("plugin", pid)] = thing(f"the plugin {p['title']}", p["title"], p["path"], p["line"], p["doc"], "Plugin", {"id": pid})
    for name, p in sorted(system.points.items()):
        note[("point", name)] = thing(f"the extension point {name}", name, p["path"], p["line"], p["doc"], "Extension point",
                                      {"keyed": p["keyed"], "scope": p["scope"]})
    for kind, k in sorted(system.kinds.items()):
        note[("kind", kind)] = thing(f"the kind {kind}", kind, k["path"], k["line"], k["doc"], "Kind",
                                     {"props": k["props"], "definition": k["definition"], "version": k["version"] or None,
                                      "capabilities": k["capabilities"]})
    for key, p in sorted(system.properties.items()):
        note[("property", key)] = thing(f"the property {key}", key, p["path"], p["line"], p["doc"], "Property", {"type": p["type"]})

    def drawn(*keys):
        return all(note.get(k) is not None for k in keys)

    for pid, what, key in system.declares:
        if drawn(("plugin", pid), (what, key)):
            d.edge(note[("plugin", pid)], note[(what, key)], **{"is": title["declares"]})
    for (pid, point), lines in system.fills.items():
        if drawn(("plugin", pid), ("point", point)):
            d.edge(note[("plugin", pid)], note[("point", point)], **{"is": title["fills"], "fieldValues": {"adds": lines}})
    for kind, key, pid in system.holds:
        if drawn(("kind", kind), ("property", key)):
            d.edge(note[("kind", kind)], note[("property", key)], **{"is": title["holds"], "fieldValues": {"by": pid}})
