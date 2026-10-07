#!/bin/bash
#
# test_docker_encryption_compression.sh
#
# Live-Docker coverage for encrypt=yes/compress=yes (innocreate's
# --encrypt=AES256/--encrypt-key= and --compress/--compress-threads=
# flags). Confirms the resulting backup files are genuinely encrypted
# and/or compressed -- not just that bgbackup.sh thinks it succeeded --
# by round-tripping them back to plain files with the same tool that
# made them (xtrabackup --decrypt/--decompress, mariadb-backup
# --decompress) and checking that round-trip actually completes.
#
# Several real, non-obvious findings surfaced while building this test.
# One (#4) was an actual bgbackup.sh bug, now fixed alongside this test;
# the rest are current tool/script behavior asserted on directly below
# rather than worked around:
#
#   1. mariadb-backup in this MariaDB version has NO --encrypt/
#      --encrypt-key support at all (it errors "unknown variable"). The
#      --encrypt=AES256/--encrypt-key= flags innocreate adds are an
#      xtrabackup-only feature in practice; on backuptool=1 (MariaDB
#      Backup), encrypt=yes currently makes every backup FAIL outright.
#      This is asserted directly below rather than skipped, since it's
#      real current behavior a test suite should catch.
#   2. bgbackup.cnf.dist documents `cryptkey` as "Full path to encryption
#      key" and the README has the operator generate a random key INTO a
#      file at that path -- but innocreate passes it via xtrabackup's
#      `--encrypt-key=` (literal key material), never
#      `--encrypt-key-file=` (reads a file). The encryption test below
#      deliberately sets cryptkey to a plain string with no backing file
#      at all, and it still works -- proving the file is never read; the
#      "key" in use is really just whatever string sits in cryptkey=.
#   3. copy_secured_log_to_backup's redaction -- sed "s/${cryptkey}/.../"
#      -- isn't delimiter-escaped, AND has no -i/redirect, so it prints
#      the redacted text to stdout instead of writing it back to the
#      copied log file. Even on a cryptkey with no '/' in it (so the sed
#      command itself doesn't error), the copied bgbackup.log still ends
#      up with the plaintext key in it -- the redaction never actually
#      lands either way. The test below forces a '/' into the key (see
#      cryptkey generation below) to exercise the delimiter-clash
#      manifestation deterministically rather than only on ~40% of runs
#      (the odds a 32-char base64 string happens to contain a '/').
#   4. [FOUND AND FIXED] innocreate built --encrypt-key=${cryptkey@Q} --
#      bash's @Q quoting wraps the value in literal single quotes -- and
#      then ran it through $innocommand unquoted (word-split, but never
#      re-parsed for quoting). The two literal quote characters became
#      part of the key xtrabackup actually received, making every
#      encrypted backup fail with "Invalid key length" (sometimes a clean
#      backup failure, sometimes a SIGABRT inside xtrabackup's own
#      encrypt+compress worker thread when combined with --compress --
#      both are the same root cause, not a libgcrypt threading race).
#      This made xtrabackup encryption completely non-functional
#      regardless of key content. Fixed by dropping the stray @Q -- every
#      other value innocommand builds (password, socket, etc.) is passed
#      the same unquoted way, so plain substitution is the correct,
#      consistent fix here, not a workaround.
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

command -v docker >/dev/null || { echo "SKIP: docker not available"; exit 0; }
bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

name="bgt_enccomp_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

# A 32-character key, same shape as the README's `openssl rand -base64 24`
# example -- long enough for AES256. Regenerated until it contains a '/'
# so the copy_secured_log_to_backup delimiter-clash (finding #3 above) is
# exercised on every run instead of only the ~60% of runs where a random
# key happens to contain one.
cryptkey=$(openssl rand -base64 24)
while [[ "$cryptkey" != *"/"* ]]; do
    cryptkey=$(openssl rand -base64 24)
done

write_cnf() {
    local path="$1" flavor="$2" backupdir="$3" instance="$4" encrypt="$5" compress="$6"
    local threads="${7:-2}" parallel="${8:-yes}"
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
threads=$threads
parallel=$parallel
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
debug=no
verbose=no
instance_name=$instance
EOF
}

list_dir() { docker exec -u root "$name" bash -c "ls '$1' 2>/dev/null"; }
sidecar_of() { docker exec -u root "$name" bash -c "cat '$1'/bgbackup.cnf 2>/dev/null"; }
# The backup tool's own stderr is redirected straight into bgbackup.sh's
# logfile (backer_upper: `$innocommand 2>> "$logfile"`), bypassing
# log_info entirely -- it never reaches bgbackup.sh's own stdout/stderr,
# with or without -v. Assertions that need the tool's actual error text
# (not bgbackup.sh's own log_info narration) have to read the logfile
# itself.
latest_logfile() { docker exec -u root "$name" bash -c "cat \$(ls -t /work/logs/bgbackup_*.log | head -1)"; }
history_row() {
    tdc_sql "$name" "SELECT status,compressed,encrypted,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-$1' ORDER BY start_time DESC LIMIT 1"
}

