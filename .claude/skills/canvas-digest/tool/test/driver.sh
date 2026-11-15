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
"$DIGEST" measure "$W/acme.json" --out "$W/o" >"$W/m.txt" || fail measure
grep -q '^measure: 29 nodes' "$W/m.txt" || fail "measure said: $(cat "$W/m.txt")"
grep -q '^tightness: unavailable (the fake canvas embeds nothing)' "$W/m.txt" || fail "tightness line: $(cat "$W/m.txt")"
grep -q -- '--tightness' "$W/measure.log" || fail "measure asks for tightness: $(cat "$W/measure.log")"
: > "$W/measure.log"
"$DIGEST" plan "$W/acme.json" --out "$W/o" --view 1600x900 >"$W/p.txt" || fail plan
grep -q 'laid out for a view of 1600 x 900' "$W/p.txt" || fail "plan said: $(cat "$W/p.txt")"
grep -q '^clusters: ' "$W/p.txt" || fail "the cluster step is said: $(cat "$W/p.txt")"
grep -q 'no tightness: the fake canvas embeds nothing; grouped by the links alone' "$W/p.txt" || fail "clusters by the links alone, saying why: $(cat "$W/p.txt")"
[ -s "$W/o/clustered.json" ] && [ -s "$W/o/clusters.json" ] || fail "cluster files"
# the graph was measured already (by measure above), and the groups add no shape, so the one measure serves the plan: nothing is measured again
[ ! -e "$W/o/measure.clustered.json" ] && [ ! -s "$W/measure.log" ] || fail "plan measures nothing more: $(cat "$W/measure.log")"
node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (!d.layout || !d.layout.clustered || d.layout.clustered.by !== null) process.exit(1);' "$W/o/clustered.json" || fail "clustered.json says its clusters are by the links alone"
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
: > "$W/measure.log"
"$DIGEST" all "$W/acme.json" --out "$W/o3" >"$W/all2.txt" || fail "all again"
# a redraw with nothing carried measures once: the graph's own measure serves, and no carried document is made
[ "$(wc -l < "$W/measure.log" | tr -d ' ')" = 1 ] || fail "a redraw with nothing carried measures once: $(cat "$W/measure.log")"
[ ! -e "$W/o3/carried.json" ] && [ ! -e "$W/o3/measure.carried.json" ] || fail "nothing carried, so no carried.json"
[ -s "$W/o3/current.json" ] || fail "current.json"
N=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).nodes.length)' "$W/o2/drawing.json")
[ "$N" = 29 ] || fail "the drawing holds the document's 29 nodes and no more ($N)"
grep -q "^current: $N shapes" "$W/all2.txt" || fail "current said: $(cat "$W/all2.txt")"
grep -q '^clusters: ' "$W/all2.txt" || fail "a redraw groups the document too: $(cat "$W/all2.txt")"

# a redraw with a note a person carried into another container (a note out of its frame onto the board): the groups are found with it there, and canvas
# measure is asked of the carried document, as the first was but without --tightness; the plan carries the shape itself, so it says so
node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")), by = {};
  const rows = d.nodes.map((n) => Object.assign({ id: "id:" + n.key, key: n.key, at: [[n.place.at[0] + 5, n.place.at[1]], n.place.size], board: "b", inside: n.in ? [n.in] : [] }, n.in ? { in: n.in } : {}));
  const r = rows.find((x) => x.in && !d.nodes.find((n) => n.key === x.key).kind.includes("frame")); delete r.in; r.inside = []; r.changed = ["frame", "moved"];
  require("fs").writeFileSync(process.argv[2], JSON.stringify({ rows, absent: [] }));
  console.log(r.key);' "$W/o2/drawing.json" "$W/rows.json" > "$W/carried-key.txt"
: > "$W/measure.log"
"$DIGEST" all "$W/acme.json" --out "$W/o8" >"$W/all8.txt" || fail "all with a carried note"
[ "$(wc -l < "$W/measure.log" | tr -d ' ')" = 2 ] || fail "a redraw with a note carried measures twice: $(cat "$W/measure.log")"
head -1 "$W/measure.log" | grep -q -- '--tightness' && ! tail -1 "$W/measure.log" | grep -q -- '--tightness' || fail "the graph with --tightness, then the carried document without it: $(cat "$W/measure.log")"
[ -s "$W/o8/carried.json" ] && [ -s "$W/o8/measure.carried.json" ] || fail "carried.json and its measure"
K=$(cat "$W/carried-key.txt")
node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).nodes.find((n) => n.key === process.argv[2]); if (d.in) process.exit(1);' "$W/o8/carried.json" "$K" || fail "carried.json has $K out of its container"
node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).nodes.find((n) => n.key === process.argv[2]); if (!d.in) process.exit(1);' "$W/o8/clustered.json" "$K" || fail "clustered.json keeps $K in its own container"
grep -q '1 of them carried into another container' "$W/all8.txt" || fail "the summary says a note was carried: $(cat "$W/all8.txt")"
# and the next run, the note not carried, takes the stale carried.json away
rm "$W/rows.json"; : > "$W/measure.log"
"$DIGEST" plan "$W/acme.json" --out "$W/o8" >/dev/null || fail "plan again"
[ ! -e "$W/o8/carried.json" ] || fail "a stale carried.json is removed"
[ ! -s "$W/measure.log" ] || fail "no measure when nothing is carried and the measure is there: $(cat "$W/measure.log")"

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

