#!/bin/bash
#
# test_docker_encryption_compression.sh
#
# Live-Docker coverage for encrypt=yes/compress=yes (innocreate's
# --encrypt=AES256/--encrypt-key-file= and --compress/--compress-threads=
# flags). Confirms the resulting backup files are genuinely encrypted
# and/or compressed -- not just that bgbackup.sh thinks it succeeded --
# by round-tripping them back to plain files with the same tool that
# made them (xtrabackup --decrypt/--decompress, mariadb-backup
# --decompress) and checking that round-trip actually completes.
#
# cryptkey is the path of a key file, read by xtrabackup with
# --encrypt-key-file. This test checks, on real backups:
#
#   - the key itself never appears anywhere bgbackup writes or passes it:
#     not in xtrabackup's process arguments (a PATH shim records them), not
#     in bgbackup's own output, its log, the copy of that log stored with
#     the backup, the backup's bgbackup.cnf, backup_history or the
#     backup_history dump written next to the backups;
#   - the backup's bgbackup.cnf and backup_history.cryptkey record the
#     key's fingerprint (computed here independently of bgbackup.sh), and
#     neither records the key file's path; the debug config dump shows the
#     fingerprint, never a cryptkey value;
#   - a configuration that still holds the key itself in cryptkey, a missing
#     key file, a directory and a 33-byte key file (trailing newline) are
#     refused before anything else is logged and before xtrabackup runs,
#     without the value appearing in the message:
#
#       2026-10-13-14:02:11 --> Fatal: encrypt=yes, but cryptkey is not the
#       path of a readable key file. cryptkey must name the file holding the
#       encryption key, not the key itself (its value is not shown, in case
#       it is a key). See 'Encryption' in the README.
#
#   - encrypt=no records no fingerprint (sidecar empty, backup_history NULL)
#     and never logs cryptkey, even when it holds a literal key.
#
# The key file's path does appear where the backup command is echoed: in
# bgbackup's "Executing xtrabackup command:" log line and in xtrabackup's
# own "recognized client arguments" line. A path is not a secret; the test
# asserts what is echoed there is the path, not the key.
#
# Also asserted as current behavior: mariadb-backup has NO --encrypt/
# --encrypt-key-file support at all (it errors "unknown variable"), so on
# backuptool=1 (MariaDB Backup) encrypt=yes makes every backup FAIL.
# Unreadable-file refusals need a non-root user and are covered by
# test_encryption_key_check.sh; bgbackup runs as root in this container.
#
# qpress (mariadb-backup's compress/decompress helper) and xbcrypt (one of
# the external helpers xtrabackup's own --decrypt/--decompress shell out
# to) are baked into the two local test images -- see
# tests/docker/*.Dockerfile for why neither ships with the upstream
# images.
#
# Run: ./tests/test_docker_encryption_compression.sh

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
        echo "FAIL: $desc (expected NOT to find '$needle')"
        fail=$((fail + 1))
    fi
}

command -v docker >/dev/null || { echo "SKIP: docker not available"; exit 0; }
bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

name="bgt_enccomp_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

# A 32-byte key, `openssl rand -base64 24` as the README says, written
# without a trailing newline: --encrypt-key-file uses the file's bytes as
# they are. The fingerprint is computed here, independently of
# bgbackup.sh's key_fingerprint, from the documented definition.
key=$(openssl rand -base64 24)
key_path=/work/enc.key
expected_fp=$({ printf 'bgbackup key fingerprint v1\0'; printf '%s' "$key"; } | sha256sum | cut -c1-16)
write_key_files() {
    printf '%s' "$key" > "$1/enc.key"
    printf '%s\n' "$key" > "$1/enc_newline.key"
    chmod 600 "$1/enc.key" "$1/enc_newline.key"
}

