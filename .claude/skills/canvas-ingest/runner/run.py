#!/usr/bin/python3
"""Runs a repository's lens twice, isolated, and keeps the digest only when both runs agree.

    run.py REPO SCAN DIGEST [--lens FILE] [--commit SHA]

REPO is the git repository's top folder, SCAN the scan, DIGEST the file to write. The lens is FILE (the checkout's
`.canvas/lens.py`: never read from the commit), else the default lens (lenskit/default.py). It is a function
`digest(scan, repo)` returning the digest as a dict. `repo` reads COMMIT (default HEAD, resolved once) through git.

A run is `env -i` with only PATH=/usr/bin:/bin, HOME (a fresh empty folder), TZ=UTC, LC_ALL=C, PYTHONHASHSEED (1, then 2) and
PYTHONDONTWRITEBYTECODE=1, in a fresh empty folder as the current folder, under `/usr/bin/python3 -s -B`; the clock reads a
different instant in each (child.py). The two digests are compared as JSON, in the lens's own order, byte for byte: a
difference is refused, naming the first node or edge that differs and the usual causes. A lens that raises stops the run with its
traceback. The warnings the lens gathered go to standard error (the first 20, and all of them to lens-warnings.txt beside DIGEST when
there are more), and the digest (without them) to DIGEST."""
import json, os, resource, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PYTHON = '/usr/bin/python3'
TIMEOUT = 900
SAID = 20               # the lens's warnings said; the rest are kept in lens-warnings.txt beside the digest


def die(message, code=1):
    print(f"ingest: {message}", file=sys.stderr)
    sys.exit(code)


def main(argv):
    lens, commit, rest = None, None, []
    it = iter(argv)
    for a in it:
        if a == '--lens':
            lens = next(it, None)
        elif a == '--commit':
            commit = next(it, None)
        else:
            rest.append(a)
    if len(rest) != 3 or (lens is None and '--lens' in argv) or (commit is None and '--commit' in argv):
        sys.exit(__doc__)
    repo, scan, digest = (os.path.abspath(p) for p in rest)
    lens = os.path.abspath(lens) if lens else '-'
    done = subprocess.run(['git', '-C', repo, 'rev-parse', '--verify', (commit or 'HEAD') + '^{commit}'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if done.returncode != 0:
        die(f"can't find the commit {commit or 'HEAD'} in {repo}: {done.stderr.decode(errors='replace').strip()}")
    sha = done.stdout.decode().strip()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)

    scratch = tempfile.mkdtemp(prefix='lens-')
    try:
        processes = []
        for run in (1, 2):
            # each run has a current folder and a HOME of its own, empty, and different from the other's
            work, home = (os.path.join(scratch, f'run{run}', name) for name in ('cwd', 'home'))
            os.makedirs(work)
            os.makedirs(home)
            out = os.path.join(scratch, f'run{run}', 'digest.json')
            log = open(out + '.log', 'wb')
            cmd = ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', f'HOME={home}', 'TZ=UTC', 'LC_ALL=C', f'PYTHONHASHSEED={run}',
                   'PYTHONDONTWRITEBYTECODE=1', PYTHON, '-s', '-B', os.path.join(HERE, 'child.py'), str(run), scan, repo, sha, lens, out]
            processes.append((run, out, log, subprocess.Popen(cmd, cwd=work, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)))
        outputs = []
        for run, out, log, process in processes:
            try:
                process.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                for _, _, _, p in processes:
                    p.kill()
                die(f"the lens ran for over {TIMEOUT} seconds and was stopped")
            log.close()
            if process.returncode != 0:
                print(open(out + '.log', 'rb').read().decode('utf-8', 'replace').rstrip(), file=sys.stderr)
                die(f"the lens failed (run {run}): nothing was drawn" + (f" (it was {lens})" if lens != '-' else ''))
            outputs.append(out)
        texts = [open(o, encoding='utf-8').read() for o in outputs]
        warnings = [json.load(open(o + '.warnings', encoding='utf-8')) for o in outputs]
        stderr = [open(o + '.log', 'rb').read().decode('utf-8', 'replace') for o in outputs]
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if texts[0] != texts[1] or warnings[0] != warnings[1]:
        die(differ(json.loads(texts[0]), json.loads(texts[1]), warnings) + "\n"
            "A lens must make the same digest from the same scan and commit every time. The usual causes: iterating a set (or a dict built from "
            "one) of strings, whose order changes from run to run, so sort it; reading the clock; reading the environment (HOME, os.environ) "
            "or the current folder; reading a file outside `repo` (`repo.read` reads the commit, which does not change).")
    if stderr[0].strip():
        print(stderr[0].rstrip(), file=sys.stderr)
    # the first warnings are said, and all of them kept beside the digest: a lens over a big codebase can warn hundreds of times
    # (a title reworded for each long folder), which would bury the run's own lines
    for w in warnings[0][:SAID]:
        print(f"lens: {w}", file=sys.stderr)
    if len(warnings[0]) > SAID:
        kept = os.path.join(os.path.dirname(os.path.abspath(digest)), 'lens-warnings.txt')
        with open(kept, 'w', encoding='utf-8') as f:
            f.write(''.join(w + '\n' for w in warnings[0]))
        print(f"lens: and {len(warnings[0]) - SAID} more warnings (all {len(warnings[0])}: {kept})", file=sys.stderr)
    with open(digest, 'w', encoding='utf-8') as f:
        f.write(texts[0])
    result = json.loads(texts[0])
    kinds = {}
    for n in result['nodes']:
        kinds[n.get('kind', 'sticky-note')] = kinds.get(n.get('kind', 'sticky-note'), 0) + 1
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)
    print(f"lens: {kinds.get('subboard', 0)} cards, {kinds.get('frame', 0)} frames, {kinds.get('sticky-note', 0)} notes, "
          f"{len(result['edges'])} edges into {digest} (the lens ran twice, {cpu:.1f} s of cpu in all)")


def differ(a, b, warnings):
    """Where two digests first differ, in words."""
    if a.get('title') != b.get('title'):
        return f"the lens made two different digests from one scan: its title is {a.get('title')!r} in one run and {b.get('title')!r} in the other."
    for key, noun in (('nodes', 'node'), ('edges', 'edge')):
        xs, ys = a.get(key, []), b.get(key, [])
        for i in range(max(len(xs), len(ys))):
            x, y = xs[i] if i < len(xs) else None, ys[i] if i < len(ys) else None
            if x != y:
                return (f"the lens made two different digests from one scan: the first {noun} that differs is number {i + 1} ({describe(x)} in one run, "
                        f"{describe(y)} in the other).")
    for key in sorted(set(a) | set(b)):
        if a.get(key) != b.get(key):
            return f"the lens made two different digests from one scan: \"{key}\" differs between runs."
    if warnings[0] != warnings[1]:
        return "the lens made two different digests from one scan: its warnings differ between runs."
    return "the lens made two different digests from one scan."


def describe(item, most=120):
    text = 'nothing' if item is None else json.dumps(item, ensure_ascii=False)
    return text if len(text) <= most else text[:most - 1] + '…'


main(sys.argv[1:])
