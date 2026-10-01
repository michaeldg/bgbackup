#!/bin/bash

# test_daily_sequence_absent.sh
#
# Regression guard: daily_sequence / dailysequence tracking (a per-backup
# sequence-number-of-the-day field written into each backup's own
# bgbackup.cnf) was added and then fully removed again in the same
# development session, once hour-based restore-copy selection replaced
# sequence-number-based selection. Fail loudly if it (or any
# case-variant/underscore-variant spelling) ever creeps back in -- whether
# as a reintroduction of the old approach or a leftover from a bad merge.
#
# Run: ./tests/test_daily_sequence_absent.sh

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bgbackup_sh="$script_dir/../bgbackup.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected '$expected', got '$actual')"
        fail=$((fail + 1))
    fi
}

bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

hit_count=$(grep -ciE 'daily_sequence|dailysequence' "$bgbackup_sh")
assert_eq "no daily_sequence/dailysequence reference anywhere in bgbackup.sh" "0" "$hit_count"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