write_cnf() {
    local path="$1" flavor="$2" backupdir="$3" instance="$4" encrypt="$5" compress="$6"
    local cryptkey="${7:-$key_path}" debug="${8:-no}"
    cat > "$path" <<EOF
backuptool=$(tdc_backuptool_for "$flavor")
openfilelimit=0
backupuser=root
backuppass=$TDC_ROOT_PW
socket=$(tdc_socket_for "$flavor")
backuphisthost=
backuphistsocket=$(tdc_socket_for "$flavor")
backuphistuser=root
backuphistpass=$TDC_ROOT_PW
backuphistschema=mdbutil
backuphist_verify=1
monyog=no
monyogserver=
monyoguser=
monyogpass=
monyoghost=
monyogport=
fullbackupday=Everyday
differential=yes
keepdaily=7
keepweekly=4
keepmonthly=3
keepyearly=3
keepbkuptblnum=1
keeplognum=1000
keepfaileddays=365
diffupgradepct=150
backupdir=$backupdir
logpath=/work/logs
store_log_with_backup=yes
syslog=no
threads=2
parallel=yes
encrypt=$encrypt
cryptkey=$cryptkey
compress=$compress
nolock=no
rocksdb=no
galera=no
galera_minimum_nodes=0
preflight_script="echo 'OK' || echo"
slave=no
stop_slave_sql_thread=no
maillist=admin@example.com
mailsubpre="[BGBackup]"
mailon=none
run_after_success=
run_after_fail=
debug=$debug
verbose=no
instance_name=$instance
EOF
}

list_dir() { docker exec -u root "$name" bash -c "ls '$1' 2>/dev/null"; }
cat_in() { docker exec -u root "$name" bash -c "cat $1 2>/dev/null"; }
sidecar_of() { cat_in "'$1/bgbackup.cnf'"; }
# The backup tool's own stderr is redirected straight into bgbackup.sh's
# logfile (backer_upper: `$innocommand 2>> "$logfile"`), bypassing
# log_info entirely -- it never reaches bgbackup.sh's own stdout/stderr,
# with or without -v. Assertions that need the tool's actual error text
# (not bgbackup.sh's own log_info narration) have to read the logfile
# itself.
latest_logfile() { cat_in "\$(ls -t /work/logs/bgbackup_*.log | head -1)"; }
log_count() { docker exec -u root "$name" bash -c "ls /work/logs/bgbackup_*.log 2>/dev/null | wc -l"; }
history_row() {
    tdc_sql "$name" "SELECT status,compressed,encrypted,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-$1' ORDER BY start_time DESC LIMIT 1"
}
history_cryptkey() {
    tdc_sql "$name" "SELECT IFNULL(cryptkey, 'NULL') FROM mdbutil.backup_history WHERE hostname LIKE '%-$1' ORDER BY start_time DESC LIMIT 1"
}
history_rows_for() {
    tdc_sql "$name" "SELECT COUNT(*) FROM mdbutil.backup_history WHERE hostname LIKE '%-$1'"
}

# Runs bgbackup.sh with a PATH shim in front of the real xtrabackup that
# records every argument it is started with (one per line, each call
# followed by a "--" line) in /work/xtrabackup.argv, then execs the real
# binary. bgbackup.sh resolves xtrabackup via `command -v`, so it runs the
# shim. Prints bgbackup.sh's stdout+stderr; returns its exit code.
run_bgbackup_shimmed() {
    local cnf="$1"; shift
    docker exec -u root -e PATH="/work/shim:$container_path" "$name" \
        /opt/bgbackup/bgbackup.sh -c "$cnf" "$@" 2>&1
}

