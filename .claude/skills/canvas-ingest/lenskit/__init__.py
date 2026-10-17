"""lenskit: what a repository's lens (`.canvas/lens.py`) imports to turn a scan of the code into a digest.

A lens is a function `digest(scan, repo)` that returns the digest as a dict; `ingest` runs it (reference/lens.md). The
parts, none with state of its own:

    lenskit.Scan          the scan, with the lookups a lens makes (scan.py)
    lenskit.Repo          the code at one commit, read through git, never the working tree (repo.py)
    lenskit.Digest        a digest builder: frames, subboards, notes, edges, titles given out once, warnings (builder.py)
    lenskit.text          what a note says: as_text, mention, file_text, words (text.py)
    lenskit.default       the default lens, with overrides: default.digest(scan, repo, bands=[...]) (default.py)
    lenskit.yaml          a small YAML reader for config files (yaml.py)
    lenskit.sql           a small SQL reader: CREATE TABLE and ALTER TABLE ... ADD COLUMN (sql.py)

Python is /usr/bin/python3 (3.9): no `match`, no `X | Y` types, no tomllib."""
from . import default, sql, text, yaml
from .builder import Digest, Titles
from .repo import Repo
from .scan import Scan

__all__ = ['Digest', 'Repo', 'Scan', 'Titles', 'default', 'sql', 'text', 'yaml']
