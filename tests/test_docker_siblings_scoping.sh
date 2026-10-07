#!/bin/bash
#
# test_docker_siblings_scoping.sh
#
# Live-Docker coverage for bgbackup_siblings: when possibly creating
# backups from multiple instances (e.g. an asynchronous replication pair
# where backups are sometimes taken on the other host), `siblings=` lets
# retention/history queries span the whole group sharing one
# backup_history table, while backup CREATION (picking a base for a
# Differential/Incremental) stays strictly scoped to the local host --
# "Incrementals/differentials can only be created from this node's
# backups" per bgbackup.cnf.dist.
#
# Two "hosts" (sibA, sibB) are simulated with two instance_names sharing
# one MariaDB container/backup_history table -- the real per-pair
# mechanism (this_hostname_where vs. siblings_hostname_where, see
# generate_hostname_where) doesn't care whether "siblings" are really
# separate machines or, as here, the same machine under a different
# instance_name; both produce distinct `hostname` column values the exact
# same way.
#
# Run: ./tests/test_docker_siblings_scoping.sh

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

command -v docker >/dev/null || { echo "SKIP: docker not available"; exit 0; }
bash -n "$bgbackup_sh" || { echo "FAIL: $bgbackup_sh has a syntax error"; exit 1; }

name="bgt_siblings_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs" "$workdir/backups_a" "$workdir/backups_b"

container_hostname=$(docker exec "$name" hostname)

write_cnf() {
    local path="$1" backupdir="$2" instance="$3" siblings="$4"
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
siblings=$siblings
EOF
}

# Same extraction technique as test_docker_retention_cleanup.sh: run the
# real backup_cleanup (plus generate_hostname_where/
# backup_has_live_dependent) directly against the real database/
# filesystem, with keepdaily/siblings passed as arguments instead of read
# from any .cnf.
run_backup_cleanup() {
    local cname="$1" kd="$2" instance="$3" siblings="$4"
    local inner

    inner="set -u"$'\n'
    inner+="$(tdc_extract_function generate_hostname_where "$bgbackup_sh")"$'\n'
    inner+="$(tdc_extract_function backup_has_live_dependent "$bgbackup_sh")"$'\n'
    inner+="$(tdc_extract_function log_info "$bgbackup_sh")"$'\n'
    inner+="$(tdc_extract_function backup_cleanup "$bgbackup_sh")"$'\n'
    inner+="mysqlhistcommand=\"mysql -uroot -p${TDC_ROOT_PW} -Bse \""$'\n'
    inner+="backuphistschema=mdbutil"$'\n'
    inner+="keepdaily=$kd"$'\n'
    inner+="keepweekly=0"$'\n'
    inner+="keepmonthly=0"$'\n'
    inner+="keepyearly=0"$'\n'
    inner+="instance_name='$instance'"$'\n'
    inner+="siblings='$siblings'"$'\n'
    inner+="log_status=SUCCEEDED"$'\n'
    inner+="butype=Full"$'\n'
    inner+="verbose=no"$'\n'
    inner+="syslog=no"$'\n'
    inner+='logfile=$(mktemp)'$'\n'
    inner+="generate_hostname_where"$'\n'
    inner+="backup_cleanup"$'\n'
    inner+='cat "$logfile"; rm -f "$logfile"'$'\n'

    docker exec -i -u root "$cname" bash -s <<< "$inner"
}

dir_exists() {
    docker exec -u root "$name" bash -c "[ -d '$1' ] && echo yes || echo no"
}

###############################################################################
echo "== creation-time isolation: a sibling's Full is never used as this host's base =="
write_cnf "$workdir/a.cnf" /work/backups_a sibA "${container_hostname}-sibB"
write_cnf "$workdir/b.cnf" /work/backups_b sibB "${container_hostname}-sibA"

tdc_run_bgbackup "$name" /work/a.cnf >/dev/null   # F_A
tdc_run_bgbackup "$name" /work/b.cnf >/dev/null   # F_B
tdc_run_bgbackup "$name" /work/a.cnf >/dev/null   # I_A -- 2nd run for sibA

mapfile -t a_rows < <(tdc_sql "$name" "SELECT uuid,butype,based_on_uuid,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-sibA' ORDER BY start_time")
IFS=$'\t' read -r fa_uuid fa_type fa_based fa_loc <<< "${a_rows[0]}"
IFS=$'\t' read -r ia_uuid ia_type ia_based ia_loc <<< "${a_rows[1]}"
fb_uuid=$(tdc_sql "$name" "SELECT uuid FROM mdbutil.backup_history WHERE hostname LIKE '%-sibB'")
fb_loc=$(tdc_sql "$name" "SELECT bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-sibB'")

assert_eq "sibA run1 is a Full" "Full" "$fa_type"
assert_eq "sibB has its own, separate Full" "1" "$(tdc_sql "$name" "SELECT COUNT(*) FROM mdbutil.backup_history WHERE hostname LIKE '%-sibB'")"
assert_eq "sibA run2 is an Incremental" "Incremental" "$ia_type"
assert_eq "sibA's Incremental bases on sibA's OWN Full, despite sibB's Full existing and siblings being configured" "$fa_uuid" "$ia_based"

###############################################################################
echo "== retention scoping: siblings= pulls the sibling's old backups into the SAME cleanup pass =="
# Backdate both chains past keepdaily -- distinct offsets, newest-first,
# same reasoning as test_docker_retention_cleanup.sh's scenario A (a tied
# end_time would leave MySQL's ORDER BY tie-break unspecified).
tdc_sql "$name" "UPDATE mdbutil.backup_history SET end_time = DATE_SUB(NOW(), INTERVAL 10 DAY) WHERE uuid='$fa_uuid'" >/dev/null
tdc_sql "$name" "UPDATE mdbutil.backup_history SET end_time = DATE_SUB(NOW(), INTERVAL 9 DAY) WHERE uuid='$ia_uuid'" >/dev/null
tdc_sql "$name" "UPDATE mdbutil.backup_history SET end_time = DATE_SUB(NOW(), INTERVAL 10 DAY) WHERE uuid='$fb_uuid'" >/dev/null

# Run cleanup "as sibA", with siblings pointing at sibB -- a single pass
# scoped to {sibA, sibB} together.
run_backup_cleanup "$name" 7 sibA "${container_hostname}-sibB" >/dev/null

assert_eq "sibA's Incremental deleted" "DELETED" "$(tdc_sql "$name" "SELECT IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$ia_uuid'")"
assert_eq "sibA's Full deleted (its only dependent, the Incremental, is gone too)" "DELETED" "$(tdc_sql "$name" "SELECT IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$fa_uuid'")"
assert_eq "sibB's Full ALSO deleted -- cleanup run as sibA reached into its sibling's backups" "DELETED" "$(tdc_sql "$name" "SELECT IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$fb_uuid'")"
assert_eq "sibA Full directory removed" "no" "$(dir_exists "$fa_loc")"
assert_eq "sibA Incremental directory removed" "no" "$(dir_exists "$ia_loc")"
assert_eq "sibB Full directory removed too" "no" "$(dir_exists "$fb_loc")"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