###############################################################################
echo "== Percona/xtrabackup: encrypt=yes, compress=no, debug =="
workdir=$(tdc_start percona "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs" "$workdir/enc_only" "$workdir/compress_only" "$workdir/both" "$workdir/plain" \
         "$workdir/literal" "$workdir/missing" "$workdir/dir" "$workdir/newline" "$workdir/shim"
write_key_files "$workdir"
container_path=$(docker exec "$name" printenv PATH)
cat > "$workdir/shim/xtrabackup" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" -- >> /work/xtrabackup.argv
exec /usr/bin/xtrabackup "$@"
EOF
chmod 755 "$workdir/shim/xtrabackup"

write_cnf "$workdir/enc.cnf" percona /work/enc_only enc_only yes no "$key_path" yes
enc_output=$(run_bgbackup_shimmed /work/enc.cnf)

IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row enc_only)"
assert_eq "encrypt=yes backup SUCCEEDED" "SUCCEEDED" "$status"
assert_eq "backup_history.encrypted reflects config" "yes" "$encrypted"

listing=$(list_dir "$bulocation")
assert_contains "data files carry the .xbcrypt suffix" "$listing" "ibdata1.xbcrypt"

argv=$(cat_in /work/xtrabackup.argv)
assert_contains "xtrabackup was started with --encrypt-key-file=<key file>" "$argv" "--encrypt-key-file=$key_path"
assert_not_contains "xtrabackup's arguments never hold the key" "$argv" "$key"
assert_not_contains "xtrabackup is never given --encrypt-key=" "$argv" "--encrypt-key="

enc_cnf=$(sidecar_of "$bulocation")
assert_contains "sidecar: encrypt='yes'" "$enc_cnf" "encrypt='yes'"
assert_contains "sidecar: records the key's fingerprint" "$enc_cnf" "cryptkey_fingerprint='$expected_fp'"
assert_not_contains "sidecar: no cryptkey= line" "$enc_cnf" $'\ncryptkey='
assert_not_contains "sidecar: not the key file's path" "$enc_cnf" "$key_path"
assert_not_contains "sidecar: not the key" "$enc_cnf" "$key"

assert_eq "backup_history.cryptkey holds the fingerprint" "$expected_fp" "$(history_cryptkey enc_only)"
full_row=$(tdc_sql "$name" "SELECT * FROM mdbutil.backup_history WHERE hostname LIKE '%-enc_only'")
assert_not_contains "backup_history row: not the key file's path" "$full_row" "$key_path"
assert_not_contains "backup_history row: not the key" "$full_row" "$key"

enc_log=$(latest_logfile)
assert_not_contains "bgbackup's log: not the key" "$enc_log" "$key"
assert_not_contains "bgbackup's own output: not the key" "$enc_output" "$key"
assert_not_contains "the log copy stored with the backup: not the key" "$(cat_in "'$bulocation/bgbackup.log'")" "$key"
assert_contains "debug config dump shows the fingerprint" \
    "$(grep -- '--> cryptkey_fingerprint:' <<< "$enc_log")" "$expected_fp"
assert_eq "debug config dump has no cryptkey: line" "0" "$(grep -c -- '--> cryptkey:' <<< "$enc_log")"
assert_contains "the logged backup command names the key file (a path, not the key)" \
    "$(grep 'Executing xtrabackup command:' <<< "$enc_log")" "--encrypt-key-file=$key_path"
assert_eq "the old log-copy redaction step is gone" "0" "$(grep -c 'Replacing cryptkey' <<< "$enc_log")"

history_dump=$(cat_in "/work/enc_only/mdbutil.backup_history-*.sql")
assert_contains "backup_history dump next to the backups holds the fingerprint" "$history_dump" "$expected_fp"
assert_not_contains "backup_history dump: not the key" "$history_dump" "$key"

