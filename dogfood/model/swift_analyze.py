#!/usr/bin/env python3
"""Swift's reader, first half: reads a package's Package.swift and sources into model.json, the model every
layout reads (README.md has its format): its modules, their files, what each file declares and says of itself.
Which file uses which comes from the compiler's index (swift_index_read.py), which adds it to model.json.
    swift_analyze.py <repo> <project dir>/model.json"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from reading import first_sentence, readme

# ---- Package.swift ------------------------------------------------------------------------------

TARGETS = ('target', 'executableTarget', 'testTarget', 'macro')

def blank_comments(text):
    """The text with its comments blanked (newlines kept), so every position still points where it did."""
    out, i, n = list(text), 0, len(text)
    while i < n:
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            i = n if j < 0 else j + 3
        elif text[i] == '"':
            i += 1
            while i < n and text[i] not in '"\n':
                i += 2 if text[i] == '\\' else 1
            i += 1
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out[i:j] = ' ' * (j - i)
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out[i:j] = [c if c == '\n' else ' ' for c in text[i:j]]
            i = j
        else:
            i += 1
    return ''.join(out)

def _closing(code, i, open_, close):
    """The index just past the bracket that closes the one opened just before i, in code with no comments."""
    depth = 1
    while i < len(code) and depth:
        c = code[i]
        if c == '"':
            i += 1
            while i < len(code) and code[i] != '"':
                i += 2 if code[i] == '\\' else 1
        elif c == open_:
            depth += 1
        elif c == close:
            depth -= 1
        i += 1
    return i

def package_name(repo):
    """What the package calls itself, `Package(name: "X"`, else its folder's name."""
    code = blank_comments(open(os.path.join(repo, 'Package.swift')).read())
    m = re.search(r'\bPackage\(\s*name:\s*"([^"]+)"', code)
    return m.group(1) if m else os.path.basename(os.path.abspath(repo))

def shipped_modules(code):
    """The modules of the plugins a package's product is made of, once each, in order, as this repo writes them: a
    table `let ships = [` ... `]` of "Module.Type" strings, in code with no comments. None in a package without one."""
    table = re.search(r'^let ships = \[\n(.*?)^\]', code, re.S | re.M)
    out = []
    for module in re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)\.[A-Za-z_][A-Za-z0-9_]*"', table.group(1)) if table else []:
        if module not in out:
            out.append(module)
    return out

def parse_package(repo):
    """Every target in Package.swift: name, deps (targets and products, by name), path, kind, and its layer tag,
    a `// layer: <name>` comment after it, as this repo writes (`<layer> of X` reads as <layer>). A target written twice
    (in #if branches) is read once; dependencies that aren't a literal list are left out, and said.

    `deps` is what a target's line writes: what its design depends on, and what the board draws its arrows from.
    `links` is what a compile of it reads: those, and, for a line whose list ends `+ shipped` (the product, and the
    tests of it), every module of the plugins that ship, which link into it and which it may import though its line
    names none of them. So the app's card has no arrow to every plugin, and its tests still type-check."""
    text = open(os.path.join(repo, 'Package.swift')).read()
    code = blank_comments(text)
    shipped = shipped_modules(code)
    out, seen, pos = [], set(), 0
    pattern = re.compile(r'\.(' + '|'.join(TARGETS) + r')\(')
    while True:
        m = pattern.search(code, pos)
        if not m:
            break
        end = _closing(code, m.end(), '(', ')')
        args = code[m.end():end - 1]
        pos = end
        name = re.search(r'name:\s*"([^"]+)"', args)
        if not name or name.group(1) in seen:
            continue
        seen.add(name.group(1))
        deps, ships = [], False
        d = re.search(r'dependencies:\s*(\[)?', args)
        if d and d.group(1):
            closed = _closing(args, d.end(), '[', ']')
            inner = args[d.end():closed - 1]
            for a, b in re.findall(r'\.(?:target|byName|product)\(\s*name:\s*"([^"]+)"[^)]*\)|"([^"]+)"', inner):
                deps.append(a or b)
            ships = re.match(r'\s*\+\s*shipped\b', args[closed:]) is not None
        elif d:
            print(f"Package.swift: {name.group(1)}'s dependencies aren't a list written out; left out", file=sys.stderr)
        path = re.search(r'path:\s*"([^"]+)"', args)
        eol = text.find('\n', end)
        tag = re.match(r'\s*,?\s*//\s*layer:\s*(.+?)\s*$', text[end:eol if eol >= 0 else len(text)])
        layer = tag.group(1) if tag else None
        of = re.match(r'(\w+) of \w+', layer) if layer else None
        if of:
            layer = of.group(1)
        kind = m.group(1)
        out.append(dict(name=name.group(1), deps=deps, links=deps + [m for m in shipped if ships and m not in deps], kind=kind, layer=layer,
                        path=path.group(1) if path else ('Tests/' if kind == 'testTarget' else 'Sources/') + name.group(1),
                        test=kind == 'testTarget' or layer in ('test', 'testsupport')))
    return out

