#!/bin/zsh
# Builds every module but the app (debug), runs every test executable, as many at once as there are
# cores (a failing one doesn't stop the others), and exits non-zero if any failed. Each one's output
# is printed whole, in order, once it's done. TEST_FILTER=substring runs only the tests whose
# "Suite: test" name contains it, and fails if that's none at all. TEST_JOBS=N runs N at once;
# TEST_UI_MENUS=1 (tests that open real menus) runs them one at a time.
set -uo pipefail
zmodload zsh/datetime
cd "${0:A:h}"
[[ ${TEST_JOBS:-1} == <1-> ]] || { print -u2 "test.sh: TEST_JOBS is how many run at once, 1 or more; not '$TEST_JOBS'"; exit 2 }
./build.sh tests || exit 1
tests=(${(f)"$(./build.sh list test)"}) || exit 1

# A Suite runs only if its target's main.swift passes it to runTests, and Swift doesn't warn about
# one that's left out, so check.
unregistered=()
for t in $tests; do
    files=(Tests/$t/**/*.swift(N)); files=(${files:#Tests/$t/main.swift})
    (( ${#files} )) || continue
    registered=$(sed -E 's#//.*##' Tests/$t/main.swift)
    for suite in ${(f)"$(sed -E 's#//.*##' $files | grep -oE '(let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*([[:space:]]*:[[:space:]]*Suite)?[[:space:]]*=[[:space:]]*Suite\(' | sed -E 's/^(let|var)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\2/')"}; do
        [[ $registered =~ "(^|[^A-Za-z0-9_])$suite([^A-Za-z0-9_]|\$)" ]] ||
            unregistered+="Tests/$t: the Suite $suite isn't passed to runTests in main.swift, so it never runs"
    done
done
(( ${#unregistered} )) && { print -u2 -l -- $unregistered; exit 1 }

# The slowest first (by how long each took last time), so none of them starts last.
integer jobs=${TEST_JOBS:-$(sysctl -n hw.ncpu)}
[[ -n ${TEST_UI_MENUS:-} ]] && jobs=1
typeset -A took
for t in $tests; do [[ -f build/debug/$t/took ]] && took[$t]=$(<build/debug/$t/took) || took[$t]=0; done
queue=(${(f)"$(for t in $tests; do print -r -- "$took[$t] $t"; done | sort -rn | cut -d' ' -f2)"})

# Each test's output goes to this run's own file, so two runs at once don't read each other's, then
# to build/debug/<test>/output.txt.
tmp=$(mktemp -d -t tests)
run_test() {
    local t=$1 start=$EPOCHREALTIME
    build/debug/$t/$t > $tmp/$t.out 2>&1
    local rc=$?
    print -r -- $(( EPOCHREALTIME - start )) > build/debug/$t/took
    cp -f $tmp/$t.out build/debug/$t/output.txt
    return $rc
}

typeset -A finished running  # a test that ended: its status; one running: its process
failed=()
integer ran=0 shown=0
show() {  # prints test $1's output under its name, and counts what it ran
    print -P "%B── $1%b"
    cat $tmp/$1.out
    (( finished[$1] == 0 )) || failed+=$1
    # runTests ends with "N passed, M failed".
    local output=(${(f)"$(<$tmp/$1.out)"})
    [[ ${output[-1]:-} =~ '^([0-9]+) passed, ([0-9]+) failed$' ]] && ran+=$(( match[1] + match[2] ))
}
stop_tree() {  # a process and every process under it
    local child
    for child in ${(f)"$(pgrep -P $1)"}; do [[ -n $child ]] && stop_tree $child; done
    kill -TERM $1
}
# Stopped (^C, a TERM): the tests still running stop too, those that ended are shown, and those that
# didn't are named, with where their output so far is.
interrupted() {
    setopt local_options no_err_exit
    local t pid
    for pid in ${(v)running}; do stop_tree $pid; done 2> /dev/null
    for t in ${tests[shown+1,-1]}; do
        if (( ${+finished[$t]} )); then
            show $t
        elif [[ -e $tmp/$t.out ]]; then
            cp -f $tmp/$t.out build/debug/$t/output.txt
            print -u2 "test.sh: $t was stopped; its output so far is in build/debug/$t/output.txt"
        fi
    done
    exit 130
}
trap 'rm -rf -- "$tmp"' EXIT
trap interrupted INT TERM HUP

mkfifo $tmp/done
exec {done}<>$tmp/done      # each test writes "name status" here as it ends
while (( shown < ${#tests} )); do
    while (( ${#running} < jobs && ${#queue} )); do
        # A job started with & ignores ^C, and so would the test it runs: give it back.
        ( trap - INT QUIT; run_test $queue[1]; print -r -- "$queue[1] $?" >&$done ) &
        running[$queue[1]]="$!"
        shift queue
    done
    read -r -u $done t rc
    unset "running[$t]"; finished[$t]=$rc
    # Print, in order, every test that's done up to the first that isn't.
    while (( shown < ${#tests} )) && (( ${+finished[${tests[shown+1]}]} )); do
        shown+=1
        show ${tests[shown]}
    done
done
exec {done}>&-
(( ${#failed} )) && print -u2 "FAILED: ${(j:, :)failed}"
[[ -n ${TEST_FILTER:-} ]] && (( ran == 0 )) && { print -u2 "TEST_FILTER=$TEST_FILTER matched no tests"; exit 1 }
(( ${#failed} )) && exit 1
print "all test executables passed"
