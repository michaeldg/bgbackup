#!/bin/bash
#
# test_docker_replica_sql_thread_safety_net.sh
#
# Live-Docker coverage for the stop_slave_sql_thread=yes safety net: if
# bgbackup.sh is killed (SIGTERM) while the replica's SQL thread is
# stopped for the backup, does the SQL thread actually come back?
#
# stop_slave_sql_thread wraps a manual STOP SLAVE SQL_THREAD / START SLAVE
# SQL_THREAD directly around the backup command in backer_upper, tracked
# via sql_thread_stop_pending and restored by
# restore_slave_sql_thread_if_needed() from the script's own exit trap
# (`trap '...; rm -f $lockfile' 0`) -- so it's supposed to run no matter
# how the script leaves that window: normal completion, SIGINT, an
# untrapped SIGTERM, or log_error's exit 1. This file proves the SIGTERM
# case for real: a genuine two-node MariaDB async replication pair (not
# Galera -- see this project's own convention of using real async
# replication rather than simulating it), a genuine SIGTERM delivered to
# the real bgbackup.sh process while it is genuinely inside the stopped-
# thread window, and a genuine check of the replica's own SHOW SLAVE
# STATUS before and after.
#
# Getting a real, honest window to signal into (rather than racing a
# fixed sleep against the backup tool) means making $innocommand itself
# take a few real seconds: ~600MB of dummy data is loaded on the primary
# and replicated across first. Detecting "the backup tool is running
# right now" and sending the signal are done inside ONE single docker
# exec session running a script file on the replica (detect_and_kill.sh,
# written to the bind-mounted /work dir, not inlined via `bash -c` with
# nested quoting) so there's no per-poll round-trip latency from the host
# and no shell-quoting fragility -- it polls locally, snapshots SHOW SLAVE
# STATUS the instant it sees the backup tool, and signals bgbackup.sh's
# real PID (found via pgrep -f) immediately after, all in-container. This
# machine is shared with other concurrent work, so the polling budget is
# deliberately generous (up to 180s) rather than tuned to an idle-machine
# timing -- load on this VM has been observed to make a ~2.5s backup take
# well over a minute.
#
# SIGTERM is sent to bgbackup.sh's PID *inside* the container rather than
# to the `docker exec` client process on the host, since `docker exec`
# does not reliably forward host signals into the container's PID
# namespace.
#
# Run: ./tests/test_docker_replica_sql_thread_safety_net.sh

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

net="bgt_replnet_$$"
primary="bgt_primary_$$"
replica="bgt_replica_$$"
primary_wd=""
replica_wd=""

cleanup() {
    docker rm -f "$primary" "$replica" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    [ -n "$primary_wd" ] && rm -rf "$primary_wd" 2>/dev/null
    [ -n "$replica_wd" ] && rm -rf "$replica_wd" 2>/dev/null
}
trap cleanup EXIT

docker network create "$net" >/dev/null
image=$(tdc_image_for mariadb)
primary_wd=$(mktemp -d /tmp/bgbackup_test.XXXXXX)
replica_wd=$(mktemp -d /tmp/bgbackup_test.XXXXXX)

docker run -d --name "$primary" --network "$net" --network-alias primary \
    -e MARIADB_ROOT_PASSWORD="$TDC_ROOT_PW" \
    -v "$primary_wd:/work" \
    "$image" --server-id=1 --log-bin=mysql-bin --log-slave-updates=1 >/dev/null

docker run -d --name "$replica" --network "$net" --network-alias replica \
    -e MARIADB_ROOT_PASSWORD="$TDC_ROOT_PW" \
    -v "$replica_wd:/work" \
    -v "$TDC_REPO_ROOT:/opt/bgbackup:ro" \
    "$image" --server-id=2 --log-bin=mysql-bin --log-slave-updates=1 >/dev/null

tdc_wait_ready "$primary" 90 || { echo "FAIL: primary never became ready"; exit 1; }
tdc_wait_ready "$replica" 90 || { echo "FAIL: replica never became ready"; exit 1; }

