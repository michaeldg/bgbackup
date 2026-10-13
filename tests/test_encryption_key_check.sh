#!/bin/bash
#
# test_encryption_key_check.sh
#
# Fixture-based test for key_fingerprint() and check_encryption_key() in
# bgbackup.sh: with encrypt=yes, cryptkey must be the path of a readable
# 32-byte key file, and bgbackup records that key's fingerprint instead of
# the key or its path. Every refusal goes through log_error (logged, printed
# on stderr, exit 1) without ever showing cryptkey's value, which in an
# older configuration is the key itself:
#
#   2026-10-13-14:02:11 --> Fatal: encrypt=yes, but cryptkey is not the path
#   of a readable key file. cryptkey must name the file holding the
#   encryption key, not the key itself (its value is not shown, in case it is
#   a key). See 'Encryption' in the README.
#
# The fingerprint is pinned to a known answer (computed independently with
# Python's hashlib: sha256(b"bgbackup key fingerprint v1\0" + key)[:16]), so
# a change to its definition -- which would make every recorded fingerprint
# stop matching -- fails here. The live-Docker side (the check really runs
# before anything is logged, the fingerprint really lands in the sidecar and
# backup_history) is in test_docker_encryption_compression.sh.
#
# key_fingerprint, check_encryption_key, log_error, log_info and mail_log are
# extracted live out of bgbackup.sh (tdc_extract_function). Each
# check_encryption_key case runs in a subshell, since log_error exits.
#
# Run: ./tests/test_encryption_key_check.sh

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

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "PASS: $desc"; pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected NOT to find '$needle')"; echo "   in: $haystack"
        fail=$((fail + 1))
    fi
}

bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

for fn in key_fingerprint check_encryption_key log_error log_info mail_log; do
    src=$(tdc_extract_function "$fn" "$bgbackup_sh")
    if [[ -z "$src" ]]; then
        echo "FAIL: could not extract $fn() out of $bgbackup_sh -- has it been renamed?"
        exit 1
    fi
    eval "$src"
done

work=$(mktemp -d)
trap 'chmod -R u+rwx "$work" 2>/dev/null; rm -rf "$work"' EXIT

# Stub the real `mail` binary, recording that it was called.
mail() { : > "$work/mail_called"; cat >/dev/null; }

###############################################################################
echo "== key_fingerprint =="

printf '%s' '0123456789abcdef0123456789abcdef' > "$work/known.key"
assert_eq "known answer: fingerprint of the key '0123456789abcdef0123456789abcdef'" \
    "1fd0a25cbe954920" "$(key_fingerprint "$work/known.key")"

assert_eq "same as the documented one-liner (README)" \
    "$({ printf 'bgbackup key fingerprint v1\0'; cat "$work/known.key"; } | sha256sum | cut -c1-16)" \
    "$(key_fingerprint "$work/known.key")"

plain_sha=$(sha256sum < "$work/known.key" | cut -c1-16)
[[ "$plain_sha" != "$(key_fingerprint "$work/known.key")" ]]
assert_eq "differs from the key file's plain SHA-256 (the label separates them)" "0" "$?"

assert_eq "16 lowercase hex digits" "1" \
    "$(key_fingerprint "$work/known.key" | grep -cE '^[0-9a-f]{16}$')"

# Every byte counts, including a trailing newline: xtrabackup uses the
# file's bytes as they are, so a key file with a newline is another key.
printf '%s\n' '0123456789abcdef0123456789abcdef' > "$work/known_nl.key"
[[ "$(key_fingerprint "$work/known_nl.key")" != "$(key_fingerprint "$work/known.key")" ]]
assert_eq "a trailing newline changes the fingerprint" "0" "$?"

# Binary keys (NUL bytes, high bytes) are hashed as raw bytes, not as text.
head -c 32 /dev/urandom > "$work/binary.key"
printf '\0\0\377abc' >> "$work/binary.key"
assert_eq "binary key with NUL bytes: same value as hashing the raw bytes" \
    "$({ printf 'bgbackup key fingerprint v1\0'; cat "$work/binary.key"; } | sha256sum | cut -c1-16)" \
    "$(key_fingerprint "$work/binary.key")"

label_only=$(printf 'bgbackup key fingerprint v1\0' | sha256sum | cut -c1-16)

out=$(key_fingerprint "$work/missing.key"); rc=$?
assert_eq "missing file: fails" "1" "$rc"
assert_eq "missing file: prints nothing (not the label's own fingerprint)" "" "$out"

mkdir "$work/a_directory"
out=$(key_fingerprint "$work/a_directory"); rc=$?
assert_eq "directory: fails" "1" "$rc"
assert_eq "directory: prints nothing" "" "$out"

out=$(key_fingerprint ""); rc=$?
assert_eq "empty path: fails" "1" "$rc"

if [[ "$(id -u)" -ne 0 ]]; then
    printf '%s' '0123456789abcdef0123456789abcdef' > "$work/unreadable.key"
    chmod 000 "$work/unreadable.key"
    out=$(key_fingerprint "$work/unreadable.key"); rc=$?
    assert_eq "unreadable file: fails" "1" "$rc"
    assert_not_contains "unreadable file: never prints the label-only fingerprint" "$out" "$label_only"
else
    echo "SKIP: unreadable-file cases (running as root, which reads any file)"
fi

