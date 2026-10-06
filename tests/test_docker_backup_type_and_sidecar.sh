#!/bin/bash
#
# test_docker_backup_type_and_sidecar.sh
#
# Live-Docker coverage for the two highest-value, most load-bearing pieces
# of bgbackup.sh:
#
#   1. Full vs. Differential vs. Incremental selection (innocreate), plus
#      diffupgradepct's auto-upgrade-to-Full when a Differential's
#      projected chain size gets too large (differential_upgrade_needed).
#   2. The exact fields written to backup_history and into each backup's
#      own bgbackup.cnf sidecar (backup_history_and_mark_failed,
#      backup_write_config). This format is load-bearing for the sibling
#      Ansible role's chain_resolve.bash, which parses it.
#
# Runs real mariadb-backup against a real MariaDB server in Docker (see
# tests/lib/docker_common.sh and tests/docker/mariadb-with-bc.Dockerfile).
# Three independent "instances" (via instance_name) share one container so
# a Full/Differential/Incremental/upgrade series can each start from a
# clean backup_history, without needing four separate containers:
#   - diffseries:   differential=yes, Full -> Differential -> Differential
#   - incrseries:   differential=no,  Full -> Incremental -> Incremental
#   - upgseries:    differential=yes, exercises diffupgradepct's upgrade
#   - noupgseries:  differential=yes, confirms the upgrade does NOT fire
#                   when the projection stays under threshold
#
# keepdaily is set to 7 (a multiple of 7) and keepweekly to 4 (already
# >= ceil(7/7)) deliberately: bgbackup.sh's startup auto-bump logic for
# these (lines ~964-974) actually keys off a variable named $fullbackday,
# not the real $fullbackupday config var -- $fullbackday is never set
# anywhere, so that condition is always true regardless of fullbackupday.
# With these values the bump is a no-op (new == old), which keeps this
# test's retention numbers equal to what's configured instead of also
# having to replicate that (apparently unintentional) behavior here.
#
# Run: ./tests/test_docker_backup_type_and_sidecar.sh

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
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc"
        echo "   expected: $expected"
        echo "   actual:   $actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected to find '$needle')"
        echo "   in: $haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "PASS: $desc"
        pass=$((pass + 1))
    else
        echo "FAIL: $desc (expected NOT to find '$needle')"
        echo "   in: $haystack"
        fail=$((fail + 1))
    fi
}

command -v docker >/dev/null || { echo "SKIP: docker not available"; exit 0; }
bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

name="bgt_type_sidecar_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null

mkdir -p "$workdir/backups_diff" "$workdir/backups_incr" "$workdir/backups_upg" "$workdir/backups_noupg"

# Base config shared by every series in this file; only backupdir,
# instance_name, differential and (for the upgrade series) bgbackup_hour
# vary per series.
write_base_cnf() {
    local path="$1" backupdir="$2" instance="$3" differential="$4"
    cat > "$path" <<EOF
backuptool=1
openfilelimit=0
backupuser=root
backuppass=$TDC_ROOT_PW
socket=$(tdc_socket_for mariadb)
backuphisthost=
backuphistsocket=$(tdc_socket_for mariadb)
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
differential=$differential
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
instance_name=$instance
EOF
}
mkdir -p "$workdir/logs"

sidecar_of() {
    local pattern="$1"
    docker exec -u root "$name" bash -c "cat $pattern/bgbackup.cnf 2>/dev/null"
}

###############################################################################
echo "== Full -> Differential -> Differential (differential=yes) =="
write_base_cnf "$workdir/diff.cnf" /work/backups_diff diffseries yes
tdc_run_bgbackup "$name" /work/diff.cnf >/dev/null
tdc_run_bgbackup "$name" /work/diff.cnf >/dev/null
tdc_run_bgbackup "$name" /work/diff.cnf >/dev/null

mapfile -t diff_rows < <(tdc_sql "$name" "SELECT uuid,butype,based_on_uuid,status,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-diffseries' ORDER BY start_time")
assert_eq "diffseries: three rows recorded" "3" "${#diff_rows[@]}"

