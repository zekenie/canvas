#!/usr/bin/env python3
"""Reads the repo's module graph and sources, and writes model.json: modules, files, and what each file
declares and says of itself. Which file uses which comes from the compiler (index_build.py, index_read.py)."""
import json, os, re, sys

REPO = sys.argv[1]
OUT = sys.argv[2]

TARGET = re.compile(r'^\s*\.(target|executableTarget)\(name: "([^"]+)", dependencies: \[([^\]]*)\](?:, path: "([^"]+)")?\),\s*// layer: (.+?)\s*$')

def parse_package():
    mods = []
    for line in open(os.path.join(REPO, 'Package.swift')):
        m = TARGET.match(line)
        if not m:
            continue
        kind, name, deps, path, layer = m.groups()
        deps = [d.strip().strip('"') for d in deps.split(',') if d.strip()]
        of = None
        lm = re.match(r'test of (\w+)', layer)
        if lm:
            layer, of = 'test', lm.group(1)
        if path is None:
            path = 'Sources/' + name
        mods.append(dict(name=name, deps=deps, path=path, layer=layer, testOf=of,
                         executable=(kind == 'executableTarget')))
    return mods

def strip_code(src):
    """Source with comments and string literals blanked (interpolations kept), lines kept."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            i = j
            continue
        if src.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith('/*', j): depth += 1; j += 2
                elif src.startswith('*/', j): depth -= 1; j += 2
                else: j += 1
            out.append('\n' * src.count('\n', i, j))
            i = j
            continue
        if c == '"' or (c == '#' and re.match(r'#+"', src[i:i+8] or '')):
            # raw strings: #"..."#
            hashes = 0
            while i < n and src[i] == '#': hashes += 1; i += 1
            multi = src.startswith('"""', i)
            delim = '"""' if multi else '"'
            i += len(delim)
            end = delim + '#' * hashes
            buf = []
            while i < n:
                if src.startswith(end, i):
                    i += len(end); break
                if src[i] == '\\' and hashes == 0:
                    if i + 1 < n and src[i+1] == '(':
                        # interpolation: keep as code
                        depth, j = 1, i + 2
                        while j < n and depth:
                            if src[j] == '(': depth += 1
                            elif src[j] == ')': depth -= 1
                            j += 1
                        buf.append(' ' + src[i+2:j-1] + ' ')
                        i = j
                        continue
                    if i + 1 < n and src[i+1] == '\n':
                        buf.append('\n')     # a line continuation: the line still counts
                    i += 2
                    continue
                if src[i] == '\n':
                    buf.append('\n')
                    if not multi: i += 1; break
                i += 1
            out.append(' "" ' + ''.join(ch if ch == '\n' else '' for ch in buf if ch == '\n') +
                       ' '.join(b for b in buf if b != '\n'))
            continue
        out.append(c)
        i += 1
    return ''.join(out)

ACCESS = r'(?:(public|open|package|internal|fileprivate|private)(?:\(set\))?\s+)?'
MODS = r'(?:(?:final|indirect|nonisolated|static|override|convenience|required|lazy|mutating|dynamic|weak|unowned|class)\s+)*'
ATTRS = r'(?:@[\w.]+(?:\([^)]*\))?\s+)*'
TOP = re.compile(r'^' + ATTRS + ACCESS + MODS + ATTRS + ACCESS + MODS +
                 r'(class|struct|enum|protocol|actor|typealias|func|let|var|extension|macro)\s+([A-Za-z_][\w]*)')
MEMBER = re.compile(r'^    ' + ATTRS + ACCESS + MODS + ATTRS + ACCESS + MODS +
                    r'(func|var|let|init|subscript|struct|class|enum|typealias|protocol|actor|case)\b\s*([A-Za-z_][\w]*)?')
def first_sentence(text, limit=230):
    text = re.sub(r'\s+', ' ', text).strip()
    # a sentence ends at ". " not inside backticks or parens
    depth, tick = 0, False
    for i, ch in enumerate(text):
        if ch == '`': tick = not tick
        elif not tick and ch == '(': depth += 1
        elif not tick and ch == ')': depth = max(0, depth - 1)
        elif not tick and depth == 0 and ch == '.' and (i + 1 == len(text) or text[i+1] == ' '):
            s = text[:i+1]
            break
    else:
        s = text
    if len(s) > limit:
        cut = s[:limit].rsplit(' ', 1)[0].rstrip(',;:(')
        s = cut + '…'
    return s

