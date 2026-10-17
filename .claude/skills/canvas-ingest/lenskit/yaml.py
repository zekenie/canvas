"""A small YAML reader, for the config files a lens reads (docker-compose, CI workflows, OpenAPI, k8s manifests, a service's own).

    from lenskit import yaml
    config = yaml.load(repo.read("docker-compose.yml"))        # dicts, lists, str, int, float, bool, None

Read: block mappings and sequences (a sequence may sit at its key's indent), plain scalars (`null`, `~`, `true` and `false`,
integers, floats; anything else is text, so `yes` and `on` are text, as in YAML 1.2), 'single' and "double" quoted strings
(with their escapes), comments, literal and folded block scalars (`|`, `>`; `-` strips the last line break, `+` keeps the
blank lines after the text, else one line break ends it), and single-line flow `[a, b]` and `{a: b}`, nested. A byte order mark
at the start of the text is passed over.

Refused, with a YamlError that names the line: anchors and aliases (`&`, `*`, the `<<` merge key), tags (`!`), more than one
document (a second `---`, `...`), `? ` complex keys, a tab in indentation, a flow collection that runs over lines, a plain
scalar that runs over lines, and a key given twice."""
import re


class YamlError(ValueError):
    pass


def load(text):
    return _Reader(text).document()


_INT = re.compile(r'[-+]?[0-9]+$')
_FLOAT = re.compile(r'[-+]?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][-+]?[0-9]+)?$')


def _scalar(word):
    if word in ('', '~', 'null', 'Null', 'NULL'):
        return None
    if word in ('true', 'True', 'TRUE'):
        return True
    if word in ('false', 'False', 'FALSE'):
        return False
    if _INT.match(word):
        return int(word)
    if _FLOAT.match(word) and any(ch in word for ch in '.eE'):
        return float(word)
    return word