IFS=$'\t' read -r full_uuid full_type full_based full_status full_loc <<< "${diff_rows[0]}"
IFS=$'\t' read -r d1_uuid d1_type d1_based d1_status d1_loc <<< "${diff_rows[1]}"
IFS=$'\t' read -r d2_uuid d2_type d2_based d2_status d2_loc <<< "${diff_rows[2]}"

assert_eq "run1 is Full" "Full" "$full_type"
assert_eq "run1 based_on_uuid is NULL (no base)" "NULL" "$full_based"
assert_eq "run2 is Differential" "Differential" "$d1_type"
assert_eq "run2 based_on_uuid points at the Full" "$full_uuid" "$d1_based"
assert_eq "run3 is Differential" "Differential" "$d2_type"
assert_eq "run3 (second Differential) still bases on the Full, not run2's Differential" "$full_uuid" "$d2_based"
assert_eq "all three rows SUCCEEDED" "SUCCEEDED SUCCEEDED SUCCEEDED" "$full_status $d1_status $d2_status"

full_cnf=$(sidecar_of "$full_loc")
assert_contains "Full sidecar: butype='Full'" "$full_cnf" "butype='Full'"
assert_contains "Full sidecar: backuptool='1'" "$full_cnf" "backuptool='1'"
assert_contains "Full sidecar: compress='no'" "$full_cnf" "compress='no'"
assert_contains "Full sidecar: encrypt='no'" "$full_cnf" "encrypt='no'"
assert_contains "Full sidecar: galera='no'" "$full_cnf" "galera='no'"
assert_contains "Full sidecar: slave='no'" "$full_cnf" "slave='no'"
assert_contains "Full sidecar: stop_slave_sql_thread='no'" "$full_cnf" "stop_slave_sql_thread='no'"
assert_contains "Full sidecar: end_time field present and quoted" "$full_cnf" "end_time='"
assert_contains "Full sidecar: carries the cryptkey hint comment" "$full_cnf" "#cryptkey=your_crypt_key"
assert_not_contains "Full sidecar: no incbase line (nothing to base on)" "$full_cnf" "incbase="

diff_cnf=$(sidecar_of "$d1_loc")
assert_contains "Differential sidecar: butype='Differential'" "$diff_cnf" "butype='Differential'"
assert_contains "Differential sidecar: incbase points at the Full's directory" "$diff_cnf" "incbase='$full_loc'"

###############################################################################
echo "== Full -> Incremental -> Incremental (differential=no) =="
write_base_cnf "$workdir/incr.cnf" /work/backups_incr incrseries no
tdc_run_bgbackup "$name" /work/incr.cnf >/dev/null
tdc_run_bgbackup "$name" /work/incr.cnf >/dev/null
tdc_run_bgbackup "$name" /work/incr.cnf >/dev/null

mapfile -t incr_rows < <(tdc_sql "$name" "SELECT uuid,butype,based_on_uuid,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-incrseries' ORDER BY start_time")
assert_eq "incrseries: three rows recorded" "3" "${#incr_rows[@]}"

IFS=$'\t' read -r ifull_uuid ifull_type ifull_based ifull_loc <<< "${incr_rows[0]}"
IFS=$'\t' read -r i1_uuid i1_type i1_based i1_loc <<< "${incr_rows[1]}"
IFS=$'\t' read -r i2_uuid i2_type i2_based i2_loc <<< "${incr_rows[2]}"

assert_eq "run1 is Full" "Full" "$ifull_type"
assert_eq "run2 is Incremental" "Incremental" "$i1_type"
assert_eq "run2 based_on_uuid points at the Full" "$ifull_uuid" "$i1_based"
assert_eq "run3 is Incremental" "Incremental" "$i2_type"
assert_eq "run3 (second Incremental) bases on run2's Incremental, not the original Full -- true cumulative chaining, unlike Differential" "$i1_uuid" "$i2_based"

