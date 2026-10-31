# Reads YAML and SQL with lenskit's readers and prints what they made, as JSON.
# usage: python3 -s -B readers.py SKILL    (SKILL: the canvas-ingest skill's folder, where lenskit is)
import json, sys
sys.path.insert(0, sys.argv[1])
from lenskit import sql, yaml

compose = yaml.load("""
# a comment
version: "3.8"
services:
  web:
    image: nginx:1.2   # a trailing comment
    ports:
      - "80:80"
      - 443
    environment:
      - A=1
      - B: two
        C: [1, 2, {x: y}]
    command: |
      echo hi
      echo there
    note: >
      one
      two
      three
    flag: true
    empty:
    words: [yes, on, no]
  db: {image: pg, size: 3.5, quoted: 'it''s # not a comment'}
list:
- a
- b
-
  - nested
-
after: last
""")

refused = {}
for label, text in {
    "anchor": "a: &x 1", "alias": "a: *x", "tag": "a: !!str b", "documents": "a: 1\n---\nb: 2", "flow": "a: [1,\n 2]",
    "twice": "a: 1\na: 2", "tab": "a:\n\tb: 1", "indent": "a:\n  b: 1\n c: 2", "complex": "? x\n: y", "merge": "<<: z",
    "plain": "a: one\n  two",
}.items():
    try:
        yaml.load(text)
        refused[label] = "NOT REFUSED"
    except yaml.YamlError as e:
        refused[label] = str(e)

found = sql.tables(["""
-- users, and their orders
CREATE TABLE IF NOT EXISTS public.users (
  id bigserial PRIMARY KEY,
  email character varying(255) NOT NULL UNIQUE,
  created timestamp with time zone DEFAULT now(),
  tags text[],
  CONSTRAINT positive CHECK (id > 0)
);
CREATE INDEX users_email ON users (email);
CREATE TABLE "orders" (id int, user_id int REFERENCES users (id), amount numeric(10, 2) NOT NULL, PRIMARY KEY (id));
INSERT INTO users (email) VALUES ('a;b');
CREATE FUNCTION f() RETURNS int AS $$ BEGIN CREATE TABLE inside (a int); END $$ LANGUAGE plpgsql;
CREATE TABLE soon_gone (a int);
""", """
ALTER TABLE users ADD COLUMN IF NOT EXISTS name text NOT NULL, ADD COLUMN age int;
ALTER TABLE orders DROP COLUMN amount;
ALTER TABLE orders RENAME COLUMN user_id TO uid;
DROP TABLE IF EXISTS soon_gone;
CREATE TABLE view_like AS SELECT 1;
ALTER TABLE never_created ADD COLUMN x int;
CREATE TABLE app.audit (id int);
CREATE TABLE temp_name (b int);
ALTER TABLE temp_name RENAME TO renamed;
"""])

print(json.dumps({
    "compose": compose, "refused": refused, "single_document": yaml.load("---\na: 1\n"),
    "tables": {k: {"columns": [{"name": c.name, "type": c.type, "nullable": c.nullable, "primary_key": c.primary_key} for c in t.columns]} for k, t in found.items()},
    "table_names": list(found),
}))
