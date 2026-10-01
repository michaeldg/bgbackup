#!/bin/bash

# test_expand_hour_spec.sh
#
# Fixture-based test for expand_hour_spec() in bgbackup.sh: turns a
# cron-style hour field (single value, comma list, step range, wildcard, or
# wildcard-step) into a sorted, deduplicated list of hours. Used by
# count_remaining_differentials to project how many more Differentials will
# run before the next scheduled Full (see differential_upgrade_needed).
#
# Pure bash, no database and no wall-clock dependency, so it's extracted and
# tested directly rather than driven through the DB-dependent functions that
# call it.
#
# The function is extracted live out of bgbackup.sh by name below, rather
# than hand-copied into this file, so the test always exercises the exact
# function currently shipped and can't quietly drift out of sync with it.
# Sourcing bgbackup.sh directly isn't an option: everything after the
# function definitions is top-level script that runs unconditionally on
# source and needs a live bgbackup.cnf and MariaDB/MySQL instance to even
# get past its own preflight checks.
#
# Run: ./tests/test_expand_hour_spec.sh

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
        echo "FAIL: $desc"
        echo "   expected: $expected"
        echo "   actual:   $actual"
        fail=$((fail + 1))
    fi
}

bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

func_src=$(awk '
    /^function expand_hour_spec[[:space:]]*\{/ { found = 1 }
    found { print; if ($0 == "}") exit }
' "$bgbackup_sh")

if [[ -z "$func_src" ]]; then
    echo "FAIL: could not extract expand_hour_spec() out of $bgbackup_sh -- has it been renamed?"
    exit 1
fi
eval "$func_src"

run() { expand_hour_spec "$1" | paste -sd, -; }

assert_eq "single value" \
    "9" "$(run "9")"

assert_eq "comma list is sorted and deduplicated" \
    "0,1,5" "$(run "5,1,5,1,0")"

assert_eq "wildcard expands to every hour" \
    "$(seq -s, 0 23)" "$(run "*")"

assert_eq "wildcard-step expands with the given stride" \
    "0,6,12,18" "$(run "*/6")"

assert_eq "plain range expands inclusive" \
    "9,10,11,12,13,14,15,16,17" "$(run "9-17")"

assert_eq "range-step expands with the given stride" \
    "0,5,10,15,20" "$(run "0-20/5")"

assert_eq "an unparseable fragment is silently skipped, not fatal" \
    "5" "$(run "abc,5")"

assert_eq "combining forms unions and sorts the result" \
    "0,5,8,16" "$(run "*/8,5")"

assert_eq "empty spec yields nothing" \
    "" "$(run "")"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