docker exec "$primary" mysql -uroot -p"$TDC_ROOT_PW" -e "
CREATE USER 'repl'@'%' IDENTIFIED BY 'replpass';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
" 2>/dev/null

docker exec "$replica" mysql -uroot -p"$TDC_ROOT_PW" -e "
CHANGE MASTER TO MASTER_HOST='primary', MASTER_USER='repl', MASTER_PASSWORD='replpass', MASTER_USE_GTID=slave_pos;
START SLAVE;
" 2>/dev/null

slave_status() {
    docker exec "$replica" mysql -uroot -p"$TDC_ROOT_PW" -Bse "SHOW SLAVE STATUS\G" 2>/dev/null \
        | grep -E "Slave_IO_Running:|Slave_SQL_Running:" | awk '{print $2}'
}
mapfile -t st < <(slave_status)
assert_eq "replica IO thread running before anything else happens" "Yes" "${st[0]:-}"
assert_eq "replica SQL thread running before anything else happens" "Yes" "${st[1]:-}"

###############################################################################
echo "== loading ~600MB on the primary so the replica's own backup takes real time =="
docker exec "$primary" mysql -uroot -p"$TDC_ROOT_PW" -e "
CREATE DATABASE bigdata;
CREATE TABLE bigdata.big (id INT PRIMARY KEY AUTO_INCREMENT, data LONGBLOB) ENGINE=InnoDB;
"
for i in $(seq 1 600); do
    docker exec "$primary" mysql -uroot -p"$TDC_ROOT_PW" -e "INSERT INTO bigdata.big (data) SELECT REPEAT('a', 1024*1024);" &
    if (( i % 25 == 0 )); then wait; fi
done
wait

# Wait for the replica to actually catch up (row count match) rather than
# a fixed sleep.
cnt=0
for i in $(seq 1 180); do
    cnt=$(docker exec "$replica" mysql -uroot -p"$TDC_ROOT_PW" -Bse "SELECT COUNT(*) FROM bigdata.big" 2>/dev/null || echo 0)
    [ "$cnt" = "600" ] && break
    sleep 1
done
assert_eq "replica caught up on the ~600MB table" "600" "$cnt"

###############################################################################
echo "== SIGTERM mid-backup: the replica's SQL thread must come back =="

docker exec "$replica" mysql -uroot -p"$TDC_ROOT_PW" -e "CREATE DATABASE mdbutil;" 2>/dev/null
mkdir -p "$replica_wd/backups" "$replica_wd/logs"
cat > "$replica_wd/sigterm.cnf" <<EOF
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
backupdir=/work/backups
logpath=/work/logs
store_log_with_backup=no
syslog=no
threads=2
parallel=no
encrypt=no
cryptkey=
compress=no
nolock=no
rocksdb=no
galera=no
galera_minimum_nodes=0
preflight_script="echo 'OK' || echo"
slave=yes
stop_slave_sql_thread=yes
maillist=admin@example.com
mailsubpre="[BGBackup]"
mailon=none
run_after_success=
run_after_fail=
debug=no
verbose=no
instance_name=sigtermtest
EOF

# Written as a real file and run with plain argv (no nested quoting) --
# polls locally inside the container (no per-iteration host round trip),
# snapshots SHOW SLAVE STATUS the instant it sees the backup tool, then
# immediately signals bgbackup.sh's real PID. 1800 x 0.1s = up to 180s,
# generous for a loaded shared machine.
#
# Matches "mariabackup", not "mariadb-backup": /usr/bin/mariabackup is a
# symlink to mariadb-backup, but bgbackup.sh resolves $innobackupex via
# `command -v mariabackup` (backuptool=1's detection, see bgbackup.sh)
# and execs THAT path, so the running process's own cmdline contains the
# symlink's name ("mariabackup"), not the real file's name -- the two
# strings don't even overlap as substrings of each other.
cat > "$replica_wd/detect_and_kill.sh" <<'SCRIPT'
#!/bin/bash
rootpw="$1"
cnf_path="$2"
for ((i = 1; i <= 1800; i++)); do
    if pgrep -f mariabackup >/dev/null 2>&1; then
        mysql -uroot -p"$rootpw" -Bse "SHOW SLAVE STATUS\G" 2>/dev/null \
            | grep -E "Slave_IO_Running:|Slave_SQL_Running:" > /work/mid_backup_slave_status.txt
        bgpid=$(pgrep -f "bgbackup.sh -c $cnf_path" | head -1)
        if [ -n "$bgpid" ]; then
            kill -TERM "$bgpid"
            echo "FOUND_AND_KILLED pid=$bgpid iter=$i"
            exit 0
        fi
    fi
    sleep 0.1
