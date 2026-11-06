#!/usr/bin/env python3
"""A repository's ingest settings, <repo>/.canvas/ingest.json, read and checked for `ingest` (which never parses JSON in sh).

    settings.py <repo> <scip index path>

Prints the settings as shell assignments for `eval` (S_SCANNER, S_SCIP, S_PREPARE, S_WINDOW as WxH, S_MESS, S_RANKS, S_DRAWING; each
empty when unset; S_FILE says whether there was a file). An unknown key is a warning on standard error, a bad value is an
error naming the key (status 1). With no file, S_SCANNER is empty: ingest decides from what the repository holds.

    scanner   "swift" or "scip"
    scip      the command that writes a SCIP index, run at the repository's root; {index} stands for the path to write
              (written bare, never in quotes: it is replaced by a shell-quoted path)
    prepare   a command run at the repository's root before scanning (installing packages)
    window    [width, height], each from 1 to 1,000,000: the room every board is laid out for; absent, the window's size when the run starts
    mess      0 to 1, the digest's dial
    ranks     "rows" or "columns"
    drawing   the drawing's name, which the app keeps a record by: drawing again with a name updates that drawing in place;
              absent, the lens's, else the repository's name
"""
import json, math, os, shlex, sys

KEYS = ('scanner', 'scip', 'prepare', 'window', 'mess', 'ranks', 'drawing')
WINDOW_MOST = 1_000_000


def fail(message):
    print(f"ingest: .canvas/ingest.json: {message}", file=sys.stderr)
    sys.exit(1)


def number(value):
    """A number JSON holds: never a bool, and finite (`1e400` is infinity to Python's reader, and NaN is read too)."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def main():
    repo, index = sys.argv[1], sys.argv[2]
    path = os.path.join(repo, '.canvas', 'ingest.json')
    out = {'S_FILE': '', 'S_SCANNER': '', 'S_SCIP': '', 'S_PREPARE': '', 'S_WINDOW': '', 'S_MESS': '', 'S_RANKS': '', 'S_DRAWING': ''}
    if os.path.isfile(path):
        out['S_FILE'] = '1'
        try:
            with open(path, encoding='utf-8') as f:
                settings = json.load(f)
        except (OSError, ValueError, RecursionError) as e:
            fail(f"can't be read as JSON ({e})")
        if not isinstance(settings, dict):
            fail("is not an object")
        for key in settings:
            if key not in KEYS:
                print(f"ingest: .canvas/ingest.json: unknown key \"{key}\" passed over (the keys are {', '.join(KEYS)})", file=sys.stderr)
        scanner = settings.get('scanner')
        if scanner is not None:
            if scanner not in ('swift', 'scip'):
                fail('"scanner" is "swift" or "scip"')
            out['S_SCANNER'] = scanner
        scip = settings.get('scip')
        if scip is not None:
            if not isinstance(scip, str) or not scip.strip() or '{index}' not in scip:
                fail('"scip" is a command that writes the index to {index}')
            out['S_SCIP'] = scip.replace('{index}', shlex.quote(index))
        prepare = settings.get('prepare')
        if prepare is not None:
            if not isinstance(prepare, str) or not prepare.strip():
                fail('"prepare" is a command')
            out['S_PREPARE'] = prepare
        window = settings.get('window')
        if window is not None:
            if not (isinstance(window, list) and len(window) == 2 and all(number(v) and 1 <= v <= WINDOW_MOST for v in window)):
                fail(f'"window" is [width, height], each from 1 to {WINDOW_MOST:,}')
            out['S_WINDOW'] = f"{int(round(window[0]))}x{int(round(window[1]))}"
        mess = settings.get('mess')
        if mess is not None:
            if not (number(mess) and 0 <= mess <= 1):
                fail('"mess" is a number from 0 to 1')
            out['S_MESS'] = repr(mess)
        ranks = settings.get('ranks')
        if ranks is not None:
            if ranks not in ('rows', 'columns'):
                fail('"ranks" is "rows" or "columns"')
            out['S_RANKS'] = ranks
        drawing = settings.get('drawing')
        if drawing is not None:
            if not isinstance(drawing, str) or not drawing.strip():
                fail('"drawing" is a name')
            out['S_DRAWING'] = drawing
    for key, value in out.items():
        print(f"{key}={shlex.quote(value)}")


if __name__ == '__main__':
    main()
