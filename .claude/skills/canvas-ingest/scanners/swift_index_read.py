#!/usr/bin/env python3
"""Swift's reader, second half: reads an index store (the one Xcode or `swift build` writes, or the folder of them
swift_index_build.py writes, a store a module) through libIndexStore into exact file-to-file uses: for every file,
the symbols it defines (USRs), and for every explicit reference, the file that defines the symbol. Adds them to
the scan as its uses.
    swift_index_read.py <store> <scan.json>"""
import ctypes as C, json, os, sys, collections

STORE, MODEL = sys.argv[1], sys.argv[2]
lib = C.CDLL('/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib')

class StrRef(C.Structure):
    _fields_ = [('data', C.c_char_p), ('length', C.c_size_t)]
def s(ref):
    return C.string_at(ref.data, ref.length).decode('utf-8', 'replace') if ref.length else ''

err = C.c_void_p()
lib.indexstore_store_create.restype = C.c_void_p
lib.indexstore_store_create.argtypes = [C.c_char_p, C.POINTER(C.c_void_p)]
lib.indexstore_record_reader_create.restype = C.c_void_p
lib.indexstore_record_reader_create.argtypes = [C.c_void_p, C.c_char_p, C.POINTER(C.c_void_p)]
lib.indexstore_record_reader_dispose.argtypes = [C.c_void_p]
OCC_CB = C.CFUNCTYPE(C.c_bool, C.c_void_p, C.c_void_p)
lib.indexstore_record_reader_occurrences_apply_f.argtypes = [C.c_void_p, C.c_void_p, OCC_CB]
lib.indexstore_record_reader_occurrences_apply_f.restype = C.c_bool
lib.indexstore_occurrence_get_symbol.restype = C.c_void_p
lib.indexstore_occurrence_get_symbol.argtypes = [C.c_void_p]
lib.indexstore_occurrence_get_roles.restype = C.c_uint64
lib.indexstore_occurrence_get_roles.argtypes = [C.c_void_p]
lib.indexstore_symbol_get_usr.restype = StrRef
lib.indexstore_symbol_get_usr.argtypes = [C.c_void_p]
lib.indexstore_symbol_get_name.restype = StrRef
lib.indexstore_symbol_get_name.argtypes = [C.c_void_p]
lib.indexstore_symbol_get_kind.restype = C.c_int
lib.indexstore_symbol_get_kind.argtypes = [C.c_void_p]

DECL, DEF, REF, IMPLICIT = 1 << 0, 1 << 1, 1 << 2, 1 << 8

# One store, or a folder of them: a store holds its records in v5/records
paths = [STORE] if os.path.isdir(os.path.join(STORE, 'v5')) else \
    sorted(os.path.join(STORE, d) for d in os.listdir(STORE) if os.path.isdir(os.path.join(STORE, d, 'v5')))
assert paths, f'no store at {STORE}'

model = json.load(open(MODEL))
by_base = collections.defaultdict(list)
for f in model['files']:
    by_base[os.path.basename(f['rel'])].append((f['module'], f['rel']))

records = []         # (a record's name, its store), in the stores' order
for path in paths:
    store = lib.indexstore_store_create(path.encode(), C.byref(err))
    assert store, f'no store at {path}'
    for dp, dn, fn in os.walk(os.path.join(path, 'v5', 'records')):
        records += [(f, store) for f in fn]

defs = {}            # usr -> (module, rel)
file_refs = {}       # (module, rel) -> {usr: name}
unplaced = []
for rec, store in sorted(records, key=lambda r: r[0]):
    base = rec.rsplit('-', 1)[0]
    occ = []
    def cb(ctx, o):
        sym = lib.indexstore_occurrence_get_symbol(o)
        occ.append((lib.indexstore_occurrence_get_roles(o), s(lib.indexstore_symbol_get_usr(sym)), s(lib.indexstore_symbol_get_name(sym))))
        return True
    reader = lib.indexstore_record_reader_create(store, rec.encode(), C.byref(err))
    if not reader:
        print('unreadable', rec); continue
    lib.indexstore_record_reader_occurrences_apply_f(reader, None, OCC_CB(cb))
    lib.indexstore_record_reader_dispose(reader)
    cands = by_base.get(base, [])
    if len(cands) > 1:
        # one name in several modules: the one whose name the defined symbols carry most
        defined = [u for r, u, n in occ if r & (DECL | DEF)] or [u for r, u, n in occ]
        score = lambda c: sum(u.count(f"{len(c[0])}{c[0]}") for u in defined)
        ranked = sorted(cands, key=score, reverse=True)
        cands = ranked[:1] if ranked and score(ranked[0]) > (score(ranked[1]) if len(ranked) > 1 else 0) else []
    if len(cands) != 1:
        unplaced.append(rec); continue
    key = cands[0]
    for r, u, n in occ:
        if r & (DECL | DEF):
            defs.setdefault(u, key)
    refs = file_refs.setdefault(key, {})
    for r, u, n in occ:
        if r & REF and not r & IMPLICIT:
            refs[u] = n

edges = collections.defaultdict(set)
for key, refs in file_refs.items():
    for u, n in refs.items():
        d = defs.get(u)
        if d and d != key:
            edges[(key, d)].add(n)
out = [{'from': list(a), 'to': list(b), 'names': sorted(ns)} for (a, b), ns in edges.items()]
model['uses'] = out
json.dump(model, open(MODEL, 'w'), indent=1)
print(f"records {len(records)}, files placed {len(file_refs)}, unplaced {len(unplaced)} {unplaced[:5]}, edges {len(out)}")