# an older app refuses --tightness: said once, measured again without it, the clusters by the links alone
touch "$W/tightness-old"; : > "$W/measure.log"
"$DIGEST" measure "$W/acme.json" --out "$W/oo" >"$W/old.txt" 2>"$W/old.err" || fail "an older app's measure goes on: $(cat "$W/old.err")"
grep -q "this app's canvas measure doesn't measure tightness (an older one), so the clusters are by the links alone" "$W/old.err" || fail "older app said: $(cat "$W/old.err")"
[ "$(wc -l < "$W/measure.log" | tr -d ' ')" = 2 ] && head -1 "$W/measure.log" | grep -q -- '--tightness' && ! tail -1 "$W/measure.log" | grep -q -- '--tightness' || fail "asked with the flag, then measured without it: $(cat "$W/measure.log")"
grep -q '^tightness: unavailable (canvas measure gave no tightness): clusters by the links alone' "$W/old.txt" || fail "old app tightness line: $(cat "$W/old.txt")"
"$DIGEST" plan "$W/acme.json" --out "$W/oo" --view 1600x900 >"$W/old2.txt" 2>/dev/null || fail "plan on an older app"
grep -q 'no tightness: canvas measure gave no tightness; grouped by the links alone' "$W/old2.txt" || fail "older app's clusters: $(cat "$W/old2.txt")"
rm "$W/tightness-old"

# one that takes longer than --timeout: said, measured again without the flag
touch "$W/tightness-timeout"; : > "$W/measure.log"
"$DIGEST" measure "$W/acme.json" --out "$W/ot" >"$W/to.txt" 2>"$W/to.err" || fail "a timed out tightness goes on: $(cat "$W/to.err")"
grep -q "measuring tightness took longer than --timeout, so the clusters are by the links alone. The vectors that landed are kept: run it again before anything is drawn to use them. Once the file holds the drawing, a redraw keeps what is drawn (it finds the groups again only to weigh the links), so to group it again from the tightness, draw it into a new file (a drawing is found by its name anywhere in the file)" "$W/to.err" || fail "timeout said: $(cat "$W/to.err")"
[ "$(wc -l < "$W/measure.log" | tr -d ' ')" = 2 ] && head -1 "$W/measure.log" | grep -q -- '--tightness' && ! tail -1 "$W/measure.log" | grep -q -- '--tightness' || fail "asked with the flag, then measured without it: $(cat "$W/measure.log")"
grep -q '^tightness: unavailable' "$W/to.txt" || fail "timed out tightness line: $(cat "$W/to.txt")"
rm "$W/tightness-timeout"

# a measure that fails for another reason, its message quoting the word "tightness" (a note titled so), is a failure said as one: not an older app, not a timeout
touch "$W/measure-refuses"; : > "$W/measure.log"
if "$DIGEST" measure "$W/acme.json" --out "$W/ow" >"$W/w.txt" 2>"$W/w.err"; then fail "a refused measure stops"; fi
grep -q 'digest: canvas measure failed:' "$W/w.err" && ! grep -q 'an older one' "$W/w.err" && ! grep -q 'took longer' "$W/w.err" || fail "a refusal quoting tightness: $(cat "$W/w.err")"
grep -q 'a note titled tightness' "$W/w.err" || fail "the refusal is said: $(cat "$W/w.err")"
[ "$(wc -l < "$W/measure.log" | tr -d ' ')" = 1 ] || fail "a refusal is not asked again: $(cat "$W/measure.log")"
rm "$W/measure-refuses"

# a graph with an error stops at check
node -e 'const d = require(process.argv[1]); d.nodes.push({ key: "CTO", kind: "frame" }); require("fs").writeFileSync(process.argv[2], JSON.stringify(d));' "$W/acme.json" "$W/bad.json"
if "$DIGEST" check "$W/bad.json" --out "$W/ob" >"$W/bad.txt" 2>&1; then fail "check exits 1 on errors"; fi
grep -q 'two nodes have the key "CTO"' "$W/bad.txt" || fail "check says the key"
echo "driver ok"