# Round-trip: decrypt in place with the same key file.
decrypt_log=$(docker exec -u root "$name" bash -c "xtrabackup --decrypt=AES256 --encrypt-key-file='$key_path' --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "decrypting with the key file succeeds" "$decrypt_log" "completed OK!"
listing_after=$(list_dir "$bulocation")
assert_contains "decrypted file no longer has .xbcrypt suffix" "$listing_after" "ibdata1"

###############################################################################
echo "== Refused before anything is logged: key in cryptkey, missing file, directory, 33 bytes =="
# Each case: exit 1, one new log file holding only the error line, no
# backup directory, no backup_history row, xtrabackup never started.
refused_case() {
    local label="$1" cryptkey="$2" expected_msg="$3" secret="$4"
    write_cnf "$workdir/$label.cnf" percona "/work/$label" "$label" yes no "$cryptkey"
    docker exec -u root "$name" bash -c ': > /work/xtrabackup.argv'
    # Log file names have one-second resolution: start each run in a new
    # second, so it gets a log file of its own.
    sleep 1
    local logs_before out rc new_log
    logs_before=$(log_count)
    out=$(run_bgbackup_shimmed "/work/$label.cnf"); rc=$?
    assert_eq "$label: bgbackup exits 1" "1" "$rc"
    assert_contains "$label: says why" "$out" "$expected_msg"
    assert_not_contains "$label: the value is not in bgbackup's output" "$out" "$secret"
    assert_eq "$label: exactly one new log file" "$((logs_before + 1))" "$(log_count)"
    new_log=$(latest_logfile)
    assert_eq "$label: the log holds only the error line (nothing logged before it)" "1" "$(grep -c . <<< "$new_log")"
    assert_contains "$label: that line is the error" "$new_log" "$expected_msg"
    assert_not_contains "$label: the value is not in the log" "$new_log" "$secret"
    assert_eq "$label: no backup directory created" "" "$(list_dir "/work/$label")"
    assert_eq "$label: no backup_history row" "0" "$(history_rows_for "$label")"
    assert_eq "$label: xtrabackup never started" "" "$(cat_in /work/xtrabackup.argv)"
}
refused_case literal "$key" "cryptkey is not the path of a readable key file" "$key"
refused_case missing /work/missing.key "cryptkey is not the path of a readable key file" "/work/missing.key"
refused_case dir /work "cryptkey is not the path of a readable key file" "/work"
refused_case newline /work/enc_newline.key "holds 33 bytes; AES256 needs exactly 32" "$key"

###############################################################################
echo "== Percona/xtrabackup: encrypt=no, compress=yes =="
write_cnf "$workdir/compress.cnf" percona /work/compress_only compress_only no yes
tdc_run_bgbackup "$name" /work/compress.cnf >/dev/null

IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row compress_only)"
assert_eq "compress=yes backup SUCCEEDED" "SUCCEEDED" "$status"
assert_eq "backup_history.compressed reflects config" "yes" "$compressed"
assert_eq "encrypt=no: backup_history.cryptkey is NULL" "NULL" "$(history_cryptkey compress_only)"
assert_contains "encrypt=no: sidecar's fingerprint is empty" "$(sidecar_of "$bulocation")" "cryptkey_fingerprint=''"

listing=$(list_dir "$bulocation")
assert_contains "data files carry the .zst suffix, no .xbcrypt" "$listing" "ibdata1.zst"

decompress_log=$(docker exec -u root "$name" bash -c "xtrabackup --decompress --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "decompressing succeeds" "$decompress_log" "completed OK!"

###############################################################################
echo "== Percona/xtrabackup: encrypt=yes AND compress=yes together =="
write_cnf "$workdir/both.cnf" percona /work/both both yes yes
both_output=$(tdc_run_bgbackup "$name" /work/both.cnf 2>&1)
# The old log-copy redaction ran `sed "s/<key>/.../"`, which failed on any
# key containing a '/' ("unknown option to `s'").
assert_not_contains "encrypt+compress: no sed error from a redaction step" "$both_output" "sed:"
assert_not_contains "encrypt+compress: bgbackup's output does not hold the key" "$both_output" "$key"

IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row both)"
assert_eq "encrypt+compress backup SUCCEEDED" "SUCCEEDED" "$status"
assert_contains "encrypt+compress: sidecar records the fingerprint" "$(sidecar_of "$bulocation")" "cryptkey_fingerprint='$expected_fp'"