# ---- a source file ------------------------------------------------------------------------------

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

def analyze_file(path, rel, module, repo):
    """What a file declares, as Swift says it: top-level declarations (what, access), members (access), and the
    first sentence of the main declaration's doc comment."""
    src = open(path, encoding='utf-8').read()
    lines = src.split('\n')
    code = strip_code(src)
    clines = code.split('\n')
    decls = []      # top-level declarations
    members = []    # members at depth 1 (extensions and types)
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
                members.append(dict(name=name, what=what, access=access or 'internal', owner=cur_top['name']))
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
    return dict(module=module, rel=rel, path=os.path.relpath(path, repo), lines=len(lines) - (1 if src.endswith('\n') else 0),
                decls=decls, members=members, desc=first_sentence(desc) if desc else None)

# ---- in the model's words -----------------------------------------------------------------------

KIND = dict(**{k: 'type' for k in ('class', 'struct', 'enum', 'protocol', 'actor', 'typealias')},
            func='function', extension='extension', let='value', var='value', macro='other')
VISIBILITY = dict(public='public', open='public', package='public', internal='internal', fileprivate='private', private='private')

def neutral_file(raw):
    """A file as the model has it: public is what another module may use (public, open, package), internal what
    the module's other files may (internal), private the file's own (private, fileprivate)."""
    pub = ('public', 'open', 'package')
    return dict(module=raw['module'], rel=raw['rel'], path=raw['path'], lines=raw['lines'], doc=raw['desc'],
                api=any(d['access'] in pub for d in raw['decls']) or any(m['access'] in pub for m in raw['members']),
                decls=[dict(name=d['name'], kind=KIND[d['what']], visibility=VISIBILITY[d['access']], line=d['line'])
                       for d in raw['decls']])

def main(repo, out):
    model = dict(language='swift', name=package_name(repo), modules=[], files=[], uses=[])
    for t in parse_package(repo):
        root = os.path.join(repo, t['path'])
        fl = []
        for dp, dn, fn in os.walk(root):
            dn.sort()
            for f in sorted(fn):
                if f.endswith('.swift'):
                    p = os.path.join(dp, f)
                    fl.append(neutral_file(analyze_file(p, os.path.relpath(p, root), t['name'], repo)))
        own = {f['rel']: f for f in fl}
        folders = sorted(set(f['rel'].split('/')[0] for f in fl if '/' in f['rel']))
        def doc_of(folder, name):
            """A folder's README, else the doc of the file named like it."""
            f = own.get(f"{folder}/{name}.swift" if folder else f"{name}.swift")
            return readme(os.path.join(root, folder or '')) or (f['doc'] if f else None)
        model['modules'].append(dict(name=t['name'], path=t['path'], deps=t['deps'], test=t['test'], layer=t['layer'],
                                     files=[f['rel'] for f in fl], lines=sum(f['lines'] for f in fl),
                                     doc=doc_of(None, t['name']), folders={d: doc_of(d, d) for d in folders}))
        model['files'].extend(fl)
    json.dump(model, open(out, 'w'), indent=1)
    print(f"modules {len(model['modules'])}, files {len(model['files'])}")

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
