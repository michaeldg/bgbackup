#!/bin/bash
#
# test_docker_safe_slave_backup_flag.sh
#
# Live-Docker regression guard for innocreate's --safe-slave-backup flag
# (bgbackup.sh line ~335):
#
#   if [ "$nolock" = yes ] && [ "$slave" = yes ] ; then
#       innocommand=$innocommand" --safe-slave-backup"
#   fi
#
# --safe-slave-backup is only ever added when BOTH nolock=yes AND
# slave=yes -- easy to get wrong (e.g. accidentally gating on either flag
# alone). This is a genuinely separate mechanism from
# stop_slave_sql_thread=yes (a manual STOP/START SLAVE SQL_THREAD wrapped
# around the whole backup command, see
# test_docker_replica_sql_thread_safety_net.sh) and doesn't need a real
# replica at all: the flag is passed to the backup tool unconditionally
# based on config, with no live SHOW SLAVE STATUS check (unlike
# stop_slave_sql_thread, which config_check downgrades to "no" when the
# host doesn't look like a replica). All four combinations of nolock x
# slave are run against a single, perfectly ordinary standalone server.
#
# The actual command line is read back out of the backup's own logfile
# (backer_upper logs "Executing ... command: ..." via log_info, which
# store_log_with_backup=no still writes to logpath on the host-visible
# bind mount) rather than re-run with -v, matching the simplest read-back
# approach already used by the sidecar/encryption tests in this suite.
#
# Run: ./tests/test_docker_safe_slave_backup_flag.sh

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bgbackup_sh="$script_dir/../bgbackup.sh"
# shellcheck source=lib/docker_common.sh
source "$script_dir/lib/docker_common.sh"

pass=0
fail=0

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

name="bgt_safeslave_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs"

write_cnf() {
    local path="$1" backupdir="$2" instance="$3" nolock="$4" slave="$5"
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
fullbackupday=Always
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
nolock=$nolock
rocksdb=no
galera=no
galera_minimum_nodes=0
preflight_script="echo 'OK' || echo"
slave=$slave
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

# The exact "Executing ... command: ..." log_info line from the most
# recent run's logfile.
latest_command_line() {
    docker exec -u root "$name" bash -c "grep -h 'Executing' \$(ls -t /work/logs/bgbackup_*.log | head -1)"
}

run_case() {
    local label="$1" nolock="$2" slave="$3"
    mkdir -p "$workdir/backups_$label"
    write_cnf "$workdir/$label.cnf" "/work/backups_$label" "$label" "$nolock" "$slave"
    tdc_run_bgbackup "$name" "/work/$label.cnf" >/dev/null
    latest_command_line
}

###############################################################################
echo "== --safe-slave-backup requires BOTH nolock=yes AND slave=yes =="

cmd=$(run_case ss_both yes yes)
assert_contains "nolock=yes, slave=yes: --safe-slave-backup IS present" "$cmd" "--safe-slave-backup"
assert_contains "nolock=yes, slave=yes: --no-lock is also present" "$cmd" "--no-lock"
assert_contains "nolock=yes, slave=yes: --slave-info is also present" "$cmd" "--slave-info"

cmd=$(run_case ss_nolock_only yes no)
assert_not_contains "nolock=yes, slave=no: --safe-slave-backup is ABSENT" "$cmd" "--safe-slave-backup"
assert_contains "nolock=yes, slave=no: --no-lock is still present on its own" "$cmd" "--no-lock"

cmd=$(run_case ss_slave_only no yes)
assert_not_contains "nolock=no, slave=yes: --safe-slave-backup is ABSENT" "$cmd" "--safe-slave-backup"
assert_contains "nolock=no, slave=yes: --slave-info is still present on its own" "$cmd" "--slave-info"

cmd=$(run_case ss_neither no no)
assert_not_contains "nolock=no, slave=no: --safe-slave-backup is ABSENT" "$cmd" "--safe-slave-backup"
assert_not_contains "nolock=no, slave=no: --no-lock is ABSENT" "$cmd" "--no-lock"
assert_not_contains "nolock=no, slave=no: --slave-info is ABSENT" "$cmd" "--slave-info"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
