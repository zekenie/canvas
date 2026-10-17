#!/usr/bin/python3
"""Adds to a digest what drew it: one line at the end of its `text`, the root board's header.

    stamp.py DIGEST REPO SHA LENS APP_BUILD

DIGEST is the file the lens's digest was written to (runner/run.py), REPO the repository, SHA the commit drawn, LENS the lens file
(`.canvas/lens.py`) or "-" for the default lens, APP_BUILD what the app that will draw it says its build is. The line is made after
the lens has run, outside the determinism check, so a lens can neither leave it out nor vary it:

    Drawn from commit 1a2b3c4d5e6f (2026-10-16) with lens 0123456789ab, app build 9f8e7d6c5b4a, macOS 26.0.1.

The commit is 12 hex digits and its committer date in UTC; the lens is the content hash of `.canvas/lens.py` (git's blob id of its bytes, so
committing the lens changes nothing, and neither does the folder it runs in), or, for the default lens, "default" and a hash of lenskit's files; the build is the app's
(`unknown` if it says none); macOS is `sw_vers -productVersion`. The same inputs always make the same line."""
import hashlib, json, os, re, subprocess, sys, time

SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def out(*command):
    done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode != 0:
        sys.exit(f"ingest: {' '.join(command)}: {done.stderr.decode(errors='replace').strip()}")
    return done.stdout.decode().strip()


def one_word(text):
    """A field of the line: one run of non-space characters (a build id has none to lose), `unknown` when empty."""
    return re.sub(r'\s+', '-', text.strip()) or 'unknown'


def blob_hash(data):
    """Git's id for a blob of these bytes, as `git hash-object --no-filters` gives it: of the bytes as they are, so no repository's
    attributes (a `text` or `eol` setting, a filter) and no folder the command runs in change it."""
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def lens_field(lens):
    if lens != '-':
        with open(lens, 'rb') as f:
            return f"lens {blob_hash(f.read())[:12]}"
    digest = hashlib.sha1()
    folder = os.path.join(SKILL, 'lenskit')
    for name in sorted(n for n in os.listdir(folder) if n.endswith('.py')):
        digest.update(name.encode() + b'\0' + open(os.path.join(folder, name), 'rb').read() + b'\0')
    return f"the default lens {digest.hexdigest()[:12]}"


def main(digest_file, repo, sha, lens, build):
    committed = int(out('git', '-C', repo, 'show', '-s', '--format=%ct', sha))
    line = (f"Drawn from commit {sha[:12]} ({time.strftime('%Y-%m-%d', time.gmtime(committed))}) with {lens_field(lens)}, "
            f"app build {one_word(build)}, macOS {one_word(out('/usr/bin/sw_vers', '-productVersion'))}.")
    with open(digest_file, encoding='utf-8') as f:
        digest = json.load(f)
    text = digest.get('text')
    digest['text'] = f"{text.rstrip()}\n\n{line}" if isinstance(text, str) and text.strip() else line
    with open(digest_file, 'w', encoding='utf-8') as f:
        f.write(json.dumps(digest, indent=1) + '\n')
    print(f"ingest: {line}")


main(*sys.argv[1:6])