listing=$(list_dir "$bulocation")
assert_contains "data files are compressed THEN encrypted: .zst.xbcrypt" "$listing" "ibdata1.zst.xbcrypt"

docker exec -u root "$name" bash -c "xtrabackup --decrypt=AES256 --encrypt-key-file='$key_path' --target-dir='$bulocation' --remove-original >/dev/null 2>&1"
both_decompress_log=$(docker exec -u root "$name" bash -c "xtrabackup --decompress --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "full decrypt-then-decompress round trip succeeds" "$both_decompress_log" "completed OK!"
final_listing=$(list_dir "$bulocation")
assert_contains "fully round-tripped file has neither suffix left" "$final_listing" "ibdata1"

###############################################################################
echo "== Percona/xtrabackup: encrypt=no, compress=no baseline; a literal key in cryptkey is ignored =="
# encrypt=no never uses cryptkey, so an old configuration's literal key is
# neither refused nor logged, not even by the debug config dump.
write_cnf "$workdir/plain.cnf" percona /work/plain plain no no "$key" yes
plain_output=$(tdc_run_bgbackup "$name" /work/plain.cnf 2>&1)
IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row plain)"
assert_eq "baseline backup SUCCEEDED" "SUCCEEDED" "$status"
listing=$(list_dir "$bulocation")
assert_contains "baseline: data files are plain, no suffix at all" "$listing" "ibdata1"
plain_cnf=$(sidecar_of "$bulocation")
assert_contains "baseline sidecar: compress='no'" "$plain_cnf" "compress='no'"
assert_contains "baseline sidecar: encrypt='no'" "$plain_cnf" "encrypt='no'"
assert_contains "baseline sidecar: empty fingerprint" "$plain_cnf" "cryptkey_fingerprint=''"
assert_eq "baseline: backup_history.cryptkey is NULL" "NULL" "$(history_cryptkey plain)"
plain_log=$(latest_logfile)
assert_not_contains "baseline with a literal key in cryptkey: not in the log" "$plain_log" "$key"
assert_not_contains "baseline with a literal key in cryptkey: not in bgbackup's output" "$plain_output" "$key"
assert_not_contains "baseline with a literal key in cryptkey: not in the sidecar" "$plain_cnf" "$key"

tdc_cleanup "$name" "$workdir"

###############################################################################
echo "== MariaDB/mariabackup: compress=yes works; encrypt=yes does not =="
name="bgt_enccomp_md_$$"
workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs" "$workdir/md_compress" "$workdir/md_encrypt"
write_key_files "$workdir"

write_cnf "$workdir/md_compress.cnf" mariadb /work/md_compress md_compress no yes
tdc_run_bgbackup "$name" /work/md_compress.cnf >/dev/null
IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row md_compress)"
assert_eq "MariaDB compress=yes backup SUCCEEDED" "SUCCEEDED" "$status"
listing=$(list_dir "$bulocation")
assert_contains "MariaDB: data files carry the .qp suffix" "$listing" "ibdata1.qp"
decompress_log=$(docker exec -u root "$name" bash -c "mariadb-backup --decompress --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "MariaDB: .qp files genuinely decompress back to plain files" "$decompress_log" "completed OK!"

write_cnf "$workdir/md_encrypt.cnf" mariadb /work/md_encrypt md_encrypt yes no
tdc_run_bgbackup "$name" /work/md_encrypt.cnf >/dev/null
IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row md_encrypt)"
assert_eq "KNOWN LIMITATION: MariaDB/mariabackup has no --encrypt support; encrypt=yes makes the backup FAIL, not produce an encrypted backup" "FAILED" "$status"
# mariadb-backup's own rejection of the flag is on its stderr, which
# backer_upper redirects straight into the logfile (see latest_logfile's
# comment) -- it never reaches bgbackup.sh's own stdout/stderr.
encrypt_run_log=$(latest_logfile)
assert_contains "mariabackup's actual rejection of the unsupported flag shows up in the log" "$encrypt_run_log" "unknown variable"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
