#!/bin/sh
# The corpus check: the grouping and the plan, run on the 71 module boards of this repository that the spike used (docs/plans/board-layout/spike:
# data.tar.gz holds the graph document, the kinds and the app's measurement of it; strategy.tar.gz holds the tightness of every link as OpenAI's
# text-embedding-3-large gave it, the groups the spike made of it at resolution 1.5 (data/groups-decided.json of the spike's folder) and the spike's own
# measurement), with no app, no key and no network. It holds the strategy of issue 26: the lens's boards and frames as they are, none added; the links
# between groups cut before anything is placed, and each that has a clear line once everything is placed brought back as an arrow.
#   1. the measurement and the tightness together (corpus-measure.mjs);
#   2. `cluster`, which must make the spike's groups byte for byte (groups.json);
#   3. `plan` of the clustered document, with the spike's measurement, for a view of 1322 x 893;
#   4. the counts (corpus-counts.mjs), which must be exactly what the spike counted of the same strategy (its strategy-pairs.mjs):
#      774 of 2202 links inside boards drawn as arrows, 72 of 72 boards clean; 1226 links between groups, 147 of them back as arrows; 976 inside
#      groups, 349 of them cut by the engine; the six boards 172 of 557 arrows (360 between groups, 29 back; 197 inside, 54 cut).
# JSC=1 runs the clustering and the plan under the system's jsc instead of node: the same numbers.
#   mise run test:digest-corpus        or        sh .claude/skills/canvas-digest/tool/test/corpus.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL=$(cd "$HERE/.." && pwd)
SPIKE=$(cd "$HERE/../../../../../docs/plans/board-layout/spike" && pwd)
JSC_BIN=${JSC_BIN:-/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
tar xzf "$SPIKE/data.tar.gz" -C "$W" data
tar xzf "$SPIKE/strategy.tar.gz" -C "$W" strategy
mkdir -p "$W/out"
# the tool, under node, or under jsc (which takes no relative path from another folder: every path is absolute)
tool() { if [ -n "${JSC:-}" ]; then (cd "$TOOL" && "$JSC_BIN" main.js -- "$@"); else node "$TOOL/main.js" "$@"; fi; }
fail() { echo "FAIL: $*"; exit 1; }

node "$HERE/corpus-measure.mjs" "$W/strategy" "$W/measure.json"
tool cluster "$W/data/graph.json" "$W/measure.json" "$W/out" --kinds "$W/data/kinds.json"
node "$HERE/corpus-groups.mjs" "$W/out/clusters.json" > "$W/groups.json"
cmp -s "$W/groups.json" "$W/strategy/groups.json" || fail "the groups differ from the spike's (groups.json)"
echo "the groups match the spike's, byte for byte"
tool plan "$W/out/clustered.json" "$W/strategy/measure.json" "$W/out" --kinds "$W/data/kinds.json" --view 1322x893 > "$W/plan.txt"
node "$HERE/corpus-counts.mjs" "$W/data" "$W/out/clustered.json" "$W/out/drawing.json" "$W/strategy/measure.json" > "$W/counts.txt"
cat "$W/counts.txt"
cat > "$W/want.txt" <<'WANT'
774 of 2202 links inside boards are arrows; 72 of 72 boards clean
1226 links between groups, 147 of them back as arrows; 976 inside groups, 349 of them cut by the engine
the six boards 172 of 557 arrows: 360 between groups, 29 back; 197 inside, 54 cut
WANT
cmp -s "$W/counts.txt" "$W/want.txt" || fail "the counts differ from the spike's"
echo "the corpus check holds${JSC:+ (under jsc)}"
