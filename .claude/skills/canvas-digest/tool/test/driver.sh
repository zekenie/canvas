#!/bin/sh
# The driver (../../digest) run against a fake canvas (fake-canvas.mjs): its commands, what it asks of the app, what it prints on a refusal.
# Needs node. Run by hand:   sh tool/test/driver.sh      (exit status 0 when every step holds)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DIGEST=$HERE/../../digest
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export FAKE_DIR=$W
printf '#!/bin/sh\nexec node "%s/fake-canvas.mjs" "$@"\n' "$HERE" > "$W/canvas"
chmod +x "$W/canvas"
export CANVAS_CLI=$W/canvas
export JSC=${DRIVER_JSC:-/nonexistent}
cp "$HERE/fixtures/acme.graph.json" "$W/acme.json"
fail() { echo "FAIL $*"; exit 1; }

"$DIGEST" ready --out "$W/o" | grep -q '^ready:' || fail ready
"$DIGEST" check "$W/acme.json" --out "$W/o" | grep -q '^ok$' || fail check
"$DIGEST" measure "$W/acme.json" --out "$W/o" | grep -q '^measure: 29 nodes' || fail measure
"$DIGEST" plan "$W/acme.json" --out "$W/o" --view 1600x900 | grep -q 'laid out for a view of 1600 x 900' || fail plan
[ -s "$W/o/drawing.json" ] && [ -s "$W/o/report.json" ] || fail "plan files"
"$DIGEST" apply --dry-run --out "$W/o" | grep -q '^dry run acme' || fail "apply dry"
[ -s "$W/o/results/apply.dry.json" ] || fail "apply.dry.json"
grep -q -- '--dry-run' "$W/apply.log" || fail "dry-run flag passed"
"$DIGEST" apply --out "$W/o" --on Backend | grep -q '^applied acme' || fail "apply"
[ -s "$W/o/results/apply.json" ] || fail "apply.json"
tail -1 "$W/apply.log" | grep -q -- '--on Backend' || fail "--on passed"

# all: no drawing in the file yet (the query answers no rows), so no current.json; then the file holds it, and the plan starts from its rows
rm -rf "$W/o2"; : > "$W/apply.log"
: > "$W/measure.log"
"$DIGEST" all "$W/acme.json" --out "$W/o2" --on Backend >"$W/all.txt" || fail "all"
grep -q -- '--on Backend' "$W/measure.log" || fail "measure takes --on: $(cat "$W/measure.log")"
[ ! -e "$W/o2/current.json" ] || fail "no current.json when the file lacks the drawing"
[ "$(wc -l < "$W/apply.log" | tr -d ' ')" = 2 ] || fail "all applies twice (dry, real)"
head -1 "$W/apply.log" | grep -q -- '--dry-run' || fail "dry run first"
grep -q ':drawn-by("acme")' "$W/query.log" || fail "the query"
node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const rows = d.nodes.map((n) => Object.assign({ id: "id:" + n.key, key: n.key, at: [[n.place.at[0] + 5, n.place.at[1]], n.place.size], board: "b", inside: n.in ? [n.in] : [] }, n.in ? { in: n.in } : {}));
  require("fs").writeFileSync(process.argv[2], JSON.stringify({ rows, absent: [] }));' "$W/o2/drawing.json" "$W/rows.json"
"$DIGEST" all "$W/acme.json" --out "$W/o3" >"$W/all2.txt" || fail "all again"
[ -s "$W/o3/current.json" ] || fail "current.json"
grep -q '^current: 29 shapes' "$W/all2.txt" || fail "current said"

# a query that fails is not "the file lacks the drawing": stop, saying what canvas said
touch "$W/query-fails"
if "$DIGEST" all "$W/acme.json" --out "$W/o4" >"$W/q.txt" 2>"$W/q.err"; then fail "a failed query stops all"; fi
grep -q 'too slow' "$W/q.err" || fail "the query failure said: $(cat "$W/q.err")"
rm "$W/query-fails"

# --board reaches measure, query and apply
: > "$W/measure.log"; : > "$W/query.log"; : > "$W/apply.log"
"$DIGEST" all "$W/acme.json" --out "$W/o5" --board 3 >/dev/null || fail "all --board"
grep -q -- '--board 3' "$W/measure.log" || fail "measure takes --board: $(cat "$W/measure.log")"
grep -q -- '--board 3' "$W/query.log" || fail "query takes --board"
grep -q -- '--board 3' "$W/apply.log" || fail "apply takes --board"

# apply given the graph path (relative) finds the plan beside it, and a failed apply says what it knows
(cd "$W" && "$DIGEST" plan acme.json >/dev/null && "$DIGEST" apply acme.json | grep -q '^applied acme') || fail "apply with a relative graph"
rm -rf "$W/o6"
if "$DIGEST" apply --out "$W/o6" 2>/dev/null; then fail "apply with no drawing"; fi
[ ! -e "$W/o6" ] || fail "no folder left behind by an apply with no drawing"
touch "$W/timeout"
if "$DIGEST" apply --out "$W/o" 2>"$W/t.err"; then fail "a timed out apply exits 1"; fi
grep -q 'may still be applying' "$W/t.err" && ! grep -q 'nothing was changed' "$W/t.err" || fail "timed out wording: $(cat "$W/t.err")"
rm "$W/timeout"

# a refusal: each key by the app's words, exit 1, nothing more
echo '[{"key":"CTO","reason":"bad","message":"a title is needed","hint":"give it one"}]' > "$W/refuse"
if "$DIGEST" apply --out "$W/o" 2>"$W/err.txt"; then fail "a refusal exits 1"; fi
grep -q '^CTO: a title is needed (give it one)$' "$W/err.txt" || fail "the refusal by key: $(cat "$W/err.txt")"
rm "$W/refuse"

# a graph with an error stops at check
node -e 'const d = require(process.argv[1]); d.nodes.push({ key: "CTO", kind: "frame" }); require("fs").writeFileSync(process.argv[2], JSON.stringify(d));' "$W/acme.json" "$W/bad.json"
if "$DIGEST" check "$W/bad.json" --out "$W/ob" >"$W/bad.txt" 2>&1; then fail "check exits 1 on errors"; fi
grep -q 'two nodes have the key "CTO"' "$W/bad.txt" || fail "check says the key"
echo "driver ok"
