# Reads the SQL, the YAML and the module levels that used to go wrong with lenskit, and prints what it made, as JSON.
# usage: python3 -s -B gaps.py SKILL    (SKILL: the canvas-ingest skill's folder, where lenskit is)
import json, sys
sys.path.insert(0, sys.argv[1])
from lenskit import derive, sql, yaml

def table(text, name):
    found = sql.tables(text).get(name)
    return None if found is None else [f"{c.name}:{c.type}:{'null' if c.nullable else 'not null'}{':pk' if c.primary_key else ''}" for c in found.columns]

out = {}
out["key_columns"] = table("CREATE TABLE settings (key text PRIMARY KEY, value text)", "settings")
out["soft_words"] = table("CREATE TABLE t (index int, period text, exclude bool, fulltext text, like varchar(9), key idx_k (index), INDEX i2 (index), "
                          "EXCLUDE USING gist (period WITH =), PERIOD FOR SYSTEM_TIME (a, b), FULLTEXT KEY ft (fulltext), LIKE other INCLUDING ALL)", "t")
out["alter_key"] = table("CREATE TABLE t (a int); ALTER TABLE t ADD key text, ADD COLUMN index int, ADD INDEX i (a), ADD KEY k (a)", "t")
out["dashes"] = table("CREATE TABLE t (a text DEFAULT '--', b int NOT NULL); -- a real comment\n", "t")
out["slash"] = list(sql.tables("CREATE TABLE t (a text DEFAULT '/*', b int);\n/* a real one */\nCREATE TABLE u (x int);"))
dollar = "CREATE TABLE t (a text DEFAULT '$$', b int); CREATE FUNCTION f() RETURNS int AS $$ CREATE TABLE inside (z int); $$ LANGUAGE sql; CREATE TABLE u (x int);"
out["dollar"] = list(sql.tables(dollar))
out["dollar_columns"] = table(dollar, "t")
out["comments"] = table("CREATE TABLE t (a text DEFAULT 'x' -- note\n, b int /* the b */);", "t")
out["check"] = table("CREATE TABLE t (x int CHECK (x IS NOT NULL), y int NOT NULL CHECK (y > 0), z int DEFAULT (1))", "t")
out["alter_column"] = table("CREATE TABLE t (x int, y int PRIMARY KEY); ALTER TABLE t ALTER COLUMN x SET NOT NULL, ALTER COLUMN y DROP NOT NULL; "
                            "ALTER TABLE t ALTER COLUMN x TYPE bigint USING x::bigint; ALTER TABLE t ALTER y SET DATA TYPE text", "t")
out["t_sql"] = table("CREATE TABLE t (x int); ALTER TABLE t ALTER COLUMN x varchar(10) NOT NULL", "t")
out["unicode"] = table('CREATE TABLE "größe" (naïve int, größe text)', "größe")
out["unicode_table"] = "größe" in sql.tables('CREATE TABLE "größe" (naïve int)')
out["after"] = table("CREATE TABLE t (a int); ALTER TABLE t ADD COLUMN b int NULL AFTER a, ADD c text FIRST", "t")
out["temp"] = list(sql.tables("CREATE TEMP TABLE a (x int); CREATE TEMPORARY TABLE b (x int); CREATE GLOBAL TEMPORARY TABLE c (x int); CREATE TABLE d (x int);"))
out["modify"] = table("CREATE TABLE t (a int, b int NOT NULL); ALTER TABLE t MODIFY a bigint NOT NULL, CHANGE COLUMN b c text", "t")

out["bom"] = yaml.load("﻿key: 1\nother: 2\n")
out["keep"] = yaml.load("a: |+\n  x\n\n\nb: |\n  y\n\n\nc: |-\n  z\n\nd: 1\n")
out["keep_end"] = yaml.load("a: |+\n  x\n\n")
for label, text in (("escape", 'a: "\\U00110000"'), ("surrogate", 'a: "\\ud800"')):
    try:
        yaml.load(text)
        out[label] = "NOT REFUSED"
    except yaml.YamlError as e:
        out[label] = str(e)
    except Exception as e:
        out[label] = "NOT A YamlError: " + type(e).__name__

n = 500
prod = ["M%d" % i for i in range(n)]
mods = {m: {"deps": ["M%d" % (i + 1)] if i + 1 < n else []} for i, m in enumerate(prod)}
levels = derive.levels(prod, mods)
out["chain"] = [levels["M0"], levels["M%d" % (n - 1)]]
cycle = {"A": {"deps": ["B"]}, "B": {"deps": ["A", "C"]}, "C": {"deps": []}, "D": {"deps": ["A", "C"]}}
out["levels"] = derive.levels(list(cycle), cycle)
print(json.dumps(out))