# A path starting with '-' is a file, not an option to cat.
printf '%s' '0123456789abcdef0123456789abcdef' > "$work/-dash.key"
assert_eq "path starting with '-' is read as a file" "1fd0a25cbe954920" \
    "$(cd "$work" && key_fingerprint "-dash.key")"

###############################################################################
echo "== check_encryption_key =="

# Runs check_encryption_key with encrypt=$1 and cryptkey=$2 in a subshell.
# Sets last_rc, last_stderr, last_log (the logfile's content) and
# last_fingerprint (what the check left in cryptkey_fingerprint, if it
# returned).
run_check() {
    local encrypt_setting="$1" cryptkey_setting="$2"
    local logf="$work/check.log"
    rm -f "$logf" "$work/mail_called" "$work/fp"
    (
        encrypt="$encrypt_setting"
        cryptkey="$cryptkey_setting"
        cryptkey_fingerprint="stale value from an earlier run"
        logfile="$logf"
        verbose=no syslog=no mailon=failure maillist=admin@example.com
        mailsubpre="[BGBackup]" instance_name="" mdate=01/01/26 log_status=""
        check_encryption_key
        printf '%s' "$cryptkey_fingerprint" > "$work/fp"
    ) 2> "$work/stderr" >/dev/null
    last_rc=$?
    last_stderr=$(cat "$work/stderr")
    last_log=$(cat "$logf" 2>/dev/null)
    last_fingerprint=$(cat "$work/fp" 2>/dev/null)
}

literal_key='Zm9vYmFyYmF6cXV4/3J0eXVpb3Bhc2Rm'   # 32 chars, like openssl rand -base64 24

# 1. A literal key in cryptkey (the old, documented-wrong usage).
run_check yes "$literal_key"
assert_eq "literal key: refused (exit 1)" "1" "$last_rc"
assert_contains "literal key: says cryptkey is not a readable key file" "$last_stderr" \
    "encrypt=yes, but cryptkey is not the path of a readable key file"
assert_not_contains "literal key: the key is not on stderr" "$last_stderr" "$literal_key"
assert_not_contains "literal key: the key is not in the log" "$last_log" "$literal_key"
assert_eq "literal key: the log holds only the error line" "1" "$(grep -c . <<< "$last_log")"
assert_eq "literal key: mailon=failure mails the (key-free) log" "yes" \
    "$([[ -f "$work/mail_called" ]] && echo yes || echo no)"

# 2. Missing file, directory, empty value.
run_check yes "$work/no-such.key"
assert_eq "missing key file: refused" "1" "$last_rc"
assert_contains "missing key file: clear message" "$last_stderr" "is not the path of a readable key file"
assert_not_contains "missing key file: the path is not shown either" "$last_stderr" "$work/no-such.key"

run_check yes "$work/a_directory"
assert_eq "directory as key file: refused" "1" "$last_rc"
assert_contains "directory as key file: clear message" "$last_stderr" "is not the path of a readable key file"

run_check yes ""
assert_eq "encrypt=yes with an empty cryptkey: refused" "1" "$last_rc"
assert_contains "empty cryptkey: clear message" "$last_stderr" "is not the path of a readable key file"

# 3. Unreadable file (only meaningful when not root).
if [[ "$(id -u)" -ne 0 ]]; then
    run_check yes "$work/unreadable.key"
    assert_eq "unreadable key file: refused" "1" "$last_rc"
    assert_contains "unreadable key file: clear message" "$last_stderr" "is not the path of a readable key file"
fi

# 4. Wrong size: AES256 needs exactly 32 bytes.
run_check yes "$work/known_nl.key"
assert_eq "33-byte key file (trailing newline): refused" "1" "$last_rc"
assert_contains "33-byte key file: says how many bytes and that a newline counts" "$last_stderr" \
    "holds 33 bytes; AES256 needs exactly 32 (a trailing newline counts)"
assert_not_contains "33-byte key file: the key is not shown" "$last_stderr" "0123456789abcdef"

printf '%s' '0123456789abcdef0123456789abcde' > "$work/short.key"
run_check yes "$work/short.key"
assert_eq "31-byte key file: refused" "1" "$last_rc"
assert_contains "31-byte key file: says 31 bytes" "$last_stderr" "holds 31 bytes"

: > "$work/empty.key"
run_check yes "$work/empty.key"
assert_eq "empty key file: refused" "1" "$last_rc"
assert_contains "empty key file: says 0 bytes" "$last_stderr" "holds 0 bytes"

# 5. A good key file.
run_check yes "$work/known.key"
assert_eq "32-byte key file: accepted" "0" "$last_rc"
assert_eq "32-byte key file: nothing on stderr" "" "$last_stderr"
assert_eq "32-byte key file: nothing logged" "" "$last_log"
assert_eq "32-byte key file: cryptkey_fingerprint set to its fingerprint" "1fd0a25cbe954920" "$last_fingerprint"

# 6. encrypt=no: cryptkey is not used, whatever it holds, and no
# fingerprint is recorded (a stale one from the environment is cleared).
run_check no "$literal_key"
assert_eq "encrypt=no with a literal key in cryptkey: not refused" "0" "$last_rc"
assert_eq "encrypt=no: cryptkey_fingerprint is empty" "" "$last_fingerprint"
assert_eq "encrypt=no: nothing logged" "" "$last_log"

run_check no "$work/known.key"
assert_eq "encrypt=no with a valid key file: no fingerprint recorded" "" "$last_fingerprint"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
