"""A small SQL reader, for the tables a lens finds in a repository's migrations.

    from lenskit import sql
    tables = sql.tables([repo.read(p) for p in repo.files("db/migrations/*.sql")])      # in migration order
    tables["users"].columns                                                           # [Column(name, type, nullable, primary_key)]

Read, in the order the texts and the statements come: `CREATE TABLE [IF NOT EXISTS] name (...)` with each column's name
and type (`character varying(255)`, `timestamp with time zone`, `text[]`), whether it may be null (`NOT NULL` and `PRIMARY
KEY` say not) and whether it is a primary key (on the column or in a table-level `PRIMARY KEY (a, b)`);
`ALTER TABLE name ADD [COLUMN] [IF NOT EXISTS] col type ...`, `... DROP COLUMN col`, `... RENAME COLUMN a TO b`,
`... RENAME TO new`, `... ADD PRIMARY KEY (a)`, `... ALTER COLUMN a SET NOT NULL`, `... DROP NOT NULL`, `... TYPE t` (also
`SET DATA TYPE t`, and T-SQL's `ALTER COLUMN a t [NOT NULL]`), MySQL's `MODIFY a t ...` and `CHANGE a b t ...` (a column keeps
its place; `AFTER x` and `FIRST` are no part of a type); and `DROP TABLE [IF EXISTS] a, b`. A name is as written without its
quotes (`"x"`, `` `x` ``), a schema before it kept (`app.users`) except `public.`, which is no schema, and may hold any letters
(`größe`). A column is not null by `NOT NULL` or `PRIMARY KEY` written on it, never by a `CHECK (x IS NOT NULL)`.

Skipped, without a word: every other statement (indexes, inserts, views, functions, comments, grants), a `CREATE TABLE ... AS
SELECT` or `... PARTITION OF` (no columns are written), a temporary table (`CREATE TEMP TABLE`, `TEMPORARY`: not part of the
schema), a table-level constraint but for the primary key, and an ALTER of a table no migration created. Comments and `$$ ... $$`
bodies are taken out in the same pass that reads the strings, so a `'--'` or `'/*'` in a default is a string and no comment. A word
that can start a table-level constraint (`KEY`, `INDEX`, `EXCLUDE`, `PERIOD`, `FULLTEXT`, `SPATIAL`, `LIKE`) is a column's name
when what follows is a type (`key text PRIMARY KEY`); a type this reader has never heard of after such a name reads as a
constraint. `[x]` identifiers (T-SQL) are not read; a block comment is not nested."""
import re
from collections import OrderedDict


class Column:
    def __init__(self, name, type, nullable=True, primary_key=False):
        self.name, self.type, self.nullable, self.primary_key = name, type, nullable, primary_key

    def __repr__(self):
        return f"Column({self.name!r}, {self.type!r}, nullable={self.nullable}, primary_key={self.primary_key})"


class Table:
    def __init__(self, name, schema=None):
        self.name, self.schema, self.columns = name, schema, []

    @property
    def key(self):
        return f"{self.schema}.{self.name}" if self.schema else self.name

    def column(self, name):
        return next((c for c in self.columns if c.name == name), None)

    def __repr__(self):
        return f"Table({self.key!r}, {self.columns!r})"


def tables(texts):
    """{name: Table} after the migrations in `texts` (one text, or a list of them in order) are read."""
    if isinstance(texts, str):
        texts = [texts]
    found = OrderedDict()
    for text in texts:
        for statement in _statements(text):
            _apply(_tokens(statement), statement, found)
    return found


# ---- reading ------------------------------------------------------------------------------------------------------

# What a pass over the text takes out, and what it keeps whole: a string, a quoted name, and then (the order matters) a comment or a
# $$ body, so a `--` or a `/*` inside a string is no comment. A string of Postgres's `E'...'` form has backslash escapes.
_CLEAN = re.compile(r"""(?P<keep>(?<![\w$])[eE]'(?:\\.|[^'\\]|'')*'|'(?:[^']|'')*'|"(?:[^"]|"")*"|`[^`]*`)|--[^\n]*|/\*.*?\*/|(?<![\w$])\$(?P<tag>[A-Za-z_]*)\$.*?\$(?P=tag)\$""",
                    re.DOTALL)
