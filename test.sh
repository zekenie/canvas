#!/bin/zsh
# Builds every module but the app (debug), runs every test executable (a failing one doesn't stop
# the others), and exits non-zero if any failed. TEST_FILTER=substring runs only the tests whose
# "Suite: test" name contains it, and fails if that's none at all.
set -uo pipefail
cd "${0:A:h}"
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

failed=()
integer ran=0
for t in $tests; do
    print -P "%B── $t%b"
    build/debug/$t/$t | tee build/debug/$t/output.txt
    (( pipestatus[1] == 0 )) || failed+=$t
    # runTests ends with "N passed, M failed".
    output=(${(f)"$(<build/debug/$t/output.txt)"})
    [[ ${output[-1]:-} =~ '^([0-9]+) passed, ([0-9]+) failed$' ]] && ran+=$(( match[1] + match[2] ))
done
(( ${#failed} )) && print -u2 "FAILED: ${(j:, :)failed}"
[[ -n ${TEST_FILTER:-} ]] && (( ran == 0 )) && { print -u2 "TEST_FILTER=$TEST_FILTER matched no tests"; exit 1 }
(( ${#failed} )) && exit 1
print "all test executables passed"
