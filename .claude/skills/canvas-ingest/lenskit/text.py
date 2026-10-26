"""What a note says: a file's note, and the escapes a note's text needs.

A note's `@[` is a mention to `canvas draw`, so text that is not one is written with `as_text`; a mention of a shape by its
title is `mention`. `file_text` says what a file declares, in its language's words (`words`)."""
import re

# How a note says what its file declares, in its language's words: its types by visibility, its public functions.
WORDS = {
    'swift': dict(public='public', internal='internal', private='private', function='public func', extension='extends'),
    'typescript': dict(public='exports', internal='internal', private='declares', function='exports function', extension='extends'),
}
WORDS_ELSE = dict(public='public', internal='internal', private='private', function='functions', extension='extends')


def words(language):
    """The words a note of that language says what its file declares in."""
    return WORDS.get(language, WORDS_ELSE)


def as_text(s):
    """Text a note shows as it is: every @[ in it written so draw reads it as the two characters, not a mention (a run of
    backslashes before it doubled, then one more)."""
    return re.sub(r'(\\*)@\[', lambda m: m.group(1) * 2 + '\\@[', s)


def mention(title):
    """A mention of the shape with that title, as draw reads one: its spaces folded as a title's are (a label ends at
    a line break), and in it a backslash and a ] each behind a backslash, so a title like [locale] names its shape."""
    return '@[' + ' '.join(title.split()).replace('\\', '\\\\').replace(']', '\\]') + ']'


def names(xs, cap=10):
    """The first `cap` of the names, and how many more there are."""
    return ', '.join(xs[:cap]) + (f' +{len(xs) - cap}' if len(xs) > cap else '')


def file_text(f, language, length=True):
    """A file's note: its doc, what it declares and how long it is. `f` is a file of the scan. `length=False` leaves the
    length out, for a note that holds it as a value (a note of the type File, with its `lines`)."""
    W = words(language)
    parts = []
    if f['doc']:
        parts.append(f['doc'])
    types = [d for d in f['decls'] if d['kind'] == 'type']
    pub = [d['name'] for d in types if d['visibility'] == 'public']
    rest = [d['name'] for d in types if d['visibility'] == 'internal']
    priv = [d['name'] for d in types if d['visibility'] == 'private']
    exts = sorted(set(d['name'] for d in f['decls'] if d['kind'] == 'extension') - set(d['name'] for d in types))
    funcs = [d['name'] for d in f['decls'] if d['kind'] == 'function' and d['visibility'] == 'public']
    lines = []
    if pub: lines.append(f"{W['public']} " + names(pub))
    if rest: lines.append(f"{W['internal']} " + names(rest))
    if priv and not pub and not rest: lines.append(f"{W['private']} " + names(priv))
    if funcs: lines.append(f"{W['function']} " + names(funcs, 6))
    if exts: lines.append(f"{W['extension']} " + names(exts, 6))
    if length:
        lines.append(f"{f['lines']} lines")
    if lines:
        parts.append('\n'.join(lines))
    return '\n\n'.join(parts)


def declares(f, most=60):
    """What a file declares, in a few words: its types, then its public functions (a type's name alone is enough to tell a
    file's part). At most `most` characters, ended with an ellipsis when cut."""
    types = [d['name'] for d in f['decls'] if d['kind'] == 'type']
    funcs = [d['name'] for d in f['decls'] if d['kind'] == 'function' and d['visibility'] == 'public']
    said = names(types + funcs, 4)
    return said if len(said) <= most else said[:most - 1] + '…'