_TOKEN = re.compile(r"""\s+|(?P<quoted>"(?:[^"]|"")*"|`[^`]*`)|(?P<text>[eE]'(?:\\.|[^'\\]|'')*'|'(?:[^']|'')*')|(?P<word>[^\W\d][\w$]*|[0-9]+(?:\.[0-9]+)?)|(?P<mark>.)""",
                    re.DOTALL)


def _clean(text):
    """The text with its comments and $$ bodies out: a comment is a space, a $$ body an empty string."""
    def replace(m):
        if m.group('keep') is not None:
            return m.group('keep')
        return "''" if m.group('tag') is not None else ' '
    return _CLEAN.sub(replace, text)


def _statements(text):
    """The statements of a text with its comments and $$ bodies off, split at the `;` that end them."""
    text = _clean(text)
    out, depth, start = [], 0, 0
    for m in _TOKEN.finditer(text):
        if m.group('mark'):
            c = m.group('mark')
            depth += (c == '(') - (c == ')')
            if c == ';' and depth <= 0:
                out.append(text[start:m.start()])
                start, depth = m.end(), 0
    out.append(text[start:])
    return [s for s in out if s.strip()]


def _tokens(statement):
    """[(kind, value, start, end)]: kind word (upper-cased in value only for keywords' sake: see `_is`), quoted, text, mark."""
    out = []
    for m in _TOKEN.finditer(statement):
        kind = m.lastgroup
        if kind is None:
            continue
        value = m.group(kind)
        if kind == 'quoted':
            value = value[1:-1].replace('""', '"')
        out.append((kind, value, m.start(), m.end()))
    return out


def _is(token, *words):
    return token[0] == 'word' and token[1].upper() in words


def _name(tokens, i):
    """A (possibly qualified) name at tokens[i]: (schema or None, name, the index after it), or None."""
    parts = []
    while i < len(tokens) and tokens[i][0] in ('word', 'quoted'):
        parts.append(tokens[i][1])
        i += 1
        if i < len(tokens) and tokens[i][:2] == ('mark', '.'):
            i += 1
        else:
            break
    if not parts:
        return None
    schema = '.'.join(parts[:-1]) or None
    return (None if schema == 'public' else schema), parts[-1], i


def _key(schema, name):
    return f"{schema}.{name}" if schema else name


def _split(tokens, i, end):
    """The tokens from i to end cut at the commas that are not inside parentheses."""
    out, depth, current = [], 0, []
    for t in tokens[i:end]:
        if t[0] == 'mark' and t[1] == '(':
            depth += 1
        elif t[0] == 'mark' and t[1] == ')':
            depth -= 1
        if t[:2] == ('mark', ',') and depth == 0:
            out.append(current)
            current = []
        else:
            current.append(t)
    if current:
        out.append(current)
    return out


def _matching(tokens, i):
    """The index of the `)` that closes the `(` at tokens[i], or None."""
    depth = 0
    for j in range(i, len(tokens)):
        if tokens[j][:2] == ('mark', '('):
            depth += 1
        elif tokens[j][:2] == ('mark', ')'):
            depth -= 1
            if depth == 0:
                return j
    return None


_CONSTRAINT_WORDS = {'NOT', 'NULL', 'DEFAULT', 'PRIMARY', 'REFERENCES', 'UNIQUE', 'CHECK', 'CONSTRAINT', 'GENERATED', 'COLLATE',
                     'AUTO_INCREMENT', 'AUTOINCREMENT', 'COMMENT', 'IDENTITY', 'AS', 'ENCODE', 'ON', 'AFTER', 'FIRST'}
