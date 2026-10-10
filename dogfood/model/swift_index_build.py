#!/usr/bin/env python3
"""Type-checks every module of a package for its index, in dependency order, into a scratch directory: each module's
interface first (for the modules that import it), then its index, in a store of its own (<scratch>/store/<Module>).
Debug flags, as test.sh builds, so tests' references to DEBUG-only hooks resolve. This is how this repo gets a store,
since SwiftPM can't build here; it handles a package whose targets need nothing but each other. A project Xcode or
`swift build` builds has a store already (DerivedData's Index.noindex/DataStore, .build's index/store).

Only what changed is made again. An interface and an index are each kept with what they were made from (`made_from`:
the compiler, the command, the module's sources and the interfaces of the modules it depends on, all by their bytes),
and made again only when that isn't what is there now. So a run after no change compiles nothing; an edit inside a
function makes its module again and no other, since its interface comes out the same bytes (build.sh relies on that
too); and an edit that changes a module's interface makes the modules that depend on it again as well. A compile reads
no interface but those: a module imports only what Package.swift says it depends on, directly or through another, as
build.sh has it, so an import that isn't declared fails here and is never an index gone stale. A module is one
whole-module compile (-wmo), which type-checks each file once: left to split a module among the cores, the compiler
checks much of it once a part, three times the work here for the same index. Deleting <scratch> starts over.
    swift_index_build.py <repo> <scratch>      writes <scratch>/store/<Module>, and says what it made"""
import atexit, fcntl, hashlib, os, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from swift_analyze import parse_package

REPO, OUT = sys.argv[1], sys.argv[2]
MODS_DIR, STORE = os.path.join(OUT, 'mods'), os.path.join(OUT, 'store')
os.makedirs(MODS_DIR, exist_ok=True); os.makedirs(STORE, exist_ok=True)

# One build of a scratch directory at a time: another waits, and then finds made what this one made.
LOCK = open(os.path.join(OUT, 'lock'), 'w')
try:
    fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    print('waiting for another build of this index', file=sys.stderr)
    fcntl.flock(LOCK, fcntl.LOCK_EX)

def data(path):
    try:
        with open(path, 'rb') as f: return f.read()
    except OSError:
        return b''

COMPILER = subprocess.run(['swiftc', '--version'], capture_output=True, text=True).stdout

def pick_sdk():
    """An SDK the compiler accepts, as build.sh picks one: SDKROOT (which /usr/bin/python3's shim sets to the
    newest SDK), else the newest installed one that type-checks. Asking takes the compiler ten seconds of an SDK
    it rejects, so the answer is kept (<scratch>/sdk), for this compiler and this SDKROOT, while that SDK is there."""
    import glob, json
    kept, asked = os.path.join(OUT, 'sdk'), [COMPILER, os.environ.get('SDKROOT', '')]
    try:
        was = json.loads(data(kept))
        if was[:2] == asked and os.path.isdir(was[2]):
            return was[2]
    except (ValueError, IndexError, TypeError):
        pass
    sdks = sorted(glob.glob('/Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk'),
                  key=lambda p: [int(x) for x in os.path.basename(p)[6:-4].split('.') if x.isdigit()], reverse=True)
    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, 'probe.swift')
        open(probe, 'w').write('let x = 1\n')
        for sdk in ([os.environ['SDKROOT']] if os.environ.get('SDKROOT') else []) + sdks:
            if subprocess.run(['swiftc', '-sdk', sdk, '-typecheck', probe], capture_output=True, env=dict(os.environ, SDKROOT=sdk)).returncode == 0:
                with open(kept, 'w') as f: json.dump(asked + [sdk], f)
                return sdk
    sys.exit('no SDK the compiler accepts')

SDK = pick_sdk()
ENV = dict(os.environ, SDKROOT=SDK)     # an empty SDKROOT outranks -sdk
BASE = ['swiftc', '-sdk', SDK, '-target', 'arm64-apple-macosx14.0', '-swift-version', '6',
        '-enable-upcoming-feature', 'MemberImportVisibility', '-Onone', '-D', 'DEBUG', '-wmo']
# An interface is a module's declarations: the bodies it wouldn't keep aren't checked for it (the module's index checks them)
DECLARATIONS = ['-Xfrontend', '-experimental-skip-non-inlinable-function-bodies-without-types']

mods = {t['name']: t for t in parse_package(REPO)}
for t in mods.values():
    t['deps'] = [d for d in t['deps'] if d in mods]      # a product from another package can't be built here

# What is no module's goes: what a module since removed or renamed left, which the reader would take for code that is
# there (and what this kept before it kept a folder a module: one store for them all, and their interfaces side by side).
for folder in (MODS_DIR, STORE):
    for kept in os.listdir(folder):
        if kept not in mods:
            path = os.path.join(folder, kept)
            shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.remove(path)