class _Reader:
    def __init__(self, text):
        text = text[1:] if text.startswith('\ufeff') else text
        self.lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')
        if len(self.lines) > 1 and self.lines[-1] == '':
            self.lines.pop()            # the text's last line break ends its last line; it does not begin another
        self.at = 0                     # the next line to read
        self.current = None             # (indent, content, line number) of the line `look` found, or a replacement for it
        self.seen = False               # whether a line of the document has been read

    # ---- lines ---------------------------------------------------------------------------------------------

    def fail(self, number, message):
        raise YamlError(f"line {number}: {message}")

    def look(self):
        """The next line with something on it: (indent, its content with the comment off, its number), or None."""
        if self.current is not None:
            return self.current
        while self.at < len(self.lines):
            raw, number = self.lines[self.at], self.at + 1
            content = _uncomment(raw).rstrip()
            body = content.lstrip(' ')
            indent = len(content) - len(body)
            if body == '' or (body.startswith('%') and indent == 0 and not self.seen):
                self.at += 1
                continue
            if body.startswith('\t'):
                self.fail(number, 'a tab in the indentation: YAML indents with spaces')
            if indent == 0 and (body == '---' or body.startswith('--- ')):
                if self.seen:
                    self.fail(number, 'more than one document: only the first is read')
                self.seen = True
                self.at += 1
                rest = body[3:].strip()
                if rest:
                    self.current = (0, rest, number)
                    return self.current
                continue
            if indent == 0 and (body == '...' or body.startswith('... ')):
                self.fail(number, 'a document end: only a single document is read')
            self.seen = True
            self.current = (indent, body, number)
            self.at += 1
            return self.current
        return None

    def take(self):
        line = self.look()
        self.current = None
        return line

    def document(self):
        first = self.look()
        if first is None:
            return None
        value = self.block(first[0])
        extra = self.look()
        if extra is not None:
            self.fail(extra[2], f'unexpected "{extra[1]}"')
        return value

    # ---- blocks --------------------------------------------------------------------------------------------

    def block(self, indent):
        line = self.look()
        _, content, number = line
        if content == '-' or content.startswith('- '):
            return self.sequence(indent)
        if _split_key(content, number, self) is not None:
            return self.mapping(indent)
        self.take()
        return self.inline(content, number, indent)

    def sequence(self, indent):
        out = []
        while True:
            line = self.look()
            if line is None or line[0] != indent or not (line[1] == '-' or line[1].startswith('- ')):
                if line is not None and line[0] > indent:
                    self.fail(line[2], 'this line is not indented as the lines before it')
                return out
            _, content, number = line
            rest = content[1:]
            offset = len(rest) - len(rest.lstrip(' '))
            rest = rest.lstrip(' ')
            if rest == '':
                self.take()
                nxt = self.look()
                out.append(self.block(nxt[0]) if nxt is not None and nxt[0] > indent else None)
            elif re.match(r'[|>][-+0-9]*$', rest):
                self.take()
                out.append(self.block_scalar(rest, indent))
            elif rest.startswith('- ') or rest == '-' or _split_key(rest, number, self) is not None:
                # "- key: value" and "- - x": the line goes on as a block whose indent is where the item's content starts
                self.current = (indent + 1 + offset, rest, number)
                out.append(self.block(indent + 1 + offset))
            else:
                self.take()
                out.append(self.inline(rest, number, indent))

    def mapping(self, indent):
        out = {}
        while True:
            line = self.look()
            if line is None or line[0] != indent:
                if line is not None and line[0] > indent:
                    self.fail(line[2], 'this line is not indented as the lines before it')
                return out
            _, content, number = line
            split = _split_key(content, number, self)
            if split is None:
                return out
            key, value = split
            if key in out:
                self.fail(number, f'the key "{key}" is given twice')
            self.take()
            if value == '':
                nxt = self.look()
                if nxt is not None and nxt[0] > indent:
                    out[key] = self.block(nxt[0])
                elif nxt is not None and nxt[0] == indent and (nxt[1] == '-' or nxt[1].startswith('- ')):
                    out[key] = self.sequence(indent)
                else:
                    out[key] = None
            elif value[0] in '|>' and re.match(r'[|>][-+0-9]*$', value):
                out[key] = self.block_scalar(value, indent)
            else:
                out[key] = self.inline(value, number, indent)

    def block_scalar(self, header, indent):
        """The lines under a `|` or `>` header: those indented more than the key's, up to one that isn't."""
        raw = []
        while self.at < len(self.lines):
            line = self.lines[self.at]
            body = line.lstrip(' ')
            if body != '' and len(line) - len(body) <= indent:
                break
            raw.append(line)
            self.at += 1
        self.current = None
        trailing = 0
        while raw and raw[-1].strip() == '':
            raw.pop()
            trailing += 1
        inner = min((len(l) - len(l.lstrip(' ')) for l in raw if l.strip()), default=0)
        lines = [l[inner:] if l.strip() else '' for l in raw]
        if header[0] == '|':
            text = '\n'.join(lines)
        else:
            text, paragraph = '', []
            for l in lines + ['']:
                if l == '':
                    if paragraph:
                        text += ' '.join(paragraph) + '\n'
                        paragraph = []
                    elif text:
                        text += '\n'
                else:
                    paragraph.append(l.strip())
            text = text.rstrip('\n')
        if '-' in header:                                   # strip: no line break at the end
            return text
        if '+' in header:                                   # keep: the line break, and every blank line after the text
            return (text + '\n' if text else '') + '\n' * trailing
        return text + '\n' if text else ''

    # ---- values on one line --------------------------------------------------------------------------------

    def inline(self, text, number, indent):
        text = text.strip()
        if text[0] in '&*!':
            what = {'&': 'an anchor', '*': 'an alias', '!': 'a tag'}[text[0]]
            self.fail(number, f'{what} ("{text.split()[0]}"): anchors, aliases and tags are not read')
        if text[0] in '[{':
            value, end = _flow(text, 0, number, self)
            if text[end:].strip():
                self.fail(number, f'unexpected "{text[end:].strip()}" after the end of a flow collection')
            return value
        if text[0] in '"\'':
            value, end = _quoted(text, 0, number, self)
            if text[end:].strip():
                self.fail(number, f'unexpected "{text[end:].strip()}" after a quoted string')
            return value
        nxt = self.look()
        if nxt is not None and nxt[0] > indent:
            self.fail(nxt[2], 'a plain scalar that runs over lines is not read: quote it, or use | or >')
        return _scalar(text)


def _uncomment(line):
    """The line without its comment: a `#` that starts it or follows a space, outside a quoted string."""
    quote, prev_token = None, ''
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if quote == "'" and c == "'" and line[i + 1:i + 2] == "'":
                i += 2
                continue
            if quote == '"' and c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '"\'' and (prev_token == '' or prev_token in ':-[{,'):
            quote = c
        elif c == '#' and (i == 0 or line[i - 1] in ' \t'):
            return line[:i]
        if not quote and c not in ' \t':
            prev_token = c
        i += 1
    return line