# Words that start a table-level constraint wherever they begin a definition (all reserved words in the dialects that have them)...
_TABLE_LEVEL = {'CONSTRAINT', 'PRIMARY', 'FOREIGN', 'UNIQUE', 'CHECK'}
# ...and words that start one only when it looks like one (`KEY idx (a)`), since each is also a fair name for a column (`key text`).
_MAYBE_TABLE_LEVEL = {'INDEX', 'KEY', 'EXCLUDE', 'FULLTEXT', 'SPATIAL', 'LIKE', 'PERIOD'}
# The types a name before a `(` marks as a column (`key varchar(10)`), not a constraint (`key idx (a)`).
_TYPES = {'INT', 'INTEGER', 'BIGINT', 'SMALLINT', 'TINYINT', 'MEDIUMINT', 'INT2', 'INT4', 'INT8', 'SERIAL', 'BIGSERIAL', 'SMALLSERIAL',
          'VARCHAR', 'VARCHAR2', 'NVARCHAR', 'NVARCHAR2', 'CHAR', 'NCHAR', 'CHARACTER', 'BPCHAR', 'TEXT', 'NTEXT', 'TINYTEXT',
          'MEDIUMTEXT', 'LONGTEXT', 'CITEXT', 'CLOB', 'NUMERIC', 'DECIMAL', 'NUMBER', 'DEC', 'FLOAT', 'FLOAT4', 'FLOAT8', 'DOUBLE',
          'REAL', 'MONEY', 'BOOL', 'BOOLEAN', 'BIT', 'VARBIT', 'BINARY', 'VARBINARY', 'BLOB', 'TINYBLOB', 'MEDIUMBLOB', 'LONGBLOB',
          'BYTEA', 'RAW', 'DATE', 'TIME', 'TIMETZ', 'TIMESTAMP', 'TIMESTAMPTZ', 'DATETIME', 'DATETIME2', 'SMALLDATETIME', 'YEAR',
          'INTERVAL', 'UUID', 'JSON', 'JSONB', 'XML', 'ENUM', 'SET', 'INET', 'CIDR', 'MACADDR', 'GEOMETRY', 'GEOGRAPHY', 'POINT',
          'LINE', 'POLYGON', 'TSVECTOR', 'TSQUERY', 'HSTORE', 'VARIANT', 'OBJECT', 'ARRAY', 'ROWID', 'IMAGE', 'SQL_VARIANT'}


def _table_level(item):
    """Whether the tokens of a definition (in a CREATE TABLE's list, or after an ALTER's ADD) are a table-level constraint and no
    column: a word that can only start one, or one that can start either followed as a constraint is (`(`, or a name and then `(`,
    and not a type: `KEY idx (a)` is one, `key varchar(10)` a column)."""
    if not item or item[0][0] != 'word':
        return False
    word = item[0][1].upper()
    if word in _TABLE_LEVEL:
        return True
    if word not in _MAYBE_TABLE_LEVEL or len(item) < 2:
        return False
    rest = item[1:]
    if rest[0][:2] == ('mark', '('):
        return word != 'LIKE'
    if rest[0][0] not in ('word', 'quoted'):
        return False
    if _is(rest[0], 'KEY', 'INDEX') and word in ('FULLTEXT', 'SPATIAL'):
        return True
    if _is(rest[0], 'FOR') and word == 'PERIOD':
        return True
    if _is(rest[0], 'USING'):
        return True
    if _is(rest[0], *_TYPES):
        return False
    if word == 'LIKE':
        return len(rest) == 1 or _is(rest[1], 'INCLUDING', 'EXCLUDING')
    return len(rest) > 1 and (rest[1][:2] == ('mark', '(') or _is(rest[1], 'USING'))


def _top_words(tokens):
    """The upper-cased words of tokens that are not inside parentheses (a `CHECK (x IS NOT NULL)` says nothing of the column)."""
    depth, out = 0, []
    for t in tokens:
        if t[0] == 'mark' and t[1] == '(':
            depth += 1
        elif t[0] == 'mark' and t[1] == ')':
            depth -= 1
        elif t[0] == 'word' and depth == 0:
            out.append(t[1].upper())
    return out


