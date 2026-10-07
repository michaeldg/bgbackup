#!/bin/bash
#
# test_docker_retention_cleanup.sh
#
# Live-Docker coverage for bgbackup.sh's retention/rotation logic against a
# real backup_history table (MariaDB + mariadb-backup):
#
#   A. backup_has_live_dependent + the newest-first deletion loop: a fully
#      expired Full<-Incremental<-Incremental<-Incremental chain collapses
#      in ONE backup_cleanup run, not one level per run.
#   B. The same dependency check actually protecting a backup: a Full and
#      its first Incremental stay past their own keepdaily cutoff because a
#      still-live, more recent Incremental is based_on_uuid them.
#   C. The keepweekly/keepmonthly/keepyearly flag lifecycle (1 = protected,
#      2 = expired-and-now-deletable) and the fact that the deletion
#      candidate filter ANDs all three (weekly<>1 AND monthly<>1 AND
#      yearly<>1) -- a backup stays protected as long as ANY one of the
#      three flags is still active, even after another has already expired.
#   D. backup_failed_cleanup: a real FAILED_ directory, aged past
#      keepfaileddays via its mtime, gets removed on the next Full run. Also
#      documents a real bug found while building this: the deleted_at
#      UPDATE that's supposed to accompany that deletion never matches any
#      row (see the KNOWN BUG assertion below).
#
# backup_cleanup itself is invoked directly (extracted out of bgbackup.sh,
# same technique as tests/test_expand_hour_spec.sh, but run for real inside
# the container against the real backup_history table and real backup
# directories -- not a stubbed fixture) so that "time passing" between
# cleanup passes can be simulated by backdating end_time in the database
# instead of actually waiting weeks/months/years for a real run of
# bgbackup.sh to age that far on its own. generate_hostname_where and
# backup_has_live_dependent are extracted alongside it since backup_cleanup
# calls both. The chains themselves (scenarios A/B/C) and the failed-backup
# lifecycle (scenario D) are still produced by real bgbackup.sh runs via
# tdc_run_bgbackup, so the backup_history rows and FAILED_ directories this
# file manipulates are the real shipped product of innocreate/
# backup_history_and_mark_failed, not hand-inserted fixtures.
#
# Note: backup_cleanup's own `if/elif/else` on log_status/butype has a dead
# elif branch (the elif's condition requires log_status=SUCCEEDED, which the
# preceding `if` already caught) -- in practice backup_cleanup runs its full
# retention pass after EVERY successful run regardless of butype, not just
# Full runs. Scenarios A-C below rely on that actual behavior rather than
# on the "Full-only" framing the dead branch's text suggests.
#
# Run: ./tests/test_docker_retention_cleanup.sh

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

name="bgt_retention_$$"
workdir=""
cleanup() { tdc_cleanup "$name" "$workdir"; }
trap cleanup EXIT

workdir=$(tdc_start mariadb "$name")
tdc_wait_ready "$name" 90 || { echo "FAIL: server never became ready"; exit 1; }
tdc_sql "$name" "CREATE DATABASE mdbutil;" >/dev/null
mkdir -p "$workdir/logs"

# Base config shared by every scenario in this file; only backupdir,
# instance_name and the keep* values vary.
write_base_cnf() {
    local path="$1" backupdir="$2" instance="$3"
    local keepdaily="$4" keepweekly="$5" keepmonthly="$6" keepyearly="$7"
    local keepfaileddays="${8:-365}" socket_override="${9:-$(tdc_socket_for mariadb)}"
    cat > "$path" <<EOF
backuptool=1
openfilelimit=0
backupuser=root
backuppass=$TDC_ROOT_PW
socket=$socket_override
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
keepdaily=$keepdaily
keepweekly=$keepweekly
keepmonthly=$keepmonthly
keepyearly=$keepyearly
keepbkuptblnum=1
keeplognum=1000
keepfaileddays=$keepfaileddays
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
EOF
}