incr_cnf=$(sidecar_of "$i2_loc")
assert_contains "second Incremental sidecar: butype='Incremental'" "$incr_cnf" "butype='Incremental'"
assert_contains "second Incremental sidecar: incbase points at the FIRST Incremental's directory" "$incr_cnf" "incbase='$i1_loc'"

###############################################################################
echo "== diffupgradepct: auto-upgrade to Full when projected chain size exceeds threshold =="
cur_hour=$(date +%H)
write_base_cnf "$workdir/upg.cnf" /work/backups_upg upgseries yes
echo "bgbackup_hour=$cur_hour" >> "$workdir/upg.cnf"

tdc_run_bgbackup "$name" /work/upg.cnf >/dev/null   # Full
tdc_run_bgbackup "$name" /work/upg.cnf >/dev/null   # Differential

# Force the projection deterministically: previous Full recorded as 10M,
# previous Differential as 20M. With bgbackup_hour pinned to the single
# current hour and fullbackupday=Everyday, count_remaining_differentials
# always resolves to exactly 1 (see docker_common.sh / this file's header
# for why), so projected_size == prev_diff_size == 20M, and threshold ==
# 150% of 10M == 15M. 20M > 15M must upgrade.
tdc_sql "$name" "UPDATE mdbutil.backup_history SET backup_size='10M' WHERE butype='Full' AND hostname LIKE '%-upgseries'" >/dev/null
tdc_sql "$name" "UPDATE mdbutil.backup_history SET backup_size='20M' WHERE butype='Differential' AND hostname LIKE '%-upgseries'" >/dev/null

upgrade_log=$(tdc_run_bgbackup "$name" /work/upg.cnf -v 2>&1)
assert_contains "upgrade run: warns about the projected chain size" "$upgrade_log" "projected to grow too large"

mapfile -t upg_rows < <(tdc_sql "$name" "SELECT butype,based_on_uuid FROM mdbutil.backup_history WHERE hostname LIKE '%-upgseries' ORDER BY start_time")
IFS=$'\t' read -r u3_type u3_based <<< "${upg_rows[2]}"
assert_eq "20M/15M: third run upgraded to Full instead of Differential" "Full" "$u3_type"
assert_eq "upgraded run has no base (it's a fresh Full)" "NULL" "$u3_based"

###############################################################################
echo "== diffupgradepct: stays Differential when projection is under threshold =="
write_base_cnf "$workdir/noupg.cnf" /work/backups_noupg noupgseries yes
echo "bgbackup_hour=$cur_hour" >> "$workdir/noupg.cnf"

tdc_run_bgbackup "$name" /work/noupg.cnf >/dev/null   # Full
tdc_run_bgbackup "$name" /work/noupg.cnf >/dev/null   # Differential

# Same mechanics as above, but prev_diff_size (5M) stays under 150% of
# full_size (10M) == 15M threshold -- must NOT upgrade.
tdc_sql "$name" "UPDATE mdbutil.backup_history SET backup_size='10M' WHERE butype='Full' AND hostname LIKE '%-noupgseries'" >/dev/null
tdc_sql "$name" "UPDATE mdbutil.backup_history SET backup_size='5M' WHERE butype='Differential' AND hostname LIKE '%-noupgseries'" >/dev/null

noupgrade_log=$(tdc_run_bgbackup "$name" /work/noupg.cnf -v 2>&1)
assert_not_contains "under-threshold run: no upgrade warning" "$noupgrade_log" "projected to grow too large"

mapfile -t noupg_rows < <(tdc_sql "$name" "SELECT butype,based_on_uuid FROM mdbutil.backup_history WHERE hostname LIKE '%-noupgseries' ORDER BY start_time")
IFS=$'\t' read -r nu_full_uuid _ <<< "$(tdc_sql "$name" "SELECT uuid,butype FROM mdbutil.backup_history WHERE hostname LIKE '%-noupgseries' AND butype='Full'")"
IFS=$'\t' read -r n3_type n3_based <<< "${noupg_rows[2]}"
assert_eq "5M/15M: third run stayed Differential" "Differential" "$n3_type"
assert_eq "third run still bases on the original Full" "$nu_full_uuid" "$n3_based"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