def _column(item, statement):
    """A Column from the tokens of one column definition (`name type constraints...`), or None."""
    if len(item) < 2 or item[0][0] not in ('word', 'quoted'):
        return None
    name = item[0][1]
    stop = next((j for j in range(1, len(item)) if _is(item[j], *_CONSTRAINT_WORDS)), len(item))
    kind = ' '.join(statement[item[1][2]:item[stop - 1][3]].split()) if stop > 1 else ''
    if not kind:
        return None
    words = _top_words(item[stop:])
    primary = 'PRIMARY' in words
    nullable = not (primary or any(a == 'NOT' and b == 'NULL' for a, b in zip(words, words[1:])))
    return Column(name, kind, nullable, primary)


def _mark_primary(table, tokens):
    """Columns named in the parentheses of tokens (`PRIMARY KEY (a, b)`) are the table's primary key."""
    for t in tokens:
        if t[0] in ('word', 'quoted'):
            column = table.column(t[1])
            if column is not None:
                column.primary_key, column.nullable = True, False


def _apply(tokens, statement, found):
    if not tokens:
        return
    if _is(tokens[0], 'CREATE'):
        i, temporary = 1, False
        while i < len(tokens) and _is(tokens[i], 'OR', 'REPLACE', 'TEMP', 'TEMPORARY', 'UNLOGGED', 'GLOBAL', 'LOCAL', 'VIRTUAL'):
            temporary = temporary or _is(tokens[i], 'TEMP', 'TEMPORARY')
            i += 1
        if temporary or i >= len(tokens) or not _is(tokens[i], 'TABLE'):
            return
        i += 1
        if i + 2 < len(tokens) and _is(tokens[i], 'IF') and _is(tokens[i + 1], 'NOT') and _is(tokens[i + 2], 'EXISTS'):
            i += 3
        named = _name(tokens, i)
        if named is None or named[2] >= len(tokens) or tokens[named[2]][:2] != ('mark', '('):
            return
        schema, name, i = named
        close = _matching(tokens, i)
        if close is None:
            return
        table = Table(name, schema)
        later = []
        for item in _split(tokens, i + 1, close):
            if _table_level(item):
                later.append(item)
                continue
            column = _column(item, statement)
            if column is not None:
                table.columns.append(column)
        for item in later:
            if any(_is(t, 'PRIMARY') for t in item[:3]) and not any(_is(t, 'FOREIGN') for t in item[:3]):
                _mark_primary(table, item)
        found[table.key] = table
    elif _is(tokens[0], 'DROP') and len(tokens) > 1 and _is(tokens[1], 'TABLE'):
        i = 2
        if i + 1 < len(tokens) and _is(tokens[i], 'IF') and _is(tokens[i + 1], 'EXISTS'):
            i += 2
        for part in _split(tokens, i, len(tokens)):
            named = _name(part, 0)
            if named is not None:
                found.pop(_key(named[0], named[1]), None)
    elif _is(tokens[0], 'ALTER') and len(tokens) > 1 and _is(tokens[1], 'TABLE'):
        i = 2
        if i < len(tokens) and _is(tokens[i], 'ONLY'):
            i += 1
        if i + 1 < len(tokens) and _is(tokens[i], 'IF') and _is(tokens[i + 1], 'EXISTS'):
            i += 2
        named = _name(tokens, i)
        if named is None:
            return
        schema, name, i = named
        table = found.get(_key(schema, name))
        if table is None:
            return
        for action in _split(tokens, i, len(tokens)):
            _alter(table, action, statement, found)


