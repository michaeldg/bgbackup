#!/bin/bash
#
# test_preflight_check.sh
#
# Fixture-based test for preflight_check() in bgbackup.sh -- the three-way
# contract between bgbackup.sh and an operator-supplied preflight_script:
#
#   - "OK" (exact match): proceeds to take the backup.
#   - "NO_ERROR;<anything>": logs the output and exits 0 -- no backup is
#     taken, but this is NOT an error (e.g. used to deliberately skip a
#     backup on a node that shouldn't run one right now).
#   - anything else: calls log_error(), which logs, mails $maillist when
#     mailon is "failure"/"all", and exits 1.
#
# The NO_ERROR; branch is a literal 9-character prefix check
# (${preflight_return_value:0:9} == "NO_ERROR;"), not a general pattern --
# this file includes a boundary regression guard on that exact cutoff: an
# 8-char "NO_ERROR" with no semicolon, and a 9-char string whose last
# character isn't ';', must both still be treated as an error.
#
# preflight_check, log_error, log_info and mail_log are extracted live out
# of bgbackup.sh (same technique as tests/test_expand_hour_spec.sh) so this
# exercises the exact shipped logic, not a reimplementation. The real `mail`
# binary is stubbed (just records that it was invoked) since no MTA is
# available in a plain fixture test; syslog=no avoids needing a `logger`
# stub too.
#
# Each case runs preflight_check in a subshell so its exit (0 or log_error's
# exit 1) doesn't end this test script.
#
# Run: ./tests/test_preflight_check.sh

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bgbackup_sh="$script_dir/../bgbackup.sh"
# shellcheck source=lib/docker_common.sh
source "$script_dir/lib/docker_common.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"; pass=$((pass + 1))
    else
        echo "FAIL: $desc"; echo "   expected: $expected"; echo "   actual:   $actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS: $desc"; pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected to find '$needle')"; echo "   in: $haystack"
        fail=$((fail + 1))
    fi
}

bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

for fn in preflight_check log_error log_info mail_log; do
    src=$(tdc_extract_function "$fn" "$bgbackup_sh")
    if [[ -z "$src" ]]; then
        echo "FAIL: could not extract $fn() out of $bgbackup_sh -- has it been renamed?"
        exit 1
    fi
    eval "$src"
done

# Stub the real `mail` binary: record that it was invoked (via a flag file,
# since this runs across a subshell boundary -- see run_preflight) and
# drain stdin so mail_log's redirect doesn't block.
mail() {
    : > "$mail_flag_file"
    cat >/dev/null
}

# Runs preflight_check with $1 as the preflight_script output and $2 as
# mailon, in a fresh logfile/mail-flag pair each time. NOT called via
# command substitution by callers -- that would fork its own subshell and
# lose every one of these assignments -- so it sets $last_exit_code,
# $last_logfile and $last_mail_invoked directly for the caller to inspect
# afterwards.
run_preflight() {
    local script="$1" mailon_setting="${2:-none}"
    last_logfile=$(mktemp)
    mail_flag_file=$(mktemp)
    rm -f "$mail_flag_file"

    (
        preflight_script="$script"
        debug=no
        verbose=no
        syslog=no
        mailon="$mailon_setting"
        maillist=admin@example.com
        mailsubpre="[BGBackup]"
        instance_name=
        mdate=01/01/26
        logfile="$last_logfile"
        # Real bgbackup.sh runs without `set -u` and log_status isn't set
        # yet at the point preflight_check runs (log_check, which sets it,
        # only runs after a backup attempt) -- mail_log's "$log_status" is
        # an unset-var reference there too; mirror that here as an empty
        # string rather than letting this file's own `set -u` turn it into
        # a crash that's specific to the test harness, not real behavior.
        log_status=""
        preflight_check
    )
    last_exit_code=$?

    last_mail_invoked=0
    [[ -f "$mail_flag_file" ]] && last_mail_invoked=1
    rm -f "$mail_flag_file"
}

###############################################################################
echo "== exact 'OK' proceeds, no error, no mail =="
run_preflight "echo 'OK'"
assert_eq "exit code 0 on OK" "0" "$last_exit_code"
assert_eq "mail not invoked on OK" "0" "$last_mail_invoked"
assert_contains "logs that it's proceeding" "$(cat "$last_logfile")" "Preflight check was OK, proceeding to take backup"
rm -f "$last_logfile"

###############################################################################
echo "== NO_ERROR; prefix: logs output, exits 0, no mail (not an error) =="
run_preflight "echo 'NO_ERROR;standby node, skipping intentionally'" "all"
assert_eq "exit code 0 on NO_ERROR;" "0" "$last_exit_code"
assert_eq "mail NOT invoked on NO_ERROR; even with mailon=all" "0" "$last_mail_invoked"
assert_contains "logs the preflight output" "$(cat "$last_logfile")" "standby node, skipping intentionally"
assert_contains "logs the no-error explanation" "$(cat "$last_logfile")" "no error with this situation"
rm -f "$last_logfile"

###############################################################################
echo "== anything else: log_error, exit 1, mails when mailon=failure/all =="
run_preflight "echo 'disk full on backup target'" "failure"
assert_eq "exit code 1 on arbitrary preflight failure text" "1" "$last_exit_code"
assert_eq "mail invoked when mailon=failure" "1" "$last_mail_invoked"
assert_contains "logs the failure reason" "$(cat "$last_logfile")" "Not creating a backup because preflight check failed"
rm -f "$last_logfile"

run_preflight "echo 'disk full on backup target'" "none"
assert_eq "exit code still 1 when mailon=none" "1" "$last_exit_code"
assert_eq "mail NOT invoked when mailon=none" "0" "$last_mail_invoked"
rm -f "$last_logfile"

###############################################################################
echo "== NO_ERROR; boundary: the match is an exact 9-char literal prefix =="

# 8 chars, no trailing semicolon at all -- must NOT match.
run_preflight "echo 'NO_ERROR'"
assert_eq "'NO_ERROR' (no semicolon) is treated as an error, not NO_ERROR;" "1" "$last_exit_code"
rm -f "$last_logfile"

# 9 chars, but the 9th character is not ';' -- must NOT match.
run_preflight "echo 'NO_ERRORX'"
assert_eq "'NO_ERRORX' (9th char not ';') is treated as an error" "1" "$last_exit_code"
rm -f "$last_logfile"

# Exactly the 9-char literal, nothing after it -- must match.
run_preflight "echo 'NO_ERROR;'"
assert_eq "'NO_ERROR;' alone (nothing after) still matches the prefix" "0" "$last_exit_code"
rm -f "$last_logfile"

# Lowercase -- the comparison is case-sensitive, must NOT match.
run_preflight "echo 'no_error;lowercase'"
assert_eq "lowercase 'no_error;' does not match (case-sensitive)" "1" "$last_exit_code"
rm -f "$last_logfile"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
