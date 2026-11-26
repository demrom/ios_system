#!/bin/bash
# Run on the Simulator already owned by the standalone test suite.
set -euo pipefail
sim=${1:?Pass the owned Simulator UUID}
probe=${2:?Pass the compiled native-pipeline probe}
work=${probe%/*}
mkdir "$work/tree"
for ((i=0; i<10000; i++)); do
    printf 'x PATTERN abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz\n' > "$work/tree/f$i.txt"
done
printf 'one\ntwo\n' > "$work/short"
failed=0
run() {
    local label=$1 expected=$2 command=$3 status=0
    xcrun simctl spawn "$sim" "$probe" "$join" "$command" > "$work/$label.out" 2> "$work/$label.err" || status=$?
    if [[ $status != "$expected" ]] || ! grep -Eq "^RESULT returned=[0-9]+ status=$expected$" "$work/$label.err"; then
        printf 'PIPELINE %s: expected=%s exit=%s FAIL\n' "$label" "$expected" "$status" >&2
        tail -18 "$work/$label.err" >&2
        failed=1
        return 1
    fi
    return 0
}
check() {
    local label=$1 expected=$2 command=$3
    shift 3
    if run "$label" "$expected" "$command"; then
        if "$@"; then
            printf 'PIPELINE %s: PASS\n' "$label"
        else
            printf 'PIPELINE %s: output mismatch FAIL\n' "$label" >&2
            failed=1
        fi
    fi
}
# Output assertions are called by check after the exit status is validated.
# shellcheck disable=SC2329
lines() { [[ $(wc -l < "$1") -eq $2 ]]; }
# shellcheck disable=SC2329
pager_output() {
    grep -Eq '^WRITER interrupted after [0-9]+ lines$' "$work/$1.err" &&
        grep -Fxq 'FOLLOWUP returned=0 status=0' "$work/$1.err" &&
        grep -Fq 'x 000000' "$work/$1.out"
}

for join in 0 1; do
    check "short-$join" 0 'writer 2 | head' lines "$work/short-$join.out" 2
    check "cat-$join" 0 "cat '$work/short' | head" cmp "$work/short" "$work/cat-$join.out"
    check "nested-$join" 0 nested lines "$work/nested-$join.out" 10
    check "found-$join" 0 "rg one '$work/short'" grep -Fxq one "$work/found-$join.out"
    check "missing-$join" 1 "rg NO_SUCH_PATTERN '$work/short'" test ! -s "$work/missing-$join.out"
    check "invalid-$join" 2 "rg '[' '$work/short'" test ! -s "$work/invalid-$join.out"
    check "unredirected-$join" 0 'writer 10000 | head' lines "$work/unredirected-$join.out" 10
    check "early-$join" 0 "writer 10000 | head > '$work/early-$join.file'" lines "$work/early-$join.file" 10
    check "three-stage-$join" 0 "writer 10000 | cat | head > '$work/three-stage-$join.file'" lines "$work/three-stage-$join.file" 10
    for pager in less more; do
        check "$pager-$join" 0 "writer 10000 | cat | $pager" pager_output "$pager-$join"
    done
    check "grep-$join" 0 "grep -r x '$work/tree' | head > '$work/grep-$join.file'" lines "$work/grep-$join.file" 10
    check "rg-$join" 0 "rg x '$work/tree' | head > '$work/rg-$join.file'" lines "$work/rg-$join.file" 10
    check "late-$join" 0 "late 10000 | head > '$work/late-$join.file'" lines "$work/late-$join.file" 10
done
exit "$failed"