def _alter(table, action, statement, found):
    if not action:
        return
    if _is(action[0], 'ADD'):
        i = 1
        if i < len(action) and _is(action[i], 'COLUMN'):
            i += 1
        elif _table_level(action[i:]):
            if _is(action[i], 'PRIMARY'):
                _mark_primary(table, action[i:])
            return
        if i + 2 < len(action) and _is(action[i], 'IF') and _is(action[i + 1], 'NOT') and _is(action[i + 2], 'EXISTS'):
            i += 3
        column = _column(action[i:], statement)
        if column is not None and table.column(column.name) is None:
            table.columns.append(column)
    elif _is(action[0], 'ALTER'):
        i = 1
        if i < len(action) and _is(action[i], 'COLUMN'):
            i += 1
        if i < len(action) and action[i][0] in ('word', 'quoted'):
            _alter_column(table, action[i][1], action[i + 1:], statement)
    elif _is(action[0], 'MODIFY'):                                      # MySQL: the column's whole definition again
        i = 2 if len(action) > 1 and _is(action[1], 'COLUMN') else 1
        column = _column(action[i:], statement)
        old = table.column(action[i][1]) if i < len(action) else None
        _replace(table, old, column)
    elif _is(action[0], 'CHANGE'):                                      # MySQL: ... and a new name
        i = 2 if len(action) > 1 and _is(action[1], 'COLUMN') else 1
        column = _column(action[i + 1:], statement)
        old = table.column(action[i][1]) if i + 1 < len(action) else None
        _replace(table, old, column)
    elif _is(action[0], 'DROP'):
        i = 1
        if i < len(action) and _is(action[i], 'COLUMN'):
            i += 1
        if i + 1 < len(action) and _is(action[i], 'IF') and _is(action[i + 1], 'EXISTS'):
            i += 2
        if i < len(action) and action[i][0] in ('word', 'quoted') and not _is(action[i], 'CONSTRAINT', 'PRIMARY', 'FOREIGN', 'INDEX', 'DEFAULT'):
            table.columns = [c for c in table.columns if c.name != action[i][1]]
    elif _is(action[0], 'RENAME'):
        i = 1
        if i < len(action) and _is(action[i], 'COLUMN'):
            i += 1
            if i + 2 < len(action) and _is(action[i + 1], 'TO'):
                column = table.column(action[i][1])
                if column is not None:
                    column.name = action[i + 2][1]
        elif i + 1 < len(action) and _is(action[i], 'TO'):
            del found[table.key]
            table.name = action[i + 1][1]
            found[table.key] = table


def _replace(table, old, new):
    """A column defined again (MySQL's MODIFY, CHANGE): in its place, still the primary key it was."""
    if new is None or old is None:
        return
    if old.primary_key:
        new.primary_key, new.nullable = True, False
    table.columns[table.columns.index(old)] = new


def _alter_column(table, name, rest, statement):
    """`ALTER [COLUMN] name <rest>`: SET NOT NULL, DROP NOT NULL, [SET DATA] TYPE t [USING ...], or T-SQL's `t [NOT] NULL`."""
    column = table.column(name)
    if column is None or not rest:
        return
    if _is(rest[0], 'SET') and len(rest) > 2 and _is(rest[1], 'NOT') and _is(rest[2], 'NULL'):
        column.nullable = False
    elif _is(rest[0], 'DROP') and len(rest) > 2 and _is(rest[1], 'NOT') and _is(rest[2], 'NULL'):
        column.nullable = column.nullable or not column.primary_key
    elif _is(rest[0], 'SET') and len(rest) > 2 and _is(rest[1], 'DATA') and _is(rest[2], 'TYPE'):
        _retype(column, rest[3:], statement)
    elif _is(rest[0], 'TYPE'):
        _retype(column, rest[1:], statement)
    elif not _is(rest[0], 'SET', 'DROP', 'ADD', 'RESTART', 'RESET', 'SET'):
        new = _column([('word', name, 0, 0)] + rest, statement)         # T-SQL: ALTER COLUMN name type [NOT NULL]
        if new is not None:
            column.type, column.nullable = new.type, new.nullable and not column.primary_key


def _retype(column, tokens, statement):
    """The type written in tokens, up to USING or COLLATE."""
    end = next((j for j, t in enumerate(tokens) if _is(t, 'USING', 'COLLATE')), len(tokens))
    if end:
        column.type = ' '.join(statement[tokens[0][2]:tokens[end - 1][3]].split())
