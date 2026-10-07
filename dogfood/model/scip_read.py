#!/usr/bin/env python3
"""The reader for a language a SCIP indexer covers (scip-typescript, scip-python, scip-ruby, ...): reads an index and
the sources it was made from into model.json (README.md has its format).
    scip_read.py <index.scip> <repo> <project dir>/model.json

Modules are the index's packages. A project of one package is split by the folders under its sources' root (the
deepest folder holding most of its files), its own files a module named after the package. A module imports another
when one of its files uses one of the other's. A file's declarations are the symbols it defines at its top level;
which of them are exported (public), and how a file describes itself, come from its source, by its language's
conventions. Tests are left out. Only scip-typescript's indexes have been tried (hono); Python's and Ruby's
conventions here follow their indexers' documented symbol forms."""
import collections, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scip
from reading import first_sentence, readme

TESTS = re.compile(r'(^|/)(__tests__|__mocks__|tests?|spec|fixtures?)/|\.(test|spec)\.[cm]?[jt]sx?$|(^|/)test_[^/]*\.py$|_test\.py$|_spec\.rb$')
INDEX_FILES = ('index.ts', 'index.tsx', 'index.js', 'mod.ts', '__init__.py')
MOST = 0.8              # the sources' root holds at least this share of a package's files

def language_of(tool):
    return next((x for x in ('typescript', 'python', 'ruby') if x in tool), 'unknown')

# ---- a language's conventions -----------------------------------------------------------------------

def ts_exports(text):
    """The names a TypeScript file exports by name: `export { a, b as c }` lists and `export default a`."""
    out = set(re.findall(r'^\s*export\s+default\s+([A-Za-z_$][\w$]*)\s*;?\s*$', text, re.M))
    for block in re.findall(r'\bexport\s*(?:type\s*)?\{([^}]*)\}', text):
        for part in block.split(','):
            name = part.strip().split(' as ')[0].replace('type ', '').strip()
            if name:
                out.add(name)
    return out

def visibility(lang, name, line, listed):
    """public when another module may use it; private when only its file may."""
    if lang == 'typescript':
        return 'public' if re.match(r'\s*export\b', line) or name in listed else 'private'
    if lang == 'python':
        return 'private' if name.startswith('_') else 'public'
    return 'public'

PRAGMA = re.compile(r'\s*(eslint|prettier|@ts-|@jsx|istanbul|global\b|jshint|tslint|c8\b|biome)', re.I)
LICENSE = re.compile(r'copyright\b|spdx-license|licensed under|all rights reserved|@license', re.I)

def first_paragraph(lines):
    """The lines up to the first blank one after some text, joined."""
    out = []
    for l in lines:
        if not l.strip():
            if out: break
            continue
        out.append(l.strip())
    return ' '.join(out) or None

def leading_comment(lang, text):
    """What a file says of itself before its code: a TypeScript file's first doc comment (`/** */`, its tags
    and examples dropped; lint pragmas and licenses passed over), a Python module's docstring, a Ruby file's first
    comment lines; each its first paragraph."""
    text = text.lstrip('﻿')
    if lang == 'typescript':
        i = 0
        while True:
            m = re.compile(r'\s*(//[^\n]*|#![^\n]*|/\*(.*?)\*/)', re.S).match(text, i)
            if not m:
                return None
            i = m.end()
            body = m.group(2)
            if body is None or not body.startswith('*') or PRAGMA.match(body.lstrip('*')) or LICENSE.search(body):
                continue        # a line comment, a plain block, a pragma or a license
            tagged = re.search(r'@(module|packageDocumentation|file|fileoverview)\b', body)
            if not tagged and re.match(r'[ \t]*\n[ \t]*[^\s/]', text[i:]):
                return None     # the doc of the declaration right under it
            kept = []
            for l in (re.sub(r'^\s*\*\s?', '', l) for l in body[1:].split('\n')):
                if l.startswith('```') or (l.startswith('@') and not re.match(r'@(module|packageDocumentation|description|file|fileoverview)\b', l)):
                    break       # an example, or the tags after the description
                kept.append(re.sub(r'^@\w+\s*', '', l))
            return first_paragraph(kept)
    if lang == 'python':
        m = re.match(r'(?:\s*#[^\n]*)*\s*[rRuU]?("""|\'\'\')(.*?)\1', text, re.S)
        return first_paragraph(m.group(2).split('\n')) if m else None
    if lang == 'ruby':
        out = []
        for l in text.split('\n'):
            s = l.strip()
            if re.match(r'#!|#\s*(frozen_string_literal|encoding|coding|typed|rubocop|-\*-)', s):
                continue        # a shebang or a magic comment
            if s.startswith('#'):
                out.append(s.lstrip('#').strip())
            elif s or out:
                break
        return first_paragraph(out)
    return None

