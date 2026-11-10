#!/bin/sh
# Runs every measure README.md quotes, from this folder, and draws its pictures again into build/pictures.
# DIGEST_TOOL is the layout branch's canvas-digest tool, the folder that holds main.js and lib/ (commit 4bc3494e of
# claude/canvas-layout-strategy-f81c7d), for instance:
#   git worktree add /tmp/slice4 4bc3494e && DIGEST_TOOL=/tmp/slice4/.claude/skills/canvas-digest/tool sh reproduce.sh
# Needs macOS 14 or later (NaturalLanguage's contextual embedding), node, swiftc and git. Takes about 20 minutes.
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

echo '== Selection along the continuum: links cut least alike first, crossings allowed, arrows into frames'
for o in show hide; do for b in 0 0.1 0.25 0.5; do
  node semlayout.mjs --order=sem --sim=mix --simk=all --frames=arrows --nocrowd=1 --budget=$b --others=$o --boards=module:Selection --out=out/cut-$b-$o > /dev/null
  printf 'cut %-4s pills for other boards %-4s ' $b $o; node score-drawing.mjs out/cut-$b-$o/drawing.json module:Selection | tail -1
done; done
for b in 0.1 0.25 0.5; do node cutjudge.mjs "cut $b=out/cut-$b-hide/drawing.json=Selection"; done
for h in 0.5 1; do for b in 0.1 0.25 0.5; do
  node semlayout.mjs --order=sem --sim=mix --simk=all --frames=arrows --nocrowd=1 --budget=$b --others=hide --hub=$h --boards=module:Selection --out=out/hub$h-$b > /dev/null
  printf 'hub penalty %-3s cut %-4s ' $h $b; node score-drawing.mjs out/hub$h-$b/drawing.json module:Selection | tail -1
done; done
node semlayout.mjs --order=sem --sim=mix --simk=all --frames=arrows --nocrowd=1 --oracle=1 --others=hide --boards=module:Selection --out=out/judges-cut > /dev/null
printf 'the judges cut '; node score-drawing.mjs out/judges-cut/drawing.json module:Selection | tail -1
node cutjudge.mjs "the judges cut=out/judges-cut/drawing.json=Selection"
node samecount.mjs
set --
for o in show hide; do for b in 0 0.1 0.25 0.5; do
  pct=$(node -e "console.log(Math.round($b * 100))")
  word=$([ $o = show ] && echo shown || echo hidden)
  node panel.mjs out/cut-$b-$o/drawing.json module:Selection build/pictures/cut-$b-$o.svg "$pct% of links cut, least alike first; pills for other boards $word" judge/rows.json
  qlmanage -t -s 1000 -o build/pictures build/pictures/cut-$b-$o.svg > /dev/null 2>&1
  set -- "$@" build/pictures/cut-$b-$o.svg.png
done; done
build/stitch build/pictures/continuum.jpg 4 "$@"
node panel.mjs out/judges-cut/drawing.json module:Selection build/pictures/judges-cut.svg "cut where both judges chip; pills for other boards hidden" judge/rows.json
qlmanage -t -s 1000 -o build/pictures build/pictures/judges-cut.svg > /dev/null 2>&1
build/stitch build/pictures/judges-cut.jpg 3 build/pictures/cut-0.25-hide.svg.png build/pictures/cut-0.5-hide.svg.png build/pictures/judges-cut.svg.png

echo '== the strategy as stated (springs.mjs): every link an arrow, congestion from k-cores, springs and the break point by similarity'
node springs.mjs --out=out/s-stated
node springs.mjs --frames=arrows --out=out/s-arrows
node springs.mjs --snap=1000 --out=out/s-base > /dev/null
node springs.mjs --snap=1000 --frames=arrows --out=out/s-base-arrows > /dev/null
for d in out-main out-branch out/s-stated out/s-arrows; do printf '%-16s ' "$d"; node score-drawing.mjs "$d/drawing.json"; done
echo '== the readings of the threshold, on Selection'
for s in 1.5 1.75 2; do printf 'stretch, threshold %-5s' $s; node springs.mjs --break=stretch --snap=$s --boards=module:Selection --out=out/s-stretch-$s; done
for s in 1.5 2 3 5; do printf 'strength, threshold %-4s' $s; node springs.mjs --snap=$s --boards=module:Selection --out=out/s-sel-$s; done
echo '== similarity with what each board shares taken out, against the judges'
node springs.mjs --auc=1
node springs.mjs --auc=1 --sim=board
echo '== the five judged boards'
for c in 0 0.5; do node springs.mjs --break=force --sim=board --cut=$c --frames=arrows --boards=$J --out=out/s-force-$c > /dev/null; done
node springs-eval.mjs out/s-base-arrows/drawing.json out-main/drawing.json $J main
node springs-eval.mjs out/s-base-arrows/drawing.json out-branch/drawing.json $J branch
node springs-eval.mjs out/s-base/drawing.json out/s-stated/drawing.json $J 'as stated'
node springs-eval.mjs out/s-base-arrows/drawing.json out/s-arrows/drawing.json $J 'arrows into frames'
for c in 0 0.5; do node springs-eval.mjs out/s-base-arrows/drawing.json out/s-force-$c/drawing.json $J "force below $c"; done