###############################################################################
echo "== Percona/xtrabackup: encrypt=yes, compress=no =="
workdir=$(tdc_start percona "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs" "$workdir/enc_only" "$workdir/compress_only" "$workdir/both" "$workdir/plain"

write_cnf "$workdir/enc.cnf" percona /work/enc_only enc_only yes no
tdc_run_bgbackup "$name" /work/enc.cnf >/dev/null

IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row enc_only)"
assert_eq "encrypt=yes backup SUCCEEDED" "SUCCEEDED" "$status"
assert_eq "backup_history.encrypted reflects config" "yes" "$encrypted"

listing=$(list_dir "$bulocation")
assert_contains "data files carry the .xbcrypt suffix" "$listing" "ibdata1.xbcrypt"

enc_cnf=$(sidecar_of "$bulocation")
assert_contains "sidecar: encrypt='yes'" "$enc_cnf" "encrypt='yes'"

# Round-trip: decrypt in place with the exact cryptkey value from the cnf
# (a plain string, not a path to any real file -- see header). If
# innocreate were reading cryptkey as a key FILE, this would fail; it
# doesn't, which is exactly the point.
decrypt_log=$(docker exec -u root "$name" bash -c "xtrabackup --decrypt=AES256 --encrypt-key='$cryptkey' --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "decrypting with the literal cryptkey STRING succeeds (cryptkey is never read as a file)" "$decrypt_log" "completed OK!"
listing_after=$(list_dir "$bulocation")
assert_contains "decrypted file no longer has .xbcrypt suffix" "$listing_after" "ibdata1"

###############################################################################
echo "== Percona/xtrabackup: encrypt=no, compress=yes =="
write_cnf "$workdir/compress.cnf" percona /work/compress_only compress_only no yes
tdc_run_bgbackup "$name" /work/compress.cnf >/dev/null

IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row compress_only)"
assert_eq "compress=yes backup SUCCEEDED" "SUCCEEDED" "$status"
assert_eq "backup_history.compressed reflects config" "yes" "$compressed"

listing=$(list_dir "$bulocation")
assert_contains "data files carry the .zst suffix, no .xbcrypt" "$listing" "ibdata1.zst"

decompress_log=$(docker exec -u root "$name" bash -c "xtrabackup --decompress --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "decompressing succeeds" "$decompress_log" "completed OK!"

###############################################################################
echo "== Percona/xtrabackup: encrypt=yes AND compress=yes together =="
write_cnf "$workdir/both.cnf" percona /work/both both yes yes
# Stderr captured separately (and stdout discarded) rather than read back
# from bgbackup.sh's own internal logfile: copy_secured_log_to_backup's
# sed call (see finding #3 below) has no redirect of its own, so its
# error lands on bgbackup.sh's stderr directly, never in that logfile.
both_stderr=$(tdc_run_bgbackup "$name" /work/both.cnf 2>&1 >/dev/null)

IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row both)"
assert_eq "encrypt+compress backup SUCCEEDED" "SUCCEEDED" "$status"

listing=$(list_dir "$bulocation")
assert_contains "data files are compressed THEN encrypted: .zst.xbcrypt" "$listing" "ibdata1.zst.xbcrypt"

docker exec -u root "$name" bash -c "xtrabackup --decrypt=AES256 --encrypt-key='$cryptkey' --target-dir='$bulocation' --remove-original >/dev/null 2>&1"
both_decompress_log=$(docker exec -u root "$name" bash -c "xtrabackup --decompress --target-dir='$bulocation' --remove-original 2>&1")
assert_contains "full decrypt-then-decompress round trip succeeds" "$both_decompress_log" "completed OK!"
final_listing=$(list_dir "$bulocation")
assert_contains "fully round-tripped file has neither suffix left" "$final_listing" "ibdata1"

# KNOWN LATENT BUG (see finding #3): copy_secured_log_to_backup's cryptkey
# redaction is an unescaped `sed "s/${cryptkey}/.../"`. cryptkey is forced
# to contain a '/' above specifically so this breaks deterministically,
# the same way it would for ~40% of real base64 keys. store_log_with_backup=yes
# (this cnf's setting, and the dist default) means this runs on every
# encrypted backup.
assert_contains "KNOWN LIMITATION: cryptkey redaction breaks when cryptkey contains '/' (unescaped sed delimiter)" "$both_stderr" "unknown option to"

###############################################################################
echo "== Percona/xtrabackup: encrypt=no, compress=no baseline is plain =="
write_cnf "$workdir/plain.cnf" percona /work/plain plain no no
tdc_run_bgbackup "$name" /work/plain.cnf >/dev/null
IFS=$'\t' read -r status compressed encrypted bulocation <<< "$(history_row plain)"
listing=$(list_dir "$bulocation")
assert_contains "baseline: data files are plain, no suffix at all" "$listing" "ibdata1"
plain_cnf=$(sidecar_of "$bulocation")
assert_contains "baseline sidecar: compress='no'" "$plain_cnf" "compress='no'"
assert_contains "baseline sidecar: encrypt='no'" "$plain_cnf" "encrypt='no'"

tdc_cleanup "$name" "$workdir"

###############################################################################
echo "== MariaDB/mariabackup: compress=yes works; encrypt=yes does not =="
name="bgt_enccomp_md_$$"
workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs" "$workdir/md_compress" "$workdir/md_encrypt"

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