def signature(info):
    """The declaration's signature, from its hover text: the code in its first fenced block."""
    for d in info['documentation']:
        m = re.match(r'```\w*\n(.*?)\n```', d, re.S)
        if m:
            return m.group(1)
    return ''

def doc_of(info):
    """A declaration's doc comment, its first paragraph: its hover text past the signature."""
    text = '\n\n'.join(d for d in info['documentation'] if not d.startswith('```'))
    return first_paragraph(text.split('\n'))

def plain_doc(text):
    """A doc's text without JSDoc's inline tags: `{@link Handler}` reads Handler."""
    return re.sub(r'\{@(?:link|linkcode|linkplain)\s+([^}|\s]+)(?:[\s|][^}]*)?\}', r'\1', text) if text else text

def _closing(s, i):
    """The index past the bracket that closes the one at i."""
    pairs, depth, j = {'(': ')', '<': '>', '[': ']', '{': '}'}, [], i
    while j < len(s):
        c = s[j]
        if c in pairs:
            depth.append(pairs[c])
        elif depth and c == depth[-1]:
            depth.pop()
            if not depth:
                return j + 1
        j += 1
    return len(s)

def is_function_type(sig):
    """Whether a value's hover reads `var name: <T>(params) => result`."""
    m = re.match(r'(var|let|const)\s+[\w$]+\s*:\s*', sig)
    if not m:
        return False
    i = m.end()
    if sig.startswith('<', i):
        i = _closing(sig, i)
        while i < len(sig) and sig[i] == ' ': i += 1
    if not sig.startswith('(', i):
        return False
    return re.match(r'\s*=>', sig[_closing(sig, i):]) is not None

def kind_of(suffix, sig, added):
    if added:
        return 'extension'      # adds to another file's declaration (TypeScript's `declare module`)
    if suffix in ('#', '/'):
        return 'type'
    if suffix == '().' or re.match(r'(function|def|async def)\b', sig):
        return 'function'
    if suffix == '.':
        return 'function' if is_function_type(sig) else 'value'
    return 'other'

# ---- the index ----------------------------------------------------------------------------------

_parsed = {}
def parsed(symbol):
    if symbol not in _parsed:
        try:
            _parsed[symbol] = scip.descriptors(symbol)
        except (ValueError, IndexError):
            _parsed[symbol] = None
    return _parsed[symbol]

def file_prefix(descs, path):
    """How many of a symbol's first descriptors name its file: its path's parts (TypeScript), or its module,
    dotted (Python). None when they don't."""
    stem = os.path.splitext(path)[0]
    names = []
    for i, (n, s) in enumerate(descs):
        if s != '/':
            break
        names.append(n)
        if '/'.join(names) == path or (len(names) == 1 and n.replace('.', '/') in (stem, stem[:-len('/__init__')] if stem.endswith('/__init__') else None)):
            return i + 1
    return None

def top_level(symbol, path):
    """(name, suffix, added) when the symbol is declared at the top of its file, or at the top of a `declare module`
    block there (added: it adds to another file's declaration)."""
    p = parsed(symbol)
    if not p or not p[1]:
        return None
    descs = p[1]
    k = file_prefix(descs, path)
    if k is None:           # a scheme that doesn't name its files: whatever only namespaces hold
        if any(s != '/' for _, s in descs[:-1]):
            return None
        k = len(descs) - 1
    added = False
    while k < len(descs) - 1 and descs[k][1] == '/' and descs[k][0].startswith(("'", '"')):
        k, added = k + 1, True
    if k != len(descs) - 1 or descs[k][1] in ('[]', '()', ':', '') or descs[k][0].startswith(("'", '"')):
        return None         # deeper in, a parameter or a property, or a `declare module` block itself
    return descs[k][0], descs[k][1], added

