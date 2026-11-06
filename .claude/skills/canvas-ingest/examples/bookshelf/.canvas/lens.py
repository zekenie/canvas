"""The bookshelf's lens: the default lens's picture of its packages and files, with every file a note of the type File.

The root holds the packages as cards in two bands, the apps over the library they share, and the types at the bottom. A
package's board holds its files as notes in frames by folder, and which file uses which as arrows (a use of a file on another
board is a pill). That much is the default lens's, given the bands. Each file's note (`file:<path>`) is then a File, with its
path and how many lines it has as values, so "which files have grown long?" and "what is under routes/?" are canvas queries.

What its conventions don't read: a folder the default lens draws as one note (past 4,000 files, the deepest folders first) is
no file, and stays a plain note. Which file uses which is the default lens's arrows, untyped.

The rules are the team's decisions, each named, with its reason and the round it came from. Python 3.9."""
from lenskit import default
from lenskit.text import as_text, file_text

# ---- the rules -----------------------------------------------------------------------------------------------------------

# Rule "apps-over-libraries": the root's bands are the apps on top and the library they share below. Why: the team reads
# the code from what runs down to what it is built on; the default lens's bands by import depth called them Level 0 and
# Level 1 (round 1).
BANDS = [("Apps", ["@bookshelf/web", "@bookshelf/api"]), ("Library", ["@bookshelf/shared"])]

# Rule "files-are-typed": every file's note is a note of the type File, its path and how many lines it has its values, and
# its words its doc and what it declares; the type is in a frame at the bottom of the root. Why: the team asks of its files
# (the long ones, the ones under a folder), and a note that is a File answers in a query and shows as one in its panel
# (round 1: setup's usual recommendation, which the team took).
TYPES_FRAME = "frame:Types"
FILE_TYPE = "type:File"
FILE = ("A file of the code: its path and how many lines it has.",
        {"type": "object", "properties": {"path": {"type": "string"}, "lines": {"type": "integer"}}, "required": ["path"]})


def digest(scan, repo):
    g = default.build(scan, repo, bands=BANDS)        # unfinished: its file notes are typed below, then it is finished
    below = 1 + max(n.get("layout", {}).get("rank", -1) for n in g.nodes if n["kind"] == "frame" and "in" not in n)   # under every band, an "Other modules" too
    types = g.node(TYPES_FRAME, "frame", {"title": "Types"}, layout={"rank": below})
    words, schema = FILE
    g.node(FILE_TYPE, "sticky-note", {"title": "File", "text": words, "schema": schema}, in_=types)
    for f in scan.files.values():
        note = g.get(f"file:{f['path']}")             # a folder drawn as one note (past 4,000 files) has no such key, and stays plain
        if note is not None:
            props = note["props"]
            text = as_text(file_text(f, scan.language, length=False))
            if text:
                props["text"] = text
            else:
                props.pop("text", None)
            props["is"] = [FILE_TYPE]
            props["fieldValues"] = {"path": f["path"], "lines": f["lines"]}
    return g.finish()
