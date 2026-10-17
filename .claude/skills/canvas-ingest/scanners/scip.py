"""Reads a SCIP index (https://github.com/scip-code/scip, scip.proto) with no dependencies: only the fields a
model needs. index(path) -> dict(tool, root, documents=[dict(path, language, symbols, occurrences)]), where
symbols are dict(symbol, documentation, kind, display_name, enclosing) and occurrences are
(range, symbol, roles), range [line, start, end] or [line, start, end line, end]."""

DEFINITION = 0x1
IMPORT = 0x2

def _varint(b, i):
    x = s = 0
    while True:
        c = b[i]
        i += 1
        x |= (c & 0x7f) << s
        if c < 0x80:
            return x, i
        s += 7

def _fields(b):
    """(field number, wire type, value) for each field of a message: a varint's int, a length-delimited bytes."""
    i, n = 0, len(b)
    while i < n:
        key, i = _varint(b, i)
        f, w = key >> 3, key & 7
        if w == 0:
            v, i = _varint(b, i)
        elif w == 2:
            ln, i = _varint(b, i)
            v, i = b[i:i + ln], i + ln
        elif w == 1:
            v, i = b[i:i + 8], i + 8
        elif w == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError(f"wire type {w} at {i}")
        yield f, w, v

def _packed(v, w):
    if w == 0:
        return [v]
    out, i = [], 0
    while i < len(v):
        x, i = _varint(v, i)
        out.append(x if x < 1 << 31 else x - (1 << 32))
    return out

def _symbol_info(b):
    s = dict(symbol='', documentation=[], kind=0, display_name='', enclosing='')
    for f, w, v in _fields(b):
        if f == 1: s['symbol'] = v.decode()
        elif f == 3: s['documentation'].append(v.decode())
        elif f == 5: s['kind'] = v
        elif f == 6: s['display_name'] = v.decode()
        elif f == 8: s['enclosing'] = v.decode()
    return s

def _occurrence(b):
    rng, sym, roles = [], '', 0
    for f, w, v in _fields(b):
        if f == 1: rng += _packed(v, w)
        elif f == 2: sym = v.decode()
        elif f == 3: roles = v
    return rng, sym, roles

def _document(b):
    d = dict(path='', language='', symbols=[], occurrences=[])
    for f, w, v in _fields(b):
        if f == 1: d['path'] = v.decode()
        elif f == 2: d['occurrences'].append(_occurrence(v))
        elif f == 3: d['symbols'].append(_symbol_info(v))
        elif f == 4: d['language'] = v.decode()
    return d

def index(path):
    out = dict(tool='', root='', documents=[])
    for f, w, v in _fields(open(path, 'rb').read()):
        if f == 1:
            for g, _, x in _fields(v):
                if g == 2: out['tool'] = ' '.join(y.decode() for h, _, y in _fields(x) if h in (1, 2))
                elif g == 3: out['root'] = x.decode()
        elif f == 2:
            out['documents'].append(_document(v))
    return out

def descriptors(symbol):
    """A global symbol's package (manager, name, version) and its descriptors as (name, suffix): suffix '/'
    namespace, '#' type, '.' term, '().' method, ':' meta, '!' macro, '[]' type parameter, '()' parameter.
    None for a local symbol."""
    if symbol.startswith('local '):
        return None
    parts, i = [], 0
    for _ in range(4):      # scheme, manager, package name, version: spaces in them are doubled
        j = i
        while True:
            j = symbol.index(' ', j)
            if symbol.startswith('  ', j):
                j += 2
                continue
            break
        parts.append(symbol[i:j].replace('  ', ' '))
        i = j + 1
    out, s = [], symbol[i:]
    k = 0
    while k < len(s):
        if s[k] == '`':
            j = k + 1
            name = []
            while True:
                if s.startswith('``', j):
                    name.append('`'); j += 2
                elif s[j] == '`':
                    break
                else:
                    name.append(s[j]); j += 1
            name, k = ''.join(name), j + 1
        elif s[k] == '[':
            j = s.index(']', k)
            out.append((s[k + 1:j], '[]')); k = j + 1; continue
        elif s[k] == '(':
            j = s.index(')', k)
            out.append((s[k + 1:j], '()')); k = j + 1; continue
        else:
            j = k
            while j < len(s) and (s[j].isalnum() or s[j] in '_+-$'):
                j += 1
            name, k = s[k:j], j
        if k < len(s) and s[k] == '(':
            j = s.index(')', k)
            out.append((name, '().')); k = j + 2
        elif k < len(s):
            out.append((name, s[k])); k += 1
        else:
            out.append((name, ''))
    return tuple(parts[1:4]), out