echo '== pictures of the strategy (build/pictures)'
pan() { node panel.mjs "$1/drawing.json" "$2" "build/pictures/$3.svg" "$4" judge/rows.json; qlmanage -t -s 1000 -o build/pictures "build/pictures/$3.svg" > /dev/null 2>&1; }
set --
for b in root module:Selection module:Mentions; do
  t=${b#module:}
  pan out-main $b main-$t "$t: main"
  pan out-branch $b branch-$t "$t: the layout branch"
  pan out/s-stated $b stated-$t "$t: the embedding rule as stated"
  set -- "$@" build/pictures/main-$t.svg.png build/pictures/branch-$t.svg.png build/pictures/stated-$t.svg.png
done
build/stitch build/pictures/strategy.jpg 3 "$@"
set --
for b in Selection Mentions; do
  pan out/s-stated module:$b r1-$b "$b: as stated (breaks on stretch)"
  pan out/s-arrows module:$b r2-$b "$b: links into frames are arrows"
  pan out/s-force-0 module:$b r3-$b "$b: breaks where the force is weak"
  set -- "$@" build/pictures/r1-$b.svg.png build/pictures/r2-$b.svg.png build/pictures/r3-$b.svg.png
done
build/stitch build/pictures/variants.jpg 3 "$@"
set --
for s in 1.5 2 3 5; do pan out/s-sel-$s module:Selection k$s "as stated, threshold $s"; set -- "$@" build/pictures/k$s.svg.png; done
build/stitch build/pictures/threshold.jpg 4 "$@"

echo '== a simulation in the background decides what breaks (background.mjs), against similarity cutting as many links on each board'
for s in 0.5 1 1.5; do node background.mjs --boards=$J --auc=1 --snap=$s --line='load against strength'; done
for s in 0.1 0.2 0.3 0.5; do node background.mjs --physics=crowding --boards=$J --auc=1 --snap=$s --line='crowding only'; done
for l in 0.5 2; do for s in 0.5 1; do node background.mjs --physics=meaning --lambda=$l --boards=$J --auc=1 --snap=$s --line="meaning moves the notes, $l"; done; done
for s in 1 0.5; do printf 'threshold %s: ' $s; node background.mjs --snap=$s --auc=1 --bands=1 | tail -1; done
echo '== its cuts, and the controls, drawn by the layout branch engine (engine.patch and simcut.patch: a cut given before layout, kept)'
rm -rf build/simtool && cp -R "$DIGEST_TOOL" build/simtool && (cd build/simtool && patch -p1 -s < ../../engine.patch && patch -p1 -s < ../../simcut.patch)
for c in "sim1:--snap=1" "sim05:--snap=0.5" "same05:--snap=0.5 --emit=same" "frac66:--snap=0.5 --emit=frac --frac=0.66" "half:--emit=half" \
  "judges:--emit=judges" "simjudges:--emit=simjudges" "chips:--emit=chips" "simchips:--emit=simchips"; do
  n=${c%%:*}; a=${c#*:}
  node background.mjs $a --out=out/bg-$n > /dev/null
done
for n in sim1 sim05 same05 frac66 half; do (SIM_CUT=out/bg-$n/cut.json SIM_KEEPCUT=1 plan build/simtool out/bg-$n/graph.json out/e-$n) & done; wait
for n in judges simjudges chips simchips; do (SIM_CUT=out/bg-$n/cut.json SIM_KEEPCUT=1 plan build/simtool out/bg-$n/graph.json out/e-$n) & done
(SIM_CUT=out/bg-sim05/cut.json plan build/simtool out/bg-sim05/graph.json out/e-sim05-back) &
wait
node engine-eval.mjs main out-main/drawing.json
node engine-eval.mjs 'layout branch' out-branch/drawing.json
for v in "sim1=the simulation, threshold 1" "sim05=the simulation, threshold 0.5" "same05=similarity, its counts (0.5)" "frac66=similarity, a flat two-thirds" \
  "half=similarity, a flat half" "judges=the judges' cut" "simjudges=similarity, the judges' counts" "chips=both judges' chips" "simchips=similarity, the chips' counts"; do
  n=${v%%=*}; node engine-eval.mjs "${v#*=}" out/e-$n/drawing.json out/bg-$n/cut.json
done
node engine-eval.mjs 'the simulation 0.5, put back' out/e-sim05-back/drawing.json out/bg-sim05/cut.json
node hubs.mjs Selection out/bg-sim05/stats.json branch=out-branch/drawing.json simulation=out/e-sim05/drawing.json similarity=out/e-same05/drawing.json
echo '== pictures of the background simulation (build/pictures)'
set --
for b in Selection Mentions; do
  pan out-branch module:$b bg-branch-$b "$b: the layout branch"
  pan out/e-sim05 module:$b bg-sim-$b "$b: the background simulation decides"
  pan out/e-same05 module:$b bg-same-$b "$b: similarity, at the simulation's count"
  pan out/e-judges module:$b bg-judges-$b "$b: the judges' cut"
  set -- "$@" build/pictures/bg-branch-$b.svg.png build/pictures/bg-sim-$b.svg.png build/pictures/bg-same-$b.svg.png build/pictures/bg-judges-$b.svg.png
done
build/stitch build/pictures/background.jpg 4 "$@"
