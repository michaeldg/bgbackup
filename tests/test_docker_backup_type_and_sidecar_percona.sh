#!/bin/bash
#
# test_docker_backup_type_and_sidecar_percona.sh
#
# Parallel pass of test_docker_backup_type_and_sidecar.sh against Percona
# Server + xtrabackup (backuptool=2), focused on the parts of innocreate
# that actually diverge by backuptool rather than re-running the whole
# Full/Differential/Incremental/diffupgradepct matrix a second time --
# that state machine itself is plain bash keyed off $differential and
# backup_history contents, not $backuptool, and the MariaDB pass already
# covers it exhaustively. What genuinely differs between the two tool
# families in innocreate:
#
#   - Tool detection: $backuptool=2 resolves to xtrabackup (innobackupex
#     was phased out of Percona XtraBackup 8.0), vs. mariabackup for
#     $backuptool=1. has_innobackupex ends up 0 either way with modern
#     tools, but that's exactly worth confirming rather than assuming.
#   - `--skip-rocksdb-backup` is only ever added when rocksdb=no AND
#     backuptool=1 (see innocreate) -- Percona Server doesn't carry
#     MyRocks the way MariaDB does, so this must stay absent for
#     backuptool=2 regardless of the rocksdb= setting.
#   - backuptool/xtrabackup_version recorded in backup_history and the
#     bgbackup.cnf sidecar reflect the actual tool in play.
#
# See tests/docker/percona-with-xtrabackup.Dockerfile for why a custom
# local image was needed (percona/percona-server:8.0 doesn't ship
# xtrabackup, and the package manager can't resolve its dependencies).
#
# Run: ./tests/test_docker_backup_type_and_sidecar_percona.sh

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

command -v docker >/dev/null || { echo "SKIP: docker not available"; exit 0; }
bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

name="bgt_type_sidecar_pxb_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

workdir=$(tdc_start percona "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/backups" "$workdir/logs"

cat > "$workdir/pxb.cnf" <<EOF
backuptool=2
openfilelimit=0
backupuser=root
backuppass=$TDC_ROOT_PW
socket=$(tdc_socket_for percona)
backuphisthost=
backuphistsocket=$(tdc_socket_for percona)
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
backupdir=/work/backups
logpath=/work/logs
store_log_with_backup=yes
syslog=no
threads=2
parallel=yes
encrypt=no
cryptkey=
compress=no
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
instance_name=pxbseries
EOF

sidecar_of() { docker exec -u root "$name" bash -c "cat $1/bgbackup.cnf 2>/dev/null"; }

echo "== Percona/xtrabackup: Full -> Differential =="
full_log=$(tdc_run_bgbackup "$name" /work/pxb.cnf -v 2>&1)
diff_log=$(tdc_run_bgbackup "$name" /work/pxb.cnf -v 2>&1)

mapfile -t rows < <(tdc_sql "$name" "SELECT uuid,butype,based_on_uuid,status,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-pxbseries' ORDER BY start_time")
assert_eq "two rows recorded" "2" "${#rows[@]}"

IFS=$'\t' read -r full_uuid full_type full_based full_status full_loc <<< "${rows[0]}"
IFS=$'\t' read -r diff_uuid diff_type diff_based diff_status diff_loc <<< "${rows[1]}"

assert_eq "run1 is Full" "Full" "$full_type"
assert_eq "run1 SUCCEEDED (xtrabackup actually ran against the real datadir)" "SUCCEEDED" "$full_status"
assert_eq "run2 is Differential" "Differential" "$diff_type"
assert_eq "run2 based_on_uuid points at the Full" "$full_uuid" "$diff_based"

full_cnf=$(sidecar_of "$full_loc")
assert_contains "Full sidecar: backuptool='2'" "$full_cnf" "backuptool='2'"
assert_contains "Full sidecar: xtrabackup_version is a parseable 'based on...' line" "$full_cnf" "based on"
assert_not_contains "Full sidecar: no incbase line" "$full_cnf" "incbase="

diff_cnf=$(sidecar_of "$diff_loc")
assert_contains "Differential sidecar: incbase points at the Full's directory" "$diff_cnf" "incbase='$full_loc'"

echo "== Flavor divergence: tool detection and rocksdb flag gating =="
assert_contains "innocreate resolved to the real xtrabackup binary" "$full_log" "Executing xtrabackup command:"
assert_not_contains "has_innobackupex is 0 for modern xtrabackup: no bare --incremental flag on the Full run" "$full_log" " --incremental "
assert_not_contains "rocksdb=no does NOT add --skip-rocksdb-backup for backuptool=2 (MyRocks is a MariaDB thing; innocreate gates this to backuptool=1 only)" "$full_log" "--skip-rocksdb-backup"
assert_contains "the Differential run DOES use --incremental-basedir" "$diff_log" "--incremental-basedir="

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
