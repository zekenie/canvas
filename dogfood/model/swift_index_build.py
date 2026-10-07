#!/usr/bin/env python3
"""Type-checks every module of a package with an index store, in dependency order, into a scratch directory:
each module's interface first (for the modules that import it), then its index. Debug flags, as test.sh
builds, so tests' references to DEBUG-only hooks resolve. This is how this repo gets a store, since SwiftPM
can't build here; it handles a package whose targets need nothing but each other. A project Xcode or
`swift build` builds has a store already (DerivedData's Index.noindex/DataStore, .build's index/store).
    swift_index_build.py <repo> <scratch>      writes <scratch>/store"""
import os, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swift_analyze import parse_package

REPO, OUT = sys.argv[1], sys.argv[2]

def pick_sdk():
    """An SDK the compiler accepts, as build.sh picks one: SDKROOT (which /usr/bin/python3's shim sets to the
    newest SDK), else the newest installed one that type-checks."""
    import glob, tempfile
    sdks = sorted(glob.glob('/Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk'),
                  key=lambda p: [int(x) for x in os.path.basename(p)[6:-4].split('.') if x.isdigit()], reverse=True)
    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, 'probe.swift')
        open(probe, 'w').write('let x = 1\n')
        for sdk in ([os.environ['SDKROOT']] if os.environ.get('SDKROOT') else []) + sdks:
            if subprocess.run(['swiftc', '-sdk', sdk, '-typecheck', probe], capture_output=True, env=dict(os.environ, SDKROOT=sdk)).returncode == 0:
                return sdk
    sys.exit('no SDK the compiler accepts')

SDK = pick_sdk()
BASE = ['swiftc', '-sdk', SDK, '-target', 'arm64-apple-macosx14.0', '-swift-version', '6',
        '-enable-upcoming-feature', 'MemberImportVisibility', '-Onone', '-D', 'DEBUG']
MODS_DIR, STORE = os.path.join(OUT, 'mods'), os.path.join(OUT, 'store')
shutil.rmtree(STORE, ignore_errors=True)     # a store keeps the records of files since changed, so each run starts empty
os.makedirs(MODS_DIR, exist_ok=True); os.makedirs(STORE, exist_ok=True)

mods = {t['name']: t for t in parse_package(REPO)}
for t in mods.values():
    t['deps'] = [d for d in t['deps'] if d in mods]      # a product from another package can't be built here

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
    p = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, SDKROOT=SDK))   # an empty SDKROOT outranks -sdk
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
