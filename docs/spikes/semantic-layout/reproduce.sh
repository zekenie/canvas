#!/bin/sh
# Runs every measure README.md quotes, from this folder, and draws its pictures again into build/pictures.
# DIGEST_TOOL is the layout branch's canvas-digest tool, the folder that holds main.js and lib/ (commit 4bc3494e of
# claude/canvas-layout-strategy-f81c7d), for instance:
#   git worktree add /tmp/slice4 4bc3494e && DIGEST_TOOL=/tmp/slice4/.claude/skills/canvas-digest/tool sh reproduce.sh
# Needs macOS 14 or later (NaturalLanguage's contextual embedding), node, swiftc and git. Takes about 15 minutes.
set -eu
cd "$(dirname "$0")"
: "${DIGEST_TOOL:?set DIGEST_TOOL to the layout branch canvas-digest tool folder (main.js, lib/)}"
export DIGEST_TOOL
mkdir -p build out
plan() { node "$1/main.js" plan "$2" data/measure.json "$3" --kinds data/kinds.json --view 1322x893 > "$3.log" 2>&1; }

echo '== the vectors'
node texts.mjs
swiftc -O embed.swift -o build/embed
build/embed data
echo '== does similarity carry meaning'
node check-sim.mjs contextual
node judge-input.mjs

echo '== the drawings: main as of the spike (218388bc), and the layout branch'
rm -rf build/main && mkdir -p build/main
(cd "$(git rev-parse --show-toplevel)" && git archive 218388bc .claude/skills/canvas-digest/tool) | tar -x -C build/main
plan build/main/.claude/skills/canvas-digest/tool data/graph.json out-main
plan "$DIGEST_TOOL" data/graph.json out-branch

echo '== the judges, and each way of ranking links against them'
node eval-judge.mjs

echo '== similarity inside the layout branch engine'
node semweights.mjs data/graph-sem.json
plan "$DIGEST_TOOL" data/graph-sem.json out-semcut
rm -rf build/semtool && cp -R "$DIGEST_TOOL" build/semtool && (cd build/semtool && patch -p1 < ../../engine.patch)
plan build/semtool data/graph-sem.json out-semmend
(export SEM_PRECUT=50; plan build/semtool data/graph-sem.json out-pre50)
(export SEM_PRECUT=density; plan build/semtool data/graph-sem.json out-dens)
(export SEM_PRECUT=50 SEM_KEEPCUT=1; plan build/semtool data/graph-sem.json out-pre50nr)

echo '== the force model'
J=module:Selection,module:Mentions,module:Draw,module:Canvas/Model,module:References
node semlayout.mjs --order=sem --sim=mix --out=out/strict
node semlayout.mjs --order=sem --sim=mix --light=1 --out=out/light
node semlayout.mjs --order=struct --sim=mix --light=1 --out=out/light-struct
node semlayout.mjs --order=sem --sim=mix --light=1 --simk=all --precut=density --out=out/combined --boards=$J
node semlayout2.mjs --order=sem --sim=mix --out=out/shared --boards=$J

echo '== health, every board'
for d in out-main out-branch out-semcut out-semmend out-pre50 out-dens out-pre50nr out/strict out/light out/light-struct; do
  printf '%-16s ' "$d"; node score-drawing.mjs "$d/drawing.json"
done
echo '== against the judges'
node agree.mjs main=out-main/drawing.json branch=out-branch/drawing.json semcut=out-semcut/drawing.json semmend=out-semmend/drawing.json \
  pre50=out-pre50/drawing.json dens=out-dens/drawing.json pre50nr=out-pre50nr/drawing.json strict=out/strict/drawing.json \
  light=out/light/drawing.json light-struct=out/light-struct/drawing.json combined=out/combined/drawing.json shared=out/shared/drawing.json
node ceiling.mjs
node combo.mjs

echo '== pictures (build/pictures)'
mkdir -p build/pictures
swiftc -O stitch.swift -o build/stitch
for b in Selection Mentions; do
  set --
  for v in main=out-main branch=out-branch spike=out-pre50 force=out/light; do
    n=${v%%=*} d=${v#*=}
    node render.mjs "$d/drawing.json" "module:$b" "build/pictures/$b-$n.svg" judge/rows.json > /dev/null
    node compose.mjs "build/pictures/$b-$n-panel.svg" "$b: $n=build/pictures/$b-$n.svg" > /dev/null
    qlmanage -t -s 1400 -o build/pictures "build/pictures/$b-$n-panel.svg" > /dev/null 2>&1
    set -- "$@" "build/pictures/$b-$n-panel.svg.png"
  done
  build/stitch "build/pictures/$b.jpg" 2 "$@"
done
node render.mjs out/strict/drawing.json module:Selection build/pictures/collapse.svg judge/rows.json > /dev/null
qlmanage -t -s 1600 -o build/pictures build/pictures/collapse.svg > /dev/null 2>&1