def _split_key(content, number, reader):
    """(key, the rest of the line) when the line is `key: rest`, else None."""
    if content[0] in '[{':
        return None
    if content[0] == '?' and (len(content) == 1 or content[1] == ' '):
        reader.fail(number, 'a complex key ("? ") is not read')
    if content[0] in '"\'':
        try:
            key, end = _quoted(content, 0, number, reader)
        except YamlError:
            return None
        rest = content[end:].lstrip(' ')
        if rest[:1] == ':' and (len(rest) == 1 or rest[1] == ' '):
            return key, rest[1:].strip()
        return None
    for m in re.finditer(r':(?= |$)', content):
        key = content[:m.start()].strip()
        if key == '' or key[0] in '&*!':
            if key[:1] in '&*!':
                reader.fail(number, f'{ {"&": "an anchor", "*": "an alias", "!": "a tag"}[key[0]] } ("{key.split()[0]}"): anchors, aliases and tags are not read')
            return None
        if key == '<<':
            reader.fail(number, 'the merge key "<<" is not read (it needs aliases)')
        return key, content[m.end():].strip()
    return None


def _quoted(text, i, number, reader):
    quote = text[i]
    out, i = [], i + 1
    while i < len(text):
        c = text[i]
        if quote == "'":
            if c == "'":
                if text[i + 1:i + 2] == "'":
                    out.append("'")
                    i += 2
                    continue
                return ''.join(out), i + 1
            out.append(c)
            i += 1
        else:
            if c == '"':
                return ''.join(out), i + 1
            if c == '\\':
                e = text[i + 1:i + 2]
                simple = {'n': '\n', 't': '\t', 'r': '\r', '0': '\0', '"': '"', '\\': '\\', '/': '/', ' ': ' ', 'a': '\a', 'b': '\b',
                          'e': '\x1b', 'f': '\f', 'v': '\v'}
                if e in simple:
                    out.append(simple[e])
                    i += 2
                    continue
                width = {'x': 2, 'u': 4, 'U': 8}.get(e)
                if width and re.fullmatch(r'[0-9a-fA-F]+', text[i + 2:i + 2 + width] or 'z'):
                    code = int(text[i + 2:i + 2 + width], 16)
                    if code > 0x10FFFF or 0xD800 <= code <= 0xDFFF:
                        reader.fail(number, f'the escape \\{e}{text[i + 2:i + 2 + width]} in a double-quoted string is no character')
                    out.append(chr(code))
                    i += 2 + width
                    continue
                reader.fail(number, f'the escape \\{e} in a double-quoted string is not read')
            out.append(c)
            i += 1
    reader.fail(number, 'a quoted string that is not closed on its line')


def _flow(text, i, number, reader):
    """A flow sequence or mapping starting at text[i]: (value, the index after it)."""
    close = ']' if text[i] == '[' else '}'
    out = [] if close == ']' else {}
    i += 1
    while True:
        i = _skip(text, i)
        if i >= len(text):
            reader.fail(number, 'a flow collection that is not closed on its line: flow collections are read on one line')
        if text[i] == close:
            return out, i + 1
        if close == ']':
            value, i = _flow_item(text, i, number, reader, ',]')
            out.append(value)
        else:
            key, i = _flow_item(text, i, number, reader, ':,}', key=True)
            i = _skip(text, i)
            if text[i:i + 1] == ':':
                value, i = _flow_item(text, _skip(text, i + 1), number, reader, ',}')
            else:
                value = None
            if not isinstance(key, str):
                key = str(key)
            if key in out:
                reader.fail(number, f'the key "{key}" is given twice')
            out[key] = value
        i = _skip(text, i)
        if text[i:i + 1] == ',':
            i += 1
        elif text[i:i + 1] != close:
            reader.fail(number, f'expected "," or "{close}" in a flow collection')


def _skip(text, i):
    while i < len(text) and text[i] in ' \t':
        i += 1
    return i


def _flow_item(text, i, number, reader, stops, key=False):
    if i >= len(text):
        reader.fail(number, 'a flow collection that is not closed on its line')
    c = text[i]
    if c in '[{':
        return _flow(text, i, number, reader)
    if c in '"\'':
        return _quoted(text, i, number, reader)
    if c in '&*!':
        reader.fail(number, f'anchors, aliases and tags are not read ("{c}")')
    j = i
    while j < len(text):
        if text[j] in stops and not (text[j] == ':' and text[j + 1:j + 2] not in (' ', ',', '}', ']', '')):
            break
        j += 1
    word = text[i:j].strip()
    return (word if key else _scalar(word)), j
