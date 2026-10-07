#!/bin/bash
#
# test_galera_checks_and_desync.sh
#
# Fixture-based coverage for bgbackup.sh's Galera-specific logic:
#
#   - backer_upper's wsrep_desync lifecycle: desync ON right before the
#     backup command, desync OFF only after the backup finishes AND the
#     wsrep_local_recv_queue poll loop reports 0.
#   - sigint()'s desync-OFF-on-Ctrl-C path.
#   - config_check's flow-control-disable gate: galera=yes downgrades to
#     galera="error" (logged, not fatal) when wsrep_provider_options
#     doesn't mention libgalera.
#   - galera_check()'s two preflight gates: an in-progress SST
#     (wsrep_sst process present) and too few cluster nodes.
#
# A real multi-node Galera cluster in Docker (real SST, cluster bootstrap)
# is a much heavier lift than the async MariaDB replication used
# elsewhere in this project. Per this task's own guidance, this file takes
# the lighter, explicitly-sanctioned substitute instead: a single node is
# never actually started here at all -- $mysqltargetcommand (and, for
# backer_upper, $innobackupex/the "ps" lookup galera_check shells out to)
# are stubbed bash functions, and backer_upper/innocreate/sigint/
# config_check/galera_check are extracted live out of bgbackup.sh (same
# technique as tests/test_expand_hour_spec.sh) and run against those
# stubs. This exercises the real shipped sequencing/branching logic
# exactly as written, including a real, severe bug it caught along the
# way (see the BUG note below) -- just not against a real wsrep provider.
#
# Run: ./tests/test_galera_checks_and_desync.sh

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

for fn in backer_upper innocreate log_info log_check sigint config_check galera_check log_error; do
    src=$(tdc_extract_function "$fn" "$bgbackup_sh")
    if [[ -z "$src" ]]; then
        echo "FAIL: could not extract $fn() out of $bgbackup_sh -- has it been renamed?"
        exit 1
    fi
    eval "$src"
done

###############################################################################
echo "== backer_upper: desync ON before the backup, OFF only after backup+queue-drain =="

# $mysqltargetcommand's value MUST end in a trailing space, matching the
# real mysqltargetcreate()'s "...-Bse " -- backer_upper's queue-poll line
# glues $mysqltargetcommand directly against a quoted literal with no
# separating space in the source (see the BUG note at that line in
# bgbackup.sh), and whether that glue lands as one argument or splits
# into two depends on whether $mysqltargetcommand's OWN expansion already
# ends in whitespace. Matching that trailing space here reproduces the
# exact same argument shape the real code produces, rather than
# incidentally avoiding the bug.
# A FILE, not a bash array: the queue-poll line invokes this stub inside
# `$(...)` command substitution, which forks a subshell -- any array/
# counter variable this function modified would be silently discarded
# the moment that subshell exits. A real file's writes survive that.
seqfile=$(mktemp)
stub_mysqltarget() {
    if [[ "$1" == *wsrep_desync=ON* ]]; then
        echo "DESYNC_ON" >> "$seqfile"
    elif [[ "$1" == *wsrep_desync=OFF* ]]; then
        echo "DESYNC_OFF" >> "$seqfile"
    elif [[ "$1" == *wsrep_local_recv_queue* ]]; then
        # Substring match, not positional parsing -- BUG note above
        # explains why the real argument isn't a clean single SQL string.
        local n=$(($(grep -c QUEUE_POLL "$seqfile") + 1))
        echo "QUEUE_POLL_$n" >> "$seqfile"
        if [ "$n" -ge 2 ]; then
            echo -e "Variable_name\t0"
        else
            echo -e "Variable_name\t5"
        fi
    else
        echo "OTHER_SQL:$1" >> "$seqfile"
    fi
}
mysqltargetcommand="stub_mysqltarget "

stub_mysqlhist() { echo 0; }   # alreadyfulltoday/alreadyfullthisweek COUNT(*) stubs
mysqlhistcommand="stub_mysqlhist"

echo_backup_stub() {
    echo "BACKUP_RAN" >> "$seqfile"
    # backer_upper redirects $innocommand's stderr (only) into $logfile;
    # log_check greps THAT file for this exact string.
    echo "completed OK!" >&2
}
innobackupex="echo_backup_stub"
has_innobackupex=0

# Globals innocreate/backer_upper read. fullbackupday=Always unconditionally
# takes innocreate's Full branch, so differential_upgrade_needed/
# differential_version_mismatch (Differential-branch-only) are never
# reached and don't need to be extracted.
backuptool=1
backupdir=/tmp
force=0
fullbackupday=Always
differential=no
backupuser=testuser
backuppass=testpass
socket=
host=
hostport=
defaults_file=
defaults_extra_file=
this_hostname_where="hostname='faketest'"
galera=yes
slave=no
parallel=no
threads=2
compress=no
encrypt=no
cryptkey=
nolock=no
rocksdb=no
monyog=no
openfilelimit=0
stop_slave_sql_thread=no
backuphistschema=mdbutil
logfile=$(mktemp)
verbose=no
syslog=no

backer_upper