# Invokes the REAL backup_cleanup (plus generate_hostname_where and
# backup_has_live_dependent, which it calls) extracted out of bgbackup.sh,
# against the real backup_history table and real files inside container
# $1. $2-$5 are keepdaily/keepweekly/keepmonthly/keepyearly -- passed
# directly as arguments rather than read from any .cnf, which is what lets
# this simulate "time passing" between cleanup passes purely by backdating
# end_time in the database between calls, without re-running the whole
# bgbackup.sh startup sequence (including its own keepdaily/keepweekly
# auto-bump logic, which this deliberately bypasses) each time. $6 is the
# instance_name whose backups to clean up. Prints the cleanup pass's own
# log_info output on stdout for assertions that need it.
run_backup_cleanup() {
    local cname="$1" kd="$2" kw="$3" km="$4" ky="$5" instance="$6"
    local inner

    inner="set -u"$'\n'
    inner+="$(tdc_extract_function generate_hostname_where "$bgbackup_sh")"$'\n'
    inner+="$(tdc_extract_function backup_has_live_dependent "$bgbackup_sh")"$'\n'
    inner+="$(tdc_extract_function log_info "$bgbackup_sh")"$'\n'
    inner+="$(tdc_extract_function backup_cleanup "$bgbackup_sh")"$'\n'
    inner+="mysqlhistcommand=\"mysql -uroot -p${TDC_ROOT_PW} -Bse \""$'\n'
    inner+="backuphistschema=mdbutil"$'\n'
    inner+="keepdaily=$kd"$'\n'
    inner+="keepweekly=$kw"$'\n'
    inner+="keepmonthly=$km"$'\n'
    inner+="keepyearly=$ky"$'\n'
    inner+="instance_name='$instance'"$'\n'
    inner+="siblings=''"$'\n'
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

# live/deleted_at rows for one instance, newest-first, as "butype based_on_uuid deleted_at"
history_rows() {
    tdc_sql "$name" "SELECT butype,based_on_uuid,IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE hostname LIKE '%-$1' ORDER BY start_time DESC"
}

dir_exists() {
    docker exec -u root "$name" bash -c "[ -d '$1' ] && echo yes || echo no"
}

backdate_end_time() {
    # $1=instance, $2=days ago
    tdc_sql "$name" "UPDATE mdbutil.backup_history SET end_time = DATE_SUB(NOW(), INTERVAL $2 DAY) WHERE hostname LIKE '%-$1'" >/dev/null
}

###############################################################################
echo "== A: fully expired Full<-Inc<-Inc<-Inc chain collapses in one cleanup pass =="
mkdir -p "$workdir/backups_chain"
write_base_cnf "$workdir/chain.cnf" /work/backups_chain retchain 0 0 0 0
tdc_run_bgbackup "$name" /work/chain.cnf >/dev/null   # Full
tdc_run_bgbackup "$name" /work/chain.cnf >/dev/null   # Incremental 1
tdc_run_bgbackup "$name" /work/chain.cnf >/dev/null   # Incremental 2
tdc_run_bgbackup "$name" /work/chain.cnf >/dev/null   # Incremental 3

mapfile -t chain_rows < <(tdc_sql "$name" "SELECT uuid,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-retchain' ORDER BY start_time")
assert_eq "four backups recorded before cleanup" "4" "${#chain_rows[@]}"

# All four are well past a keepdaily=7 cutoff -- with keepweekly/monthly/
# yearly all 0 (never flagged 1 at creation, see write_base_cnf args above)
# -- so only the dependency chain can protect any of them. Backdated with
# DISTINCT, creation-order-preserving offsets (not one UPDATE giving all
# four the exact same end_time): backup_cleanup's deletion query has no
# secondary ORDER BY key, so identical timestamps would leave MySQL's tie-
# break order unspecified and could silently invert the newest-first
# processing this scenario exists to prove.
chain_locs=()
offset=13
for row in "${chain_rows[@]}"; do
    IFS=$'\t' read -r uuid loc <<< "$row"
    chain_locs+=("$loc")
    tdc_sql "$name" "UPDATE mdbutil.backup_history SET end_time = DATE_SUB(NOW(), INTERVAL $offset DAY) WHERE uuid='$uuid'" >/dev/null
    offset=$((offset - 1))
done
run_backup_cleanup "$name" 7 0 0 0 retchain >/dev/null

mapfile -t chain_after < <(history_rows retchain)
assert_eq "all four rows now marked DELETED" "4" "$(printf '%s\n' "${chain_after[@]}" | grep -c DELETED)"
for loc in "${chain_locs[@]}"; do
    assert_eq "directory actually removed: $(basename "$loc")" "no" "$(dir_exists "$loc")"
done

###############################################################################
echo "== B: a live dependent protects its base past the base's own retention window =="
mkdir -p "$workdir/backups_protect"
write_base_cnf "$workdir/protect.cnf" /work/backups_protect retprotect 0 0 0 0
tdc_run_bgbackup "$name" /work/protect.cnf >/dev/null   # Full
tdc_run_bgbackup "$name" /work/protect.cnf >/dev/null   # Incremental 1 (based on Full)
tdc_run_bgbackup "$name" /work/protect.cnf >/dev/null   # Incremental 2 (based on Incremental 1)

mapfile -t prot_rows < <(tdc_sql "$name" "SELECT uuid,bulocation FROM mdbutil.backup_history WHERE hostname LIKE '%-retprotect' ORDER BY start_time")
IFS=$'\t' read -r full_uuid full_loc <<< "${prot_rows[0]}"
IFS=$'\t' read -r inc1_uuid inc1_loc <<< "${prot_rows[1]}"
IFS=$'\t' read -r inc2_uuid inc2_loc <<< "${prot_rows[2]}"

# Full and Incremental 1 both age past keepdaily=7; Incremental 2 (the live
# dependent) is left alone at "now" -- still well within the window.
tdc_sql "$name" "UPDATE mdbutil.backup_history SET end_time = DATE_SUB(NOW(), INTERVAL 14 DAY) WHERE uuid IN ('$full_uuid','$inc1_uuid')" >/dev/null
run_backup_cleanup "$name" 7 0 0 0 retprotect >/dev/null

mapfile -t prot_after < <(history_rows retprotect)
assert_eq "all three rows still LIVE (nothing actually deleted)" "0" "$(printf '%s\n' "${prot_after[@]}" | grep -c DELETED)"
assert_eq "Full's directory still exists" "yes" "$(dir_exists "$full_loc")"
assert_eq "Incremental 1's directory still exists" "yes" "$(dir_exists "$inc1_loc")"

###############################################################################
echo "== C: keepweekly/monthly/yearly flag lifecycle (1=protected, 2=expired) is AND'd =="
mkdir -p "$workdir/backups_weekly"
write_base_cnf "$workdir/weekly.cnf" /work/backups_weekly retweekly 7 4 2 1
tdc_run_bgbackup "$name" /work/weekly.cnf >/dev/null   # Full: first of its week/month/year

mapfile -t wk_row < <(tdc_sql "$name" "SELECT uuid,bulocation,weekly,monthly,yearly FROM mdbutil.backup_history WHERE hostname LIKE '%-retweekly'")
IFS=$'\t' read -r wk_uuid wk_loc wk_weekly wk_monthly wk_yearly <<< "${wk_row[0]}"
assert_eq "first Full of the host: weekly=1 (keepweekly=4 > 0)" "1" "$wk_weekly"
assert_eq "first Full of the host: monthly=1 (keepmonthly=2 > 0)" "1" "$wk_monthly"
assert_eq "first Full of the host: yearly=1 (keepyearly=1 > 0)" "1" "$wk_yearly"

# 40 days: past keepweekly's (4+1)*7=35-day expiry, but under keepmonthly's
# (2+1)*31=93 and keepyearly's (1+1)*366=732 -- weekly should flip to 2, but
# monthly=1 alone is enough to keep the candidate filter (which requires
# weekly<>1 AND monthly<>1 AND yearly<>1) from matching it.
backdate_end_time retweekly 40
run_backup_cleanup "$name" 7 4 2 1 retweekly >/dev/null
mapfile -t wk_row2 < <(tdc_sql "$name" "SELECT weekly,monthly,yearly,IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$wk_uuid'")
IFS=$'\t' read -r wk2_weekly wk2_monthly wk2_yearly wk2_status <<< "${wk_row2[0]}"
assert_eq "40 days: weekly expired (flipped to 2)" "2" "$wk2_weekly"
assert_eq "40 days: monthly still protected (1)" "1" "$wk2_monthly"
assert_eq "40 days: yearly still protected (1)" "1" "$wk2_yearly"
assert_eq "40 days: still LIVE -- monthly=1 alone blocks deletion despite weekly expiring" "LIVE" "$wk2_status"
assert_eq "40 days: directory still exists" "yes" "$(dir_exists "$wk_loc")"

# 100 days: past keepmonthly's 93-day expiry too, but still under
# keepyearly's 732 -- monthly flips to 2, yearly=1 alone still blocks it.
backdate_end_time retweekly 100
run_backup_cleanup "$name" 7 4 2 1 retweekly >/dev/null
mapfile -t wk_row3 < <(tdc_sql "$name" "SELECT weekly,monthly,yearly,IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$wk_uuid'")
IFS=$'\t' read -r wk3_weekly wk3_monthly wk3_yearly wk3_status <<< "${wk_row3[0]}"
assert_eq "100 days: monthly expired (flipped to 2)" "2" "$wk3_monthly"
assert_eq "100 days: yearly still protected (1)" "1" "$wk3_yearly"
assert_eq "100 days: still LIVE -- yearly=1 alone blocks deletion" "LIVE" "$wk3_status"

# 800 days: past keepyearly's 732-day expiry too -- all three flags are now
# <>1, so the backup finally becomes a real deletion candidate (and nothing
# depends on it, so it's actually deleted).
backdate_end_time retweekly 800
run_backup_cleanup "$name" 7 4 2 1 retweekly >/dev/null
mapfile -t wk_row4 < <(tdc_sql "$name" "SELECT yearly,IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$wk_uuid'")
IFS=$'\t' read -r wk4_yearly wk4_status <<< "${wk_row4[0]}"
assert_eq "800 days: yearly expired (flipped to 2)" "2" "$wk4_yearly"
assert_eq "800 days: all three flags expired -- now actually DELETED" "DELETED" "$wk4_status"
assert_eq "800 days: directory finally removed" "no" "$(dir_exists "$wk_loc")"

###############################################################################
echo "== D: backup_failed_cleanup removes a FAILED_ dir aged past keepfaileddays =="
mkdir -p "$workdir/backups_failed"
# First run: a nonexistent socket makes the backup tool itself fail to
# connect (backuphistsocket, used for history, is untouched and stays
# valid) -- a real FAILED backup produced the same way backup_history_and_
# mark_failed really renames one, not a hand-created fixture directory.
write_base_cnf "$workdir/failed_broken.cnf" /work/backups_failed retfailed 0 0 0 0 1 /nonexistent/mysql.sock
tdc_run_bgbackup "$name" /work/failed_broken.cnf >/dev/null

mapfile -t failed_row < <(tdc_sql "$name" "SELECT uuid,bulocation,status FROM mdbutil.backup_history WHERE hostname LIKE '%-retfailed'")
IFS=$'\t' read -r failed_uuid failed_loc failed_status <<< "${failed_row[0]}"
assert_eq "broken-socket run recorded as FAILED" "FAILED" "$failed_status"
assert_contains "failed backup's bulocation carries the FAILED_ rename" "$failed_loc" "FAILED_"
assert_eq "FAILED_ directory actually exists on disk" "yes" "$(dir_exists "$failed_loc")"

# Age the directory itself (backup_failed_cleanup's `find -mtime` looks at
# the directory's own mtime, not any database column) well past
# keepfaileddays=1.
docker exec -u root "$name" touch -d "10 days ago" "$failed_loc"

# Second run: a working socket, so this one succeeds. It's also this
# instance's first SUCCEEDED Full (the broken run never counted), so
# fullbackupday=Everyday resolves it to another Full -- which is what
# gates backup_failed_cleanup's scan (`if [ $butype = "Full" ]`).
write_base_cnf "$workdir/failed_ok.cnf" /work/backups_failed retfailed 0 0 0 0 1
tdc_run_bgbackup "$name" /work/failed_ok.cnf >/dev/null

assert_eq "aged FAILED_ directory removed by the next Full run" "no" "$(dir_exists "$failed_loc")"

# KNOWN BUG: backup_failed_cleanup's own deleted_at UPDATE uses
# `bulocation LIKE '%/$todelete'`, where $todelete comes from `find
# "$backupdir" ...` -- since backupdir is itself an absolute path, find
# returns the FULL path (e.g. "/work/backups_failed/FAILED_full-...", the
# exact same string already stored in bulocation), not a bare directory
# name. The pattern becomes '%//work/backups_failed/FAILED_full-...'
# (double slash), which a single-leading-slash bulocation value can never
# match, so the UPDATE silently matches zero rows every time in any
# deployment where backupdir is absolute (the documented default). The
# directory still gets deleted correctly; only the database bookkeeping is
# left stale (deleted_at stays NULL forever, pointing at a path that no
# longer exists).
mapfile -t failed_row2 < <(tdc_sql "$name" "SELECT IF(deleted_at IS NULL,'LIVE','DELETED') FROM mdbutil.backup_history WHERE uuid='$failed_uuid'")
assert_eq "KNOWN BUG: deleted_at is NOT set despite the directory being gone (LIKE pattern never matches an absolute bulocation)" "LIVE" "${failed_row2[0]}"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
