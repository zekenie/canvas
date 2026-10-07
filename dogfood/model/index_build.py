#!/usr/bin/env python3
"""Type-checks every module of the repo with an index store, in dependency order, into the scratchpad:
each module's interface first (for the modules that import it), then its index. Debug flags, as test.sh
builds, so tests' references to DEBUG-only hooks resolve."""
import os, re, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

REPO, OUT = sys.argv[1], sys.argv[2]
SDK = os.environ.get('SDKROOT', '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
BASE = ['swiftc', '-sdk', SDK, '-target', 'arm64-apple-macosx14.0', '-swift-version', '6',
        '-enable-upcoming-feature', 'MemberImportVisibility', '-Onone', '-D', 'DEBUG']
MODS_DIR, STORE = os.path.join(OUT, 'mods'), os.path.join(OUT, 'store')
shutil.rmtree(STORE, ignore_errors=True)     # a store keeps the records of files since changed, so each run starts empty
os.makedirs(MODS_DIR, exist_ok=True); os.makedirs(STORE, exist_ok=True)

TARGET = re.compile(r'^\s*\.(target|executableTarget)\(name: "([^"]+)", dependencies: \[([^\]]*)\](?:, path: "([^"]+)")?\),')
mods = {}
for line in open(os.path.join(REPO, 'Package.swift')):
    m = TARGET.match(line)
    if m:
        kind, name, deps, path = m.groups()
        mods[name] = dict(exe=kind == 'executableTarget', deps=[d.strip().strip('"') for d in deps.split(',') if d.strip()],
                          path=path or 'Sources/' + name)

def srcs(name):
    out = []
    for dp, dn, fn in os.walk(os.path.join(REPO, mods[name]['path'])):
        out += [os.path.join(dp, f) for f in fn if f.endswith('.swift')]
    return sorted(out)

def entry(name):
    return [] if any(os.path.basename(s) == 'main.swift' for s in srcs(name)) else ['-parse-as-library']

level = {}
def lvl(n):
    if n not in level:
        level[n] = 1 + max((lvl(d) for d in mods[n]['deps']), default=-1)
    return level[n]
for n in mods: lvl(n)

def run(cmd, label):
    t = time.time()
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        print(f"{label}: failed\n{p.stderr[-3000:]}"); return False
    return True

ok = True
# Interfaces, a level at a time (only what something imports).
needed = set(d for n in mods for d in mods[n]['deps'])
for L in range(max(level.values()) + 1):
    batch = [n for n in mods if level[n] == L and n in needed]
    with ThreadPoolExecutor(8) as ex:
        res = list(ex.map(lambda n: run(BASE + entry(n) + ['-emit-module', '-emit-module-path', os.path.join(MODS_DIR, n + '.swiftmodule'),
                                                           '-module-name', n, '-I', MODS_DIR] + srcs(n), 'interface ' + n), batch))
    ok &= all(res)
    if not ok: sys.exit(1)
print('interfaces done')
# Indexes, all at once.
with ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda n: run(BASE + entry(n) + ['-typecheck', '-module-name', n, '-I', MODS_DIR, '-index-store-path', STORE,
                                                       '-index-ignore-system-modules'] + srcs(n), 'index ' + n), list(mods)))
failed = [n for n, ok in zip(mods, res) if not ok]
if failed:
    sys.exit(f"indexes failed: {', '.join(failed)}")
print('indexes done')