def analyze_file(path, rel, module):
    src = open(path, encoding='utf-8').read()
    lines = src.split('\n')
    code = strip_code(src)
    clines = code.split('\n')
    imports = sorted(set(re.findall(r'^import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?([\w]+)', src, re.M)))
    decls = []      # top-level declarations
    members = []    # public members at depth 1 (extensions and types)
    docs = {}       # decl name -> doc comment
    ext_public = False
    cur_top = None
    for idx, line in enumerate(clines):
        m = TOP.match(line)
        if m:
            a1, a2, what, name = m.group(1), m.group(2), m.group(3), m.group(4)
            access = a1 or a2 or 'internal'
            cur_top = dict(name=name, what=what, access=access, line=idx + 1)
            if what == 'extension':
                ext_public = access in ('public', 'open')
            decls.append(cur_top)
            # doc comment above (in the original source)
            j = idx - 1
            doc = []
            while j >= 0 and (lines[j].lstrip().startswith('///') or lines[j].lstrip().startswith('@')):
                if lines[j].lstrip().startswith('///'):
                    doc.append(lines[j].lstrip()[3:].strip())
                j -= 1
            if doc and name not in docs:
                docs[name] = ' '.join(reversed(doc))
            continue
        mm = MEMBER.match(line)
        if mm and cur_top is not None:
            a1, a2, what, name = mm.group(1), mm.group(2), mm.group(3), mm.group(4)
            access = a1 or a2
            if access is None and cur_top['what'] == 'extension' and ext_public:
                access = 'public'
            if access is None and cur_top['what'] == 'protocol' and cur_top['access'] in ('public', 'open'):
                access = 'public'
            if name and what not in ('init', 'subscript', 'case'):
                members.append(dict(name=name, what=what, access=access or 'internal', owner=cur_top['name'], onExtension=(cur_top['what'] == 'extension')))
    # the main declaration: named like the file, else the first public type, else the first type
    stem = os.path.basename(rel)[:-6]
    base = stem.split('+')[0]
    types = [d for d in decls if d['what'] in ('class', 'struct', 'enum', 'protocol', 'actor', 'typealias')]
    main = next((d for d in types if d['name'] == stem), None) or next((d for d in types if d['name'] == base), None) \
        or next((d for d in types if d['access'] in ('public', 'open') and d['name'] in docs), None) \
        or next((d for d in types if d['name'] in docs), None) \
        or next((d for d in decls if d['name'] in docs), None)
    desc = docs.get(main['name']) if main else None
    if not desc:
        # first doc comment anywhere
        block = []
        for line in lines:
            s = line.strip()
            if s.startswith('///'):
                block.append(s[3:].strip())
            elif block:
                break
        desc = ' '.join(block) if block else None
    return dict(module=module, rel=rel, path=os.path.relpath(path, REPO), lines=len(lines) - (1 if src.endswith('\n') else 0),
                imports=imports, decls=decls, members=members,
                main=main['name'] if main else None,
                desc=first_sentence(desc) if desc else None,
                descFull=re.sub(r'\s+', ' ', desc).strip() if desc else None)

def main():
    mods = parse_package()
    files = []
    for m in mods:
        root = os.path.join(REPO, m['path'])
        fl = []
        for dp, dn, fn in os.walk(root):
            dn.sort()
            for f in sorted(fn):
                if f.endswith('.swift'):
                    p = os.path.join(dp, f)
                    fl.append(analyze_file(p, os.path.relpath(p, root), m['name']))
        m['files'] = [f['rel'] for f in fl]
        m['lines'] = sum(f['lines'] for f in fl)
        files.extend(fl)
    json.dump(dict(modules=mods, files=files), open(OUT, 'w'), indent=1)
    print(f"modules {len(mods)}, files {len(files)}")

main()