mapfile -t seq_lines < "$seqfile"
assert_eq "sequencing: ON, BACKUP, poll, poll, OFF (in that exact order)" \
    "DESYNC_ON BACKUP_RAN QUEUE_POLL_1 QUEUE_POLL_2 DESYNC_OFF" "${seq_lines[*]}"
assert_eq "backup itself reports SUCCEEDED" "SUCCEEDED" "$log_status"
rm -f "$logfile" "$seqfile"

###############################################################################
echo "== sigint: disables WSREP desync on Ctrl-C, only when galera=yes =="

stub_mysqltarget_sigint() { echo "$1" >> "$sigint_seqfile"; }

# sigint calls `exit 130` directly, so this runs it in a subshell to
# capture that exit code without ending the test script -- which means
# anything the stub records during the call must go to a FILE, not a
# bash array/variable: nothing a subshell modifies survives past `)`.
run_sigint() {
    local g="$1"
    sigint_seqfile=$(mktemp)
    (
        galera="$g"
        mysqltargetcommand="stub_mysqltarget_sigint"
        logfile=$(mktemp)
        verbose=no
        syslog=no
        sigint
    )
    last_sigint_exit=$?
    mapfile -t last_sigint_calls < "$sigint_seqfile"
    rm -f "$sigint_seqfile"
}

run_sigint yes
assert_eq "galera=yes: sigint exits 130 (standard SIGINT code)" "130" "$last_sigint_exit"
assert_eq "galera=yes: sigint issues wsrep_desync=OFF" "SET GLOBAL wsrep_desync=OFF" "${last_sigint_calls[0]:-}"

run_sigint no
assert_eq "galera=no: sigint still exits 130" "130" "$last_sigint_exit"
assert_eq "galera=no: sigint does NOT touch wsrep_desync at all" "0" "${#last_sigint_calls[@]}"

###############################################################################
echo "== config_check: galera=yes downgrades to 'error' when libgalera isn't loaded =="

run_config_check() {
    local provider_output="$1" stop_slave="$2" slave_status_output="$3"
    stub_mysqltarget_cc() {
        if [[ "$1" == *wsrep_provider_options* ]]; then
            echo "$cc_provider_output"
        elif [[ "$1" == *"SHOW SLAVE STATUS"* ]]; then
            # Real "returned nothing" is zero bytes of output, not one
            # blank line -- `echo ""` would still print a newline and
            # make `wc -l` see 1 line, not 0.
            [ -n "$cc_slave_status_output" ] && echo "$cc_slave_status_output"
        fi
    }
    cc_provider_output="$provider_output"
    cc_slave_status_output="$slave_status_output"
    galera=yes
    mysqltargetcommand="stub_mysqltarget_cc"
    stop_slave_sql_thread="$stop_slave"
    fullbackupday=Everyday
    logfile=$(mktemp)
    verbose=no
    syslog=no
    mailon=none
    config_check
    rm -f "$logfile"
}

run_config_check "wsrep_provider_options	/usr/lib/galera/libgalera_smm.so" no ""
assert_eq "libgalera IS mentioned: galera stays 'yes'" "yes" "$galera"

run_config_check "wsrep_provider_options	" no ""
assert_eq "libgalera NOT mentioned: galera downgrades to 'error' (not fatal)" "error" "$galera"

run_config_check "wsrep_provider_options	/usr/lib/galera/libgalera_smm.so" yes ""
assert_eq "stop_slave_sql_thread=yes but SHOW SLAVE STATUS empty: downgraded to 'no'" "no" "$stop_slave_sql_thread"

run_config_check "wsrep_provider_options	/usr/lib/galera/libgalera_smm.so" yes "some_slave_status_row_data"
assert_eq "stop_slave_sql_thread=yes AND this host IS a replica: stays 'yes'" "yes" "$stop_slave_sql_thread"

###############################################################################
echo "== galera_check: SST-in-progress and minimum-node gates =="

run_galera_check() {
    local ps_output="$1" cluster_size="$2" min_nodes="$3"
    stub_mysqltarget_gc() {
        if [[ "$1" == *wsrep_cluster_size* ]]; then
            echo "wsrep_cluster_size	$gc_cluster_size"
        fi
    }
    ps() { echo "$gc_ps_output"; }
    gc_ps_output="$ps_output"
    gc_cluster_size="$cluster_size"
    galera=yes
    galera_minimum_nodes="$min_nodes"
    mysqltargetcommand="stub_mysqltarget_gc"
    logfile=$(mktemp)
    verbose=no
    syslog=no
    mailon=none
    ( galera_check )
    local rc=$?
    unset -f ps
    rm -f "$logfile"
    echo "$rc"
}

rc=$(run_galera_check "root 1234 0.0 0.0 wsrep_sst_mariabackup" 3 3)
assert_eq "SST in progress: galera_check exits 1 (log_error)" "1" "$rc"

rc=$(run_galera_check "" 3 3)
assert_eq "no SST, enough nodes (3 >= 3): galera_check exits 0" "0" "$rc"

rc=$(run_galera_check "" 2 3)
assert_eq "too few nodes (2 < 3): galera_check exits 1 (log_error)" "1" "$rc"

rc=$(run_galera_check "" 1 0)
assert_eq "galera_minimum_nodes=0: node-count gate skipped regardless of actual count" "0" "$rc"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
