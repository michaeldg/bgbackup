#!/bin/bash
#
# test_docker_multi_instance.sh
#
# Live-Docker coverage for multi-instance support: $instance_name threads
# through the lockfile path (/tmp/bgbackup[-$instance_name].lock) and the
# backup_history hostname column. Confirms two concurrent "instances" on
# the same host don't collide on the lockfile, while two runs of the SAME
# instance_name at the same time still correctly block each other (the
# lock is instance-scoped, not simply absent).
#
# "Concurrently running" is made real, not simulated, by using
# preflight_script (ordinary eval'd shell) as a controllable delay: one
# run's preflight_script is `sleep 15 && echo OK`, which holds that run's
# lockfile for the whole 15s window (the lockfile is touched before
# preflight_check runs) while this test launches the other runs against
# it in the background.
#
# Run: ./tests/test_docker_multi_instance.sh

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

name="bgt_instance_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs" "$workdir/backups_a" "$workdir/backups_b"

write_cnf() {
    local path="$1" backupdir="$2" instance="$3" preflight="$4"
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
differential=no
keepdaily=0
keepweekly=0
keepmonthly=0
keepyearly=0
keepbkuptblnum=1
keeplognum=1000
keepfaileddays=365
diffupgradepct=150
backupdir=$backupdir
logpath=/work/logs
store_log_with_backup=no
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
preflight_script="$preflight"
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

###############################################################################
echo "== different instance_name is NOT blocked by another instance's lock =="
write_cnf "$workdir/lockA_slow.cnf" /work/backups_a lockA "sleep 15 && echo 'OK'"
write_cnf "$workdir/lockB.cnf" /work/backups_b lockB "echo 'OK' || echo"
write_cnf "$workdir/lockA_fast.cnf" /work/backups_a lockA "echo 'OK' || echo"

tdc_run_bgbackup "$name" /work/lockA_slow.cnf > "$workdir/lockA_slow.out" 2>&1 &
slow_pid=$!
sleep 4   # let it get past `touch $lockfile` and into its 15s preflight sleep

tdc_run_bgbackup "$name" /work/lockB.cnf > "$workdir/lockB.out" 2>&1
lockB_exit=$?
assert_eq "different instance_name (lockB) proceeds while lockA is still running" "0" "$lockB_exit"

###############################################################################
echo "== same instance_name IS blocked while an earlier run of it is still in progress =="
tdc_run_bgbackup "$name" /work/lockA_fast.cnf > "$workdir/lockA_fast.out" 2>&1
lockA_fast_exit=$?
assert_eq "same instance_name (lockA) while already running exits 1" "1" "$lockA_fast_exit"
assert_contains "blocked run logs the 'already running' message" "$(cat "$workdir/lockA_fast.out")" "already running"
assert_contains "the message names the instance-scoped lockfile path" "$(cat "$workdir/lockA_fast.out")" "/tmp/bgbackup-lockA.lock"

wait "$slow_pid"
slow_exit=$?
assert_eq "the slow lockA run itself completes normally once its sleep ends" "0" "$slow_exit"

###############################################################################
echo "== distinct instance_names land under distinct hostname values in backup_history =="
mapfile -t hostnames < <(tdc_sql "$name" "SELECT DISTINCT hostname FROM mdbutil.backup_history WHERE hostname LIKE '%-lockA' OR hostname LIKE '%-lockB' ORDER BY hostname")
assert_eq "two distinct hostname values recorded (lockA vs lockB)" "2" "${#hostnames[@]}"

lockA_count=$(tdc_sql "$name" "SELECT COUNT(*) FROM mdbutil.backup_history WHERE hostname LIKE '%-lockA'")
lockB_count=$(tdc_sql "$name" "SELECT COUNT(*) FROM mdbutil.backup_history WHERE hostname LIKE '%-lockB'")
assert_eq "exactly one SUCCEEDED row for lockA (the slow run; the blocked one never got far enough to insert a row)" "1" "$lockA_count"
assert_eq "exactly one row for lockB" "1" "$lockB_count"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