def home(symbol, where):
    """The file a symbol defined in several belongs to: the one its namespaces name, as a path (`src/context.ts`)
    or a module (`pkg.mod`), else the first."""
    p = parsed(symbol)
    if len(where) > 1 and p:
        for w in where:
            if file_prefix(p[1], w) is not None:
                return w
    return where[0]

def augmenting(symbol):
    """Whether a symbol is declared in a `declare module '...'` block, adding to another file's declaration."""
    p = parsed(symbol)
    return bool(p) and any(n.startswith(("'", '"')) for n, s in p[1] if s == '/')

def used_name(symbol):
    """What a use names: the top-level declaration the symbol is, or is in; '*' for a whole file."""
    p = parsed(symbol)
    if not p:
        return None
    return next((n for n, s in p[1] if s != '/'), '*')

def sources_root(ps):
    """The deepest folder holding at least MOST of these files."""
    root = ''
    while True:
        under = collections.Counter(p[len(root):].split('/')[0] for p in ps if p.startswith(root) and '/' in p[len(root):])
        top = under.most_common(1)
        if not top or top[0][1] < MOST * len(ps):
            return root.rstrip('/')
        root += top[0][0] + '/'

def main(index_path, repo, out):
    ix = scip.index(index_path)
    lang = language_of(ix['tool'])
    seen, docs = set(), []
    for d in ix['documents']:
        if not TESTS.search(d['path']) and d['path'] not in seen:
            seen.add(d['path'])
            docs.append(d)
    paths = {d['path'] for d in docs}
    # each file's package: the one most of its definitions name (a file that defines nothing, the commonest)
    package = {}
    for d in docs:
        names = collections.Counter(parsed(s['symbol'])[0][1] for s in d['symbols'] if parsed(s['symbol']))
        package[d['path']] = names.most_common(1)[0][0] if names else None
    commonest = collections.Counter(p for p in package.values() if p).most_common(1)
    for p in package:
        package[p] = package[p] or (commonest[0][0] if commonest else os.path.basename(os.path.abspath(repo)))
    # modules
    by_pkg = collections.defaultdict(list)
    for p in sorted(paths):
        by_pkg[package[p]].append(p)
    module_of, module_path, left_out = {}, {}, []
    if len(by_pkg) == 1:
        (name, ps), = by_pkg.items()
        root = sources_root(ps)
        for p in ps:
            if root and not p.startswith(root + '/'):
                if '/' not in p:
                    left_out.append(p); continue        # setup.py, a config beside the sources
                m = p.split('/')[0]
                module_of[p], module_path[m] = (m, p[len(m) + 1:]), m
                continue
            rel = p[len(root) + 1:] if root else p
            m = rel.split('/')[0] if '/' in rel else name
            module_of[p] = (m, rel[len(m) + 1:] if m != name else rel)
            module_path[m] = root if m == name else os.path.join(root, m)
    else:
        for name, ps in by_pkg.items():
            root = os.path.commonpath([os.path.dirname(p) for p in ps])
            for p in ps:
                module_of[p] = (name, os.path.relpath(p, root) if root else p)
            module_path[name] = root
    docs = [d for d in docs if d['path'] in module_of]
    paths = {d['path'] for d in docs}
    if left_out:
        print(f"left out, beside the sources: {', '.join(left_out[:8])}" + (' …' if len(left_out) > 8 else ''))
    # files and their declarations
    defined = collections.defaultdict(list)
    for d in docs:
        for rng, sym, roles in d['occurrences']:
            if roles & scip.DEFINITION and not sym.startswith('local ') and d['path'] not in defined[sym]:
                defined[sym].append(d['path'])
    defs = {sym: home(sym, where) for sym, where in defined.items()}
    files = []
    for d in docs:
        text = open(os.path.join(repo, d['path']), encoding='utf-8', errors='replace').read()
        lines = text.split('\n')
        listed = ts_exports(text) if lang == 'typescript' else set()
        line_of = {sym: rng[0] for rng, sym, roles in d['occurrences'] if roles & scip.DEFINITION}
        decls, seen = [], set()
        for info in d['symbols']:
            top = top_level(info['symbol'], d['path'])
            if not top or info['symbol'] not in line_of or defs.get(info['symbol']) != d['path'] or (top[0], top[2]) in seen:
                continue
            seen.add((top[0], top[2]))
            ln = line_of[info['symbol']]
            decls.append(dict(name=top[0], kind=kind_of(top[1], signature(info), top[2]), line=ln + 1,
                              visibility=visibility(lang, top[0], lines[ln] if ln < len(lines) else '', listed), info=info))
        decls.sort(key=lambda x: x['line'])
        stem = os.path.splitext(os.path.basename(d['path']))[0].lower().replace('-', '').replace('_', '')
        main_decl = next((x for x in decls if x['name'].lower() == stem and doc_of(x['info'])), None) \
            or next((x for x in decls if x['visibility'] == 'public' and doc_of(x['info'])), None)
        doc = plain_doc(leading_comment(lang, text) or (doc_of(main_decl['info']) if main_decl else None))
        m, rel = module_of[d['path']]
        files.append(dict(module=m, rel=rel, path=d['path'], lines=len(lines) - (1 if text.endswith('\n') else 0),
                          doc=first_sentence(doc) if doc else None,
                          api=any(x['visibility'] == 'public' and x['kind'] != 'extension' for x in decls),
                          decls=[{k: v for k, v in x.items() if k != 'info'} for x in decls]))
    # uses: every symbol a reference names, but where a declaration other files add to (TypeScript's
    # `declare module '...'`) is named, it comes once for each part at the same place: its additions count only
    # where nothing else is named there
    uses = collections.defaultdict(set)
    for d in docs:
        at = collections.defaultdict(list)
        for rng, sym, roles in d['occurrences']:
            if not roles & scip.DEFINITION and not sym.startswith('local ') and defs.get(sym) in paths:
                at[tuple(rng)].append(sym)
        for syms in at.values():
            plain = [s for s in syms if not augmenting(s)]
            for s in plain or syms:
                if defs[s] != d['path']:
                    name = used_name(s)
                    if name:
                        uses[(d['path'], defs[s])].add(name)
    edges = []
    for (a, b), names in sorted(uses.items()):
        names = sorted(names - {'*'}) or ['*']
        edges.append({'from': list(module_of[a]), 'to': list(module_of[b]), 'names': names})
    # modules, in their files' order, the package's own first
    deps = collections.defaultdict(set)
    for e in edges:
        if e['from'][0] != e['to'][0]:
            deps[e['from'][0]].add(e['to'][0])
    by_module = collections.defaultdict(list)
    for f in files:
        by_module[f['module']].append(f)
    names = sorted(by_module, key=lambda m: (m not in by_pkg, m))
    own = {f['path']: f for f in files}
    def folder_doc(folder):
        """A folder's README, else what its index file says of itself."""
        idx = next((own[os.path.join(folder, x)] for x in INDEX_FILES if os.path.join(folder, x) in own), None)
        return readme(os.path.join(repo, folder)) or (idx['doc'] if idx else None)
    modules = []
    for m in names:
        fs = by_module[m]
        sub = sorted(set(f['rel'].split('/')[0] for f in fs if '/' in f['rel']))
        doc = folder_doc(module_path[m]) or (readme(repo) if m in by_pkg else None)
        modules.append(dict(name=m, path=module_path[m], deps=sorted(deps[m]), test=False, layer=None,
                            files=[f['rel'] for f in fs], lines=sum(f['lines'] for f in fs), doc=doc,
                            folders={x: folder_doc(os.path.join(module_path[m], x)) for x in sub}))
    json.dump(dict(language=lang, modules=modules, files=files, uses=edges), open(out, 'w'), indent=1)
    print(f"{ix['tool']}: modules {len(modules)}, files {len(files)}, uses {len(edges)}")

if __name__ == '__main__':
    main(*sys.argv[1:4])