# A compile writes to a folder of this run's own, which takes the place of what is kept only once it is whole (`make`).
# What an earlier run left there goes: it was stopped, and a compiler it left running writes to its folder, not this one.
shutil.rmtree(os.path.join(OUT, 'part'), ignore_errors=True)
os.makedirs(os.path.join(OUT, 'part'), exist_ok=True)
PART = tempfile.mkdtemp(dir=os.path.join(OUT, 'part'))
atexit.register(shutil.rmtree, PART, ignore_errors=True)

@lru_cache(None)
def srcs(name):
    out = []
    for dp, dn, fn in os.walk(os.path.join(REPO, mods[name]['path'])):
        out += [os.path.join(dp, f) for f in fn if f.endswith('.swift')]
    return sorted(out)

def entry(name):
    return [] if any(os.path.basename(s) == 'main.swift' for s in srcs(name)) else ['-parse-as-library']

@lru_cache(None)
def closure(name):
    """The modules `name` depends on, directly or through another: the interfaces a compile of it reads."""
    out, todo = set(), list(mods[name]['deps'])
    while todo:
        dep = todo.pop()
        if dep not in out:
            out.add(dep); todo += mods[dep]['deps']
    return sorted(out)

def imports(name):
    """Where a compile of `name` looks for modules: the folders of the interfaces it depends on, and no other."""
    return [arg for dep in closure(name) for arg in ('-I', os.path.join(MODS_DIR, dep))]

level = {}
def lvl(n):
    if n not in level:
        level[n] = 1 + max((lvl(d) for d in mods[n]['deps']), default=-1)
    return level[n]
for n in mods: lvl(n)

interfaces = {}     # a module: its interface's bytes, hashed, once this run has made it or found it as it was
def made_from(cmd, name):
    """What a compile of `name` reads, as one hash: the compiler, the command (the sources' paths are in it), each
    source's bytes, and the interface of each module it depends on, which this run has settled by then."""
    h = hashlib.sha256('\0'.join([COMPILER] + cmd).encode())
    for s in srcs(name):
        h.update(hashlib.sha256(data(s)).digest())
    for dep in closure(name):
        h.update(f'{dep} {interfaces[dep]}\n'.encode())
    return h.hexdigest()

made = {'interface': [], 'index': []}
def make(what, name, command, product):
    """Makes the folder `product` with `command(folder)`, unless it is there with a mark (`made`, in it) that says it
    was made from just what is there now. The compile writes to a folder of this run's own, which takes the product's
    place only after a compile that worked, from sources still as they were when it began, its mark already in it. So
    what is kept is always whole and always what its mark says: a compile that fails or is stopped changes nothing, and
    a compiler left running by a run that was killed writes where no run reads."""
    was = made_from(command(product), name)
    if data(os.path.join(product, 'made')).decode() == was:
        return True
    part = os.path.join(PART, what, name)
    os.makedirs(part)
    p = subprocess.run(command(part), capture_output=True, text=True, env=ENV)
    if p.returncode:
        print(f"{what} {name}: failed\n{p.stderr[-3000:]}"); return False
    if made_from(command(product), name) != was:
        print(f"{what} {name}: its sources changed while it compiled; run this again"); return False
    with open(os.path.join(part, 'made'), 'w') as f: f.write(was)
    shutil.rmtree(product, ignore_errors=True)
    os.rename(part, product)
    made[what].append(name)
    return True

def interface(name):
    ok = make('interface', name, lambda folder: BASE + entry(name) + DECLARATIONS + [
        '-emit-module', '-emit-module-path', os.path.join(folder, name + '.swiftmodule'), '-module-name', name] + imports(name) + srcs(name),
        os.path.join(MODS_DIR, name))
    if ok: interfaces[name] = hashlib.sha256(data(os.path.join(MODS_DIR, name, name + '.swiftmodule'))).hexdigest()
    return ok

def index(name):
    # A store of its own, made anew each time: a store keeps the records of files since changed
    return make('index', name, lambda folder: BASE + entry(name) + ['-typecheck', '-module-name', name] + imports(name) + [
        '-index-store-path', folder, '-index-ignore-system-modules'] + srcs(name), os.path.join(STORE, name))

def said(what, names, of):
    print(f"{what}: made {len(names)} of {of}" + (f" ({', '.join(sorted(names))})" if names else ''))

JOBS = os.cpu_count() or 8      # a compile is one process on one core
# Interfaces, a level at a time (only what something imports).
needed = set(d for n in mods for d in mods[n]['deps'])
for L in range(max(level.values(), default=-1) + 1):
    batch = [n for n in mods if level[n] == L and n in needed]
    with ThreadPoolExecutor(JOBS) as ex:
        if not all(list(ex.map(interface, batch))):
            sys.exit(1)
said('interfaces', made['interface'], len(needed))
# Indexes, all at once.
with ThreadPoolExecutor(JOBS) as ex:
    res = list(ex.map(index, list(mods)))
failed = [n for n, ok in zip(mods, res) if not ok]
if failed:
    sys.exit(f"indexes failed: {', '.join(failed)}")
said('indexes', made['index'], len(mods))
print(f"type-checked {len(made['index'])} of {len(mods)} modules" if made['index'] else f"no module changed: none of the {len(mods)} type-checked")