done
echo "TIMEOUT"
exit 1
SCRIPT
chmod +x "$replica_wd/detect_and_kill.sh"

docker exec -u root "$replica" /opt/bgbackup/bgbackup.sh -c /work/sigterm.cnf > "$replica_wd/sigterm_run.out" 2>&1 &
run_pid=$!

detect_result=$(docker exec "$replica" bash /work/detect_and_kill.sh "$TDC_ROOT_PW" /work/sigterm.cnf)
detect_rc=$?
assert_eq "detect-and-kill script found the backup tool and signalled bgbackup.sh" "0" "$detect_rc"

mapfile -t mid_st < <(docker exec "$replica" cat /work/mid_backup_slave_status.txt 2>/dev/null | awk '{print $2}')
assert_eq "SQL thread IS stopped right now, mid-backup (STOP SLAVE SQL_THREAD really ran)" "No" "${mid_st[1]:-}"
assert_eq "IO thread is untouched -- only the SQL thread was stopped" "Yes" "${mid_st[0]:-}"

wait "$run_pid" 2>/dev/null
run_exit=$?
assert_eq "the killed run's own exit status reflects SIGTERM (128+15)" "143" "$run_exit"

mapfile -t after_st < <(slave_status)
assert_eq "SQL thread is running AGAIN after the SIGTERM -- the exit trap's safety net fired" "Yes" "${after_st[1]:-}"
assert_eq "IO thread never stopped at all, through any of this" "Yes" "${after_st[0]:-}"

row_count=$(docker exec "$replica" mysql -uroot -p"$TDC_ROOT_PW" -Bse "SELECT COUNT(*) FROM mdbutil.backup_history WHERE hostname LIKE '%-sigtermtest'" 2>/dev/null)
assert_eq "no backup_history row at all -- the script was killed before it got that far" "0" "$row_count"

lockfile_gone=$(docker exec "$replica" bash -c "[ -f /tmp/bgbackup-sigtermtest.lock ] && echo present || echo gone")
assert_eq "the lockfile was removed by the same exit trap" "gone" "$lockfile_gone"

# Let the orphaned backup process (reparented when bash died without
# waiting on it) finish before reusing this instance/lockfile.
for i in $(seq 1 300); do
    docker exec "$replica" pgrep -f mariabackup >/dev/null 2>&1 || break
    sleep 0.5
done

###############################################################################
echo "== sanity: a normal run afterwards still completes cleanly =="
docker exec -u root "$replica" /opt/bgbackup/bgbackup.sh -c /work/sigterm.cnf > "$replica_wd/sigterm_run2.out" 2>&1
normal_exit=$?
assert_eq "a normal run completes with exit 0 after the earlier kill" "0" "$normal_exit"

status2=$(docker exec "$replica" mysql -uroot -p"$TDC_ROOT_PW" -Bse "SELECT status FROM mdbutil.backup_history WHERE hostname LIKE '%-sigtermtest' ORDER BY start_time DESC LIMIT 1" 2>/dev/null)
assert_eq "this normal run recorded a SUCCEEDED backup_history row" "SUCCEEDED" "$status2"

mapfile -t final_st < <(slave_status)
assert_eq "replica still replicating normally after all of this" "Yes" "${final_st[1]:-}"

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
