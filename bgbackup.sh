#!/bin/bash

# bgbackup - A backup shell script for MariaDB, MySQL and Percona
#
# Authors: Ben Stillman <ben@mariadb.com>, Guillaume Lefranc <guillaume@signal18.io>, Michaël de Groot <michael@chipta.com>
# License: GNU General Public License, version 3.
# Redistribution/Reuse of this code is permitted under the GNU v3 license.
# As an additional term ALL code must carry the original Author(s) credit in comment form.
# See LICENSE in this directory for the integral text.

# Functions

# Handle control-c
function sigint {
  echo "SIGINT detected. Exiting"
  if [ "$galera" = yes ] ; then
      log_info "Disabling WSREP desync on exit"
      $mysqltargetcommand "SET GLOBAL wsrep_desync=OFF"
  fi
  # 130 is the standard exit code for SIGINT
  exit 130
}

# Mail function
function mail_log {
    mail -s "$mailsubpre $HOSTNAME $instance_name:-mysql Backup $log_status $mdate" "$maillist" < "$logfile"
}

# Function to check log for okay
function log_check {
    if grep -Eq 'completed OK!$' "$logfile" ; then
        log_status=SUCCEEDED
    else
        log_status=FAILED
    fi
}

# Logging function
function log_info() {
    if [ "$verbose" == "no" ] ; then
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    else
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" | tee -a "$logfile"
    fi
    if [ "$syslog" = yes ] ; then
        logger -p local0.notice -t bgbackup "$*"
    fi
}

# Function in case history system is down
function sql_history_down() {
        log_info "HISTORY QUERY WOULD FAIL: $*"
}

# Error function
function log_error() {
    if [ "$syslog" = yes ] ; then
        logger -p local0.notice -t bgbackup "FATAL: $*"
    fi
    printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" 1>&2
    if [ "$mailon" = "failure" ] || [ "$mailon" = "all" ] ; then
        mail_log
    fi
    exit 1
}

# Function to get WHERE clause for hostname (in case siblings are specified)
function generate_hostname_where {
    insert_host=$(hostname)
    [ -n "$instance_name" ] && insert_host="${insert_host}-$instance_name"

    this_hostname_where="hostname='$insert_host'"

    siblings_hostname_where="hostname IN ('$insert_host'"
    
    if [ -n "$siblings" ]; then
        # Use a loop to properly quote each sibling
        siblings_quoted=""
        IFS=',' read -ra siblings_array <<< "$siblings"
        for sibling in "${siblings_array[@]}"; do
            siblings_quoted+="'$sibling',"
        done
        # Remove the trailing comma if siblings_quoted is not empty
        if [ -n "$siblings_quoted" ]; then
            siblings_quoted=${siblings_quoted%,}  # Remove the trailing comma
            siblings_hostname_where="${siblings_hostname_where},${siblings_quoted}"
        fi
    fi
    siblings_hostname_where="${siblings_hostname_where})"
}


function innocreate {
    innocommand="$innobackupex"
    [ -n "$defaults_file" ] && innocommand=$innocommand" --defaults-file=$defaults_file"
    [ -n "$defaults_extra_file" ] && innocommand=$innocommand" --defaults-extra-file=$defaults_extra_file"
    if [[ "$has_innobackupex" == 0 ]] ; then innocommand=$innocommand" --backup --target-dir" ; fi
    dirdate=$(date +%Y-%m-%d_%H-%M-%S)
    if [[ "$mysqlhist_is_down:-0" == "0" ]]; then
        alreadyfull=$($mysqlhistcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE DATE(end_time) = CURDATE() AND butype = 'Full' AND status = 'SUCCEEDED' AND ${this_hostname_where} AND deleted_at IS NULL")
        anyfull=$($mysqlhistcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE butype = 'Full' AND status = 'SUCCEEDED' AND ${this_hostname_where} AND deleted_at IS NULL")
    else
        alreadyfull=0
        anyfull=0
    fi
    if ( ( [ "$(date +%A)" = "$fullbackday" ] || [ "$fullbackday" = "Everyday" ]) && [ "$alreadyfull" -eq 0 ] ) || [ "$anyfull" -eq 0 ] || [ "$fullbackday" = "Always" ] || [ "$force" == "1" ]; then
        [ "$force" == "1" ] && log_info "Creating full backup because FORCE was passed in CLI arguments."
        butype=Full
        dirname="$backupdir/full-$dirdate"
        innocommand="$innocommand $dirname"
    else
        if [ "$differential" = yes ] ; then
            butype=Differential
            diffbase=$($mysqlhistcommand "SELECT bulocation FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND ${this_hostname_where} AND butype = 'Full' AND deleted_at IS NULL ORDER BY start_time DESC LIMIT 1")
            dirname="$backupdir/diff-$dirdate"

            if [ -d "$diffbase" ]; then
                innocommand="$innocommand $dirname"
                if [ "$has_innobackupex" == "1" ] ; then innocommand=$innocommand" --incremental" ; fi
                innocommand=$innocommand" --incremental-basedir=$diffbase"
            else
                log_info "WARNING! Differential basedir $diffbase does not exist! Creating full backup instead."
                butype=Full
                dirname="$backupdir/full-$dirdate"
                innocommand="$innocommand $dirname"
            fi
        else
            butype=Incremental
            incbase=$($mysqlhistcommand "SELECT bulocation FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND ${this_hostname_where} AND deleted_at IS NULL ORDER BY start_time DESC LIMIT 1")
            if [ -d "$incbase" ]; then
                dirname="$backupdir/incr-$dirdate"
                innocommand="$innocommand $dirname"
                if [ "$has_innobackupex" == "1" ] ; then innocommand=$innocommand" --incremental" ; fi
                innocommand=$innocommand" --incremental-basedir=$incbase"
            else
                log_info "WARNING! Incremental basedir $incbase does not exist! Creating full backup instead."
                butype=Full
                dirname="$backupdir/full-$dirdate"
                innocommand="$innocommand $dirname"
            fi
        fi
    fi


    [ ! -z "$backupuser" ] && innocommand=$innocommand" --user=$backupuser"
    [ ! -z "$backuppass" ] && innocommand=$innocommand" --password=$backuppass"
    [ ! -z "$socket" ] && innocommand=$innocommand" --socket=$socket"
    [ ! -z "$host" ] && innocommand=$innocommand" --host=$host"
    [ ! -z "$hostport" ] && innocommand=$innocommand" --port=$hostport"
    if [ "$galera" = yes ] ; then innocommand=$innocommand" --galera-info" ; fi
    if [ "$slave" = yes ] ; then innocommand=$innocommand" --slave-info" ; fi
    if [ "$parallel" = yes ] ; then innocommand=$innocommand" --parallel=$threads" ; fi
    if [ "$compress" = yes ] ; then innocommand=$innocommand" --compress --compress-threads=$threads" ; fi
    if [ "$encrypt" = yes ] ; then innocommand=$innocommand" --encrypt=AES256 --encrypt-key=${cryptkey@Q}" ; fi
    if [ "$nolock" = yes ] ; then innocommand=$innocommand" --no-lock" ; fi
    if [ "$nolock" = yes ] && [ "$slave" = yes ] ; then innocommand=$innocommand" --safe-slave-backup" ; fi
    if [ "$rocksdb" = no ] && [ "$backuptool" = "1" ]; then innocommand=$innocommand" --skip-rocksdb-backup" ; fi
}

# Function to decrypt xtrabackup_checkpoints
function checkpointsdecrypt {
    xbcrypt -d --encrypt-key-file="$cryptkey" --encrypt-algo=AES256 < "$dirname"/xtrabackup_checkpoints.xbcrypt > "$dirname"/xtrabackup_checkpoints
}

# Function to disable/enable MONyog alerts
function monyog {
    curl "${monyoghost}:${monyogport}/?_object=MONyogAPI&_action=Alerts&_value=${1}&_user=${monyoguser}&_password=${monyogpass}&_server=${monyogserver}"
}

# Function to do the backup
function backer_upper {
    innocreate
    if [ "$monyog" = yes ] ; then
        log_info "Disabling MONyog alerts"
        monyog disable
        sleep 30
    fi
    if [ "$openfilelimit" -gt 0 ]; then 
        log_info "Increasing open files limit to $openfilelimit"
        ulimit -n "$openfilelimit"
    fi
    if [ "$galera" = yes ] ; then
        log_info "Enabling WSREP desync."
        $mysqltargetcommand "SET GLOBAL wsrep_desync=ON"
    fi
    log_info "Beginning ${butype} Backup"
    log_info "Executing $(basename $innobackupex) command: $(echo "$innocommand" | sed -e 's/password=.* /password=XXX /g')"
    $innocommand 2>> "$logfile"
    log_check

    if [ "$galera" = yes ] ; then
        log_info "Disabling WSREP desync."
        queue=1
        until [ "$queue" -eq 0 ]; do
            queue=$($mysqltargetcommand" \"show global status like 'wsrep_local_recv_queue';\" -ss" | awk '{ print $2 }')
            log_info "Current queue is $queue, if there is still a queue we wait until we disable desync mode"
            sleep 10
        done
        $mysqltargetcommand "SET GLOBAL wsrep_desync=OFF;"
    fi

    if [ "$monyog" = yes ] ; then
        log_info "Enabling MONyog alerts"
        monyog enable
        sleep 30
    fi
    log_info "$butype backup $log_status"
    log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
}

# Function to write configuration
function backup_write_config {
    conf_file_path="${bulocation}/bgbackup.cnf"
    echo "# Backup configuration - to make sure the restore uses the same tool version. Newer version might also work." > $conf_file_path
    echo "butype=${butype@Q}" >> $conf_file_path
    echo "backuptool=${backuptool@Q}" >> $conf_file_path
    echo "xtrabackup_version=${xtrabackup_version@Q}" >> $conf_file_path
    echo "server_version=${server_version@Q}" >> $conf_file_path
    echo "compress=${compress@Q}" >> $conf_file_path
    echo "encrypt=${encrypt@Q}" >> $conf_file_path
    echo "# if encryption is enabled, the following variable must be filled for fgrestore to work:" >> $conf_file_path
    echo "#cryptkey=your_crypt_key" >> $conf_file_path
    echo "galera=${galera@Q}" >> $conf_file_path
    echo "slave=${slave@Q}" >> $conf_file_path
    echo "end_time=${endtime@Q}" >> $conf_file_path
    if [ "$butype" = "Differential" ]; then
        echo "incbase=${diffbase@Q}" >> $conf_file_path
    elif [ "$butype" == "Incremental" ]; then
        echo "incbase=${incbase@Q}" >> $conf_file_path
    fi

    log_info "Wrote backup configuration file $conf_file_path"
    # VALUES (UUID(), "$insert_host", "$starttime", "$endtime", "$weekly", "$monthly", "$yearly", "$bulocation", "$logfile", "$log_status", "$butype", "$compress", "$encrypt", "$cryptkey", "$galera", "$slave", "$threads", "$xtrabackup_version", "$server_version", "$backup_size", NULL)
}

# Function to build mysql history command
function mysqlhistcreate {
    mysql=$(command -v mysql)
    mysqlhistcommand="$mysql"
    [ -n "$backuphist_defaults_file" ] && mysqlhistcommand=$mysqlhistcommand" --defaults-file=$backuphist_defaults_file"
    [ -n "$backuphist_defaults_extra_file" ] && mysqlhistcommand=$mysqlhistcommand" --defaults-extra-file=$backuphist_defaults_extra_file"
    mysqlhistcommand=$mysqlhistcommand" -u$backuphistuser"
    [ -n "$backuphisthost" ] && mysqlhistcommand=$mysqlhistcommand" -h$backuphisthost"
    [ -n "$backuphistpass" ] && mysqlhistcommand=$mysqlhistcommand" -p$backuphistpass"
    [ -n "$backuphistport" ] && mysqlhistcommand=$mysqlhistcommand" -P $backuphistport"
    [ -n "$backuphistsocket" ] && mysqltargetcommand=$mysqltargetcommand" -S $backuphistsocket"
    mysqlhistcommand=$mysqlhistcommand" -Bse "
}
# Function to build mysql target command
function mysqltargetcreate {
    mysql=$(command -v mysql)
    mysqltargetcommand="$mysql"
    [ -n "$defaults_file" ] && mysqltargetcommand=$mysqltargetcommand" --defaults-file=$defaults_file"
    [ -n "$defaults_extra_file" ] && mysqltargetcommand=$mysqltargetcommand" --defaults-extra-file=$defaults_extra_file"
    mysqltargetcommand=$mysqltargetcommand" -u$backupuser"
    [ -n "$host" ] && mysqltargetcommand=$mysqltargetcommand" -h $host"
    [ -n "$backuppass" ] && mysqltargetcommand=$mysqltargetcommand" -p$backuppass"
    [ -n "$hostport" ] && mysqltargetcommand=$mysqltargetcommand" -P $hostport"
    [ -n "$socket" ] && mysqltargetcommand=$mysqltargetcommand" -S $socket"
    mysqltargetcommand=$mysqltargetcommand" -Bse "
}

# Function to build mysqldump command on history database
function mysqldumpcreate {
    mysqldump=$(command -v mysqldump)
    mysqldumpcommand="$mysqldump"
    [ -n "$backuphist_defaults_file" ] && mysqldumpcommand=$mysqldumpcommand" --defaults-file=$backuphist_defaults_file"
    [ -n "$backuphist_defaults_extra_file" ] && mysqldumpcommand=$mysqldumpcommand" --defaults-extra-file=$backuphist_defaults_extra_file"
    mysqldumpcommand=$mysqldumpcommand" -u $backuphistuser"
    mysqldumpcommand=$mysqldumpcommand" --loose-no-tablespaces"  # MySQL 8.0.21 compatibility
    [ -n "$backuphisthost" ] && mysqldumpcommand=$mysqldumpcommand" -h $backuphisthost"
    [ -n "$backuphistpass" ] && mysqldumpcommand=$mysqldumpcommand" -p$backuphistpass"
    [ -n "$backuphistport" ] && mysqldumpcommand=$mysqldumpcommand" -P $backuphistport"
    [ -n "$backuphistsocket" ] && mysqldumpcommand=$mysqldumpcommand" -S $backuphistsocket"
    mysqldumpcommand=$mysqldumpcommand" $backuphistschema"
    mysqldumpcommand=$mysqldumpcommand" backup_history"
}

# Function to create backup_history table if not exists
function create_history_table {
    createtable=$(cat <<EOF
CREATE TABLE IF NOT EXISTS $backuphistschema.backup_history (
uuid varchar(40) NOT NULL,
hostname varchar(100) DEFAULT NULL,
start_time timestamp NULL DEFAULT NULL,
end_time timestamp NULL DEFAULT NULL,
bulocation varchar(255) DEFAULT NULL,
logfile varchar(255) DEFAULT NULL,
status varchar(25) DEFAULT NULL,
butype varchar(20) DEFAULT NULL,
weekly tinyint UNSIGNED NOT NULL,
monthly tinyint UNSIGNED NOT NULL,
yearly tinyint UNSIGNED NOT NULL,
compressed varchar(5) DEFAULT NULL,
encrypted varchar(5) DEFAULT NULL,
cryptkey varchar(255) DEFAULT NULL,
galera varchar(5) DEFAULT NULL,
slave varchar(5) DEFAULT NULL,
threads tinyint(2) DEFAULT NULL,
xtrabackup_version varchar(120) DEFAULT NULL,
server_version varchar(120) DEFAULT NULL,
backup_size varchar(20) DEFAULT NULL,
deleted_at timestamp NULL DEFAULT NULL,
PRIMARY KEY (uuid),
INDEX hostname_endtime (hostname, end_time),
INDEX hostname_status_deleted (hostname, status, deleted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8
EOF
)
    $mysqlhistcommand "$createtable" >> "$logfile"
    log_info "backup history table created"
}

function migrate_history_table {
    altertable=$(cat << EOF
ALTER TABLE $backuphistschema.backup_history
ADD COLUMN weekly tinyint UNSIGNED NOT NULL DEFAULT 0,
ADD COLUMN monthly tinyint UNSIGNED NOT NULL DEFAULT 0,
ADD COLUMN yearly tinyint UNSIGNED NOT NULL DEFAULT 0,
MODIFY COLUMN server_version VARCHAR(120) NULL DEFAULT NULL,
ADD INDEX hostname_endtime (hostname, end_time),
ADD INDEX hostname_status_deleted (hostname, status, deleted_at)
EOF
)
    $mysqlhistcommand "$altertable" >> "$logfile"
    log_info "backup history table migrated"
}


# Function to write backup history to database
function backup_history_and_mark_failed {
    server_version=$(mysqld -V)
    xtrabackup_version=$(xtrabackup --version 2>&1|grep 'based')
    bulocation="$dirname"

    if [ ! -d "$bulocation" ]; then
      # Directory does not exist, create it
      mkdir -p "$bulocation"
      log_info "Backup did not produce any files, directory '$bulocation' now created."

      # Create a warning file inside the new directory
      warning_file="$bulocation/warning.txt"
      echo "Warning: This directory was created because it did not exist." > "$warning_file"
      log_info "Warning file created at '$warning_file'."
    fi
    backup_size=$(du -sm "$dirname" | awk '{ print $1 }')"M"

    if [ "$log_status" != "SUCCEEDED" ]; then
        log_info "Renaming failed backup from $bulocation..."
        backup_to_rename=$(basename $bulocation)
        mv "${backupdir}/${backup_to_rename}" "${backupdir}/FAILED_${backup_to_rename}"
        bulocation="${backupdir}/FAILED_${backup_to_rename}"

        log_info "Backup renamed, new backup location is $bulocation"
    fi

    weekly=0
    monthly=0
    yearly=0

    [ "${keepweekly:-0}" -gt "0" ] && weekly=$($mysqlhistcommand "SELECT IF(COUNT(*) > 0, 0, 1) AS weekly FROM $backuphistschema.backup_history WHERE ${siblings_hostname_where} AND YEAR(end_time) = YEAR('$endtime') AND WEEK(end_time) = WEEK('$endtime') AND status='SUCCEEDED' AND weekly=1")
    [ "${keepmonthly:-0}" -gt "0" ] && monthly=$($mysqlhistcommand "SELECT IF(COUNT(*) > 0, 0, 1) AS monthly FROM $backuphistschema.backup_history WHERE ${siblings_hostname_where} AND YEAR(end_time) = YEAR('$endtime') AND MONTH(end_time) = MONTH('$endtime') AND status='SUCCEEDED' AND monthly=1")
    [ "${keepyearly:-0}" -gt "0" ] && yearly=$($mysqlhistcommand "SELECT IF(COUNT(*) > 0, 0, 1) AS yearly FROM $backuphistschema.backup_history WHERE ${siblings_hostname_where} AND YEAR(end_time) = YEAR('$endtime') AND status='SUCCEEDED' AND yearly=1")

    historyinsert=$(cat <<EOF
INSERT INTO $backuphistschema.backup_history (uuid, hostname, start_time, end_time, weekly, monthly, yearly, bulocation, logfile, status, butype, compressed, encrypted, cryptkey, galera, slave, threads, xtrabackup_version, server_version, backup_size, deleted_at)
VALUES (UUID(), "$insert_host", "$starttime", "$endtime", "$weekly", "$monthly", "$yearly", "$bulocation", "$logfile", "$log_status", "$butype", "$compress", "$encrypt", "$cryptkey", "$galera", "$slave", "$threads", "$xtrabackup_version", "$server_version", "$backup_size", NULL)
EOF
)
    $mysqlhistcommand "$historyinsert"
    #verify insert
    verifyinsert=$($mysqlhistcommand "select count(*) from $backuphistschema.backup_history where ${this_hostname_where} and end_time='$endtime'")
    if [[ "${mysqlhist_is_down:-0}" == "0" &&  "$verifyinsert" -eq "1" ]]; then
        log_info "Backup history database record inserted successfully."
    else
        log_info "Backup history database record NOT inserted successfully!"

        log_info "Renaming history failed backup so that it gets deleted eventually..."
        backup_to_rename=$(basename $bulocation)
        mv "${backupdir}/${backup_to_rename}" "${backupdir}/HISTFAILED_${backup_to_rename}"
        bulocation="${backupdir}/HISTFAILED_${backup_to_rename}"

        log_info "Backup renamed, new backup location is $bulocation"

        log_info "WARNING! Unabled to save backup history, this means incrementals and differentials cannot be created. The backup was renamed to HISTFAILED_ to allow it to be rotated."
    fi
}

# Function to cleanup backups.
function backup_cleanup {
    if [ $log_status = "SUCCEEDED" ] && [ $butype = "Full" ]; then

        log_info "Marking expired week backups as deletable backup"
        $mysqlhistcommand "UPDATE $backuphistschema.backup_history SET weekly=2 WHERE ${siblings_hostname_where} AND weekly=1 AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP() - (604800 * ($keepweekly + 1))"

        log_info "Marking expired month backups as deletable backup"
        $mysqlhistcommand "UPDATE $backuphistschema.backup_history SET monthly=2 WHERE ${siblings_hostname_where} AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP() - (86400*31 * ($keepmonthly + 1))"

        log_info "Marking expired year backups as deletable backup"
        $mysqlhistcommand "UPDATE $backuphistschema.backup_history SET yearly=2 WHERE ${siblings_hostname_where} AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP() - (86400*366 * ($keepyearly + 1))"

        log_info "Checking backups to clean up - $keepdaily days to keep."
        delcount=$($mysqlhistcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE yearly <> 1 AND monthly <> 1 AND weekly <> 1 AND ${siblings_hostname_where} and UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP()-(3600 + (86400 * $keepdaily)) AND status = 'SUCCEEDED' AND deleted_at IS NULL")
        if [ -n "$delcount" ] && [ "$delcount" -gt 0 ]; then
            deletecmd=$($mysqlhistcommand "SELECT bulocation FROM $backuphistschema.backup_history WHERE yearly <> 1 AND monthly <> 1 AND weekly <> 1 AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP()-(3600 + (86400 * $keepdaily)) AND ${siblings_hostname_where} AND status = 'SUCCEEDED' AND deleted_at IS NULL")
            while IFS= read -r todelete; do
                log_info "Deleted backup $todelete"
                rm -Rf "$todelete"
                markdeleted=$($mysqlhistcommand "UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE bulocation = '$todelete' AND ${siblings_hostname_where} AND status = 'SUCCEEDED'")
            done <<< "$deletecmd"
        else
            log_info "No backups to delete at this time."
        fi
    elif [ $log_status = "SUCCEEDED" ] && [ $butype != "Full" ]; then
        log_info "Not deleting any backups as this is not a full backup run."
    else
        log_info "Backup failed. No backups deleted at this time."
    fi
}

# Function to cleanup failed backups
function backup_failed_cleanup {

    if [ $butype = "Full" ]; then
        findfailedcmd=$(find "$backupdir" -maxdepth 1 -type d -mtime +${keepfaileddays:-365} -name '*FAILED_*')
        if [ -n "$findfailedcmd" ]; then
            while IFS= read -r todelete; do
                rm -Rf "$todelete"
                markdeleted=$($mysqlhistcommand "UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE bulocation LIKE '%/$todelete' AND ${siblings_hostname_where}")
                log_info "Deleted failed backup $todelete"
            done <<< "$findfailedcmd"
        fi
    fi

}

# Function to dump $backuphistschema schema
function mdbutil_backup {
    if [ $backuphistschema != "" ] &&  [ $log_status = "SUCCEEDED" ] &&  [ "${mysqlhist_is_down:-0}" == "0" ]; then
        mdbutildumpfile="$backupdir"/"$backuphistschema".backup_history-"$dirdate".sql
        $mysqldumpcommand > "$mdbutildumpfile" 2>&1 |grep -v "A partial dump from a server that has GTIDs will by default include the GTIDs "
        log_info "Backup history table dumped to $mdbutildumpfile"
    else
        log_info "Backup failed or history system is down. Not creating backup of history database."
    fi

}

# Function to cleanup mdbutil backups
function mdbutil_backup_cleanup {
    if [ $log_status = "SUCCEEDED" ] &&  [ "${mysqlhist_is_down:-0}" == "0" ]; then
        delbkuptbllist=$(ls -tp "$backupdir" | grep "$backuphistschema".backup_history | tail -n +$((keepbkuptblnum+=1)))
        for bkuptbltodelete in $delbkuptbllist; do
            rm -f "$backupdir"/"$bkuptbltodelete"
            log_info "Deleted backup history backup $bkuptbltodelete"
        done
    else
        log_info "Backup failed. No backup history backups deleted at this time."
    fi
}

# Function to cleanup logs
function log_cleanup {
    if [ $log_status = "SUCCEEDED" ]; then
        delloglist=$(ls -tp "$logpath" | grep bgbackup | tail -n +$((keeplognum+=1)))
        for logtodelete in $delloglist; do
            rm -f "$logpath"/"$logtodelete"
            log_info "Deleted log file $logpath/$logtodelete"
        done
    else
        log_info "Backup failed. Not deleting any log files at this time."
    fi
}

# Function to copy and secure log to backup directory
function copy_secured_log_to_backup {
    cp "$logfile" "$bulocation/bgbackup.log"
    if [ "$encrypt" = yes ]; then
        log_info "Replacing cryptkey in log file"
        sed "s/${cryptkey}/**REDACTED**/g" "$bulocation/bgbackup.log"
    fi
    log_info "Copied the log file to the backup directory"
}

# Function to check config parameters
function config_check {

    if [ "$galera" = "yes" ]; then
        has_galera=$($mysqltargetcommand "SHOW GLOBAL VARIABLES LIKE 'wsrep_provider_options'" | grep 'wsrep_provider'|grep 'libgalera' | wc -l)
        if [ "$has_galera" -eq 0 ]; then
            log_info "Disabling galera flow control is enabled, but galera library is not loaded. Not disabling galera flow control."
            galera="error"
        fi
    fi


    # Verify if fullbackupday is set correctly
    found_fullbackup_timing=false
    fullbackup_options=("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Everyday", "Always")
    for day in "${fullbackup_options[@]}"; do
        if [[ "$day" == "$fullbackday" ]]; then
            found_fullbackup_timing=true
        fi
    done

    if [[ "$found_fullbackup_timing" == false ]]; then
        log_error "Fatal: fullbackupday must be any of Monday Tuesday Wednesday Thursday Friday Saturday Sunday Everyday Always"
    fi

}

function galera_check {
    if [ "$galera" == "yes" ]; then
        num_sst_processes=`ps aux|grep wsrep_sst|grep -v grep|wc -l`
        if [ "$num_sst_processes" -gt 0  ]; then
            log_error "SST currently in progress, not creating a backup now"
        fi

        if [ "$galera_minimum_nodes" -gt 0 ] ; then
            current_nodes=$($mysqltargetcommand "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'"|grep wsrep_cluster|awk '{print $2}')
            if [ "$galera_minimum_nodes" -gt "$current_nodes" ]; then
                log_error "Not enough nodes are participating in the Galera cluster, therefore not creating a backup now"
            fi
        fi
    fi
}

function preflight_check {
    preflight_return_value=$(eval "$preflight_script" 2>&1)
    if [ "$preflight_return_value" != "OK" ]; then
        log_info "Preflight script did not return OK, preflight check output:"
        log_info "$preflight_return_value"
        if [[ ${preflight_return_value:0:9} == "NO_ERROR;" ]]; then
            log_info "Preflight indicated there is no error with this situation. Therefore the backup process is exiting without stderr output"
            if [ "$debug" = yes ] ; then
                debugme
            fi
            exit 0
        else
            log_error "Not creating a backup because preflight check failed"
        fi
    else
        log_info "Preflight check was OK, proceeding to take backup"
    fi
}

# Debug variables function
function debugme {
    log_info "defaults file: " "$defaults_file"
    log_info "defaults extra file: " "$defaults_extra_file"
    log_info "backuphist defaults file: " "$backuphist_defaults_file"
    log_info "backuphist defaults extra file: " "$backuphist_defaults_extra_file"
    log_info "host: " "$host"
    log_info "hostport: " "$hostport"
    log_info "backupuser: " "$backupuser"
    log_info "backuppass: " "$backuppass"
    log_info "monyog: " "$monyog"
    log_info "monyogserver: " "$monyogserver"
    log_info "monyoguser: " "$monyoguser"
    log_info "monyogpass: " "$monyogpass"
    log_info "monyoghost: " "$monyoghost"
    log_info "monyogport: " "$monyogport"
    log_info "fullbackday: " "$fullbackday"
    log_info "keepdaily: " "$keepdaily"
    log_info "keepweekly: " "$keepweekly"
    log_info "keepmonthly: " "$keepmonthly"
    log_info "keepyearly: " "$keepyearly"
    log_info "backupdir: " "$backupdir"
    log_info "logpath: " "$logpath"
    log_info "threads: " "$threads"
    log_info "parallel: " "$parallel"
    log_info "encrypt: " "$encrypt"
    log_info "cryptkey: " "$cryptkey"
    log_info "nolock: " "$nolock"
    log_info "compress: " "$compress"
    log_info "tempfolder: " "$tempfolder"
    log_info "galera: " "$galera"
    log_info "slave: " "$slave"
    log_info "maillist: " "$maillist"
    log_info "mailsubpre: " "$mailsubpre"
    log_info "mdate: " "$mdate"
    log_info "logfile: " "$logfile"
    log_info "store_log_with_backup: " "$store_log_with_backup"
    log_info "queue: " "$queue"
    log_info "butype: " "$butype"
    log_info "log_status: " "$log_status"
    log_info "budirdate: " "$budirdate"
    log_info "innocommand: " "$innocommand"
    log_info "prepcommand: " "$prepcommand"
    log_info "dirname: " "$dirname"
    log_info "siblings_hostname_where: " "$siblings_hostname_where"
    log_info "budir: " "$budir"
    log_info "run_after_success: " "$run_after_success"
    log_info "run_after_fail: " "$run_after_fail"
}

############################################
# Begin script

# we trap control-c
trap sigint INT

scriptdir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Function to display usage
usage() {
    echo "Usage: $0 [-c config_file | --config config_file] [-f | --force] [-v | --verbose] [-d | --debug]"
    exit 1
}

etccnf="/etc/bgbackup.cnf"
force=0

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c|--config)
            if [[ -n "$2" ]]; then
                etccnf="$2"
                shift
            else
                echo "Error: --config requires a non-empty option argument."
                usage
            fi
            ;;
        -f|--force)
            force=1
            ;;
        -v|--verbose)
            cli_verbose=true
            ;;
        -d|--debug)
            cli_debug=true
            ;;
        *)
            echo "Error: Unknown option $1"
            usage
            ;;
    esac
    shift
done

if [ -e "$etccnf" ]; then
    source "$etccnf"
elif [ -e "$scriptdir"/bgbackup.cnf ]; then
    source "$scriptdir"/bgbackup.cnf
else
    echo "Error: bgbackup.cnf configuration file not found"
    echo "The configuration file must exist somewhere in /etc or"
    echo "in the same directory where the script is located"
    exit 1
fi

[ -n "$cli_verbose" ] && verbose="yes"
[ -n "$cli_debug" ] && debug="yes"

if [ ! -d "$logpath" ]; then
    log_error "Error: Log dir $logpath not found"
fi

if [ ! -w "$logpath" ]; then
    log_error "Error: Log dir $logpath not writeable"
fi

# Set some specific variables
starttime=$(date +"%Y-%m-%d %H:%M:%S")
mdate=$(date +%m/%d/%y)    # Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/bgbackup_$(date +%Y-%m-%d-%T).log    # logfile




# verify the backup directory exists
if [ ! -d "$backupdir" ]
then
    log_info "Error: $backupdir directory not found"
    log_error "The configured directory for backups does not exist. Please create this first."
fi

# verify user running script has permissions needed to write to backup directory
if [ ! -w "$backupdir" ]; then
    log_info "Error: $backupdir directory is not writable."
    log_error "Verify the user running this script has write access to the configured backup directory."
fi


# Check for mariabackup or xtrabackup
if [ "$backuptool" == "1" ] && command -v mariabackup >/dev/null; then
    innobackupex=$(command -v mariabackup)
    has_innobackupex=0
elif [ "$backuptool" == "2" ] && command -v innobackupex >/dev/null; then
    innobackupex=$(command -v innobackupex)
    has_innobackupex=1
elif [ "$backuptool" == "2" ] && command -v xtrabackup >/dev/null; then
    innobackupex=$(command -v xtrabackup)  # Percona xtrabackup 8.0 phased out innobackupex command
    has_innobackupex=0
else
    log_error "The backuptool does not appear to be installed. Please check that a valid backuptool is chosen in bgbackup.cnf and that it's installed."
fi

# Check if old 'keepnum' variable is specified
if [[ -n "$keepnum" && -z "$keepdaily" ]]; then
    log_info "DEPRECATION WARNING! We now support keeping daily, weekly, monthly and yearly backups. Please specify 'keepdaily=$keepnum' instead of 'keepnum', as this variable might not be supported anymore in future releases."
    keepdaily="$keepnum"
fi

[ "$force" == "1" ] && echo -e "Forcing a full backup. When finished, the backup path will be printed.\n\nThe backup will be rotated normally, after $keepdaily days (possibly longer in case weekly, monthly or yearly retention is enabled.\n\nTo enable extra debug information or print the log output, add --debug and/or --verbose.\n"

# Check if we are not running too long (when the disk is full or locked, bgbackup can be stuck
runtime=`/usr/bin/ps -o etimes= -p "$$"`
if [ $runtime -gt 300 ]; then
    log_error "The script was started more then 5 minutes ago, something is wrong."
fi

# Check that we are not already running

lockfile=/tmp/bgbackup
[ -n "$instance_name" ] && lockfile=$lockfile"-$instance_name"
lockfile=$lockfile".lock"

if [ -f $lockfile ]
then
    log_error "Another instance of $lockfile is already running. Exiting."
fi
trap 'rm -f $lockfile' 0
touch $lockfile

generate_hostname_where
[ "$debug" = yes ] && log_info "Generated siblings where: $siblings_hostname_where, this hostname where: $this_hostname_where"

mysqlhistcreate
[ "$debug" = yes ] && log_info "Generated mysql history command: $mysqlhistcommand"
mysqldumpcreate
[ "$debug" = yes ] && log_info "Generated mysql history dump: $mysqldumpcommand"
mysqltargetcreate
[ "$debug" = yes ] && log_info "Generated mysql history dump: $mysqltargetcommand"

[ -z "$backuphist_verify" ] || [ "$backuphist_verify" = true ] || [ "$backuphist_verify" = 1 ] && backuphist_verify=1
[ "$backuphist_verify" != 1 ] && backuphist_verify=0

    
# Check that mysql client can connect
$mysqlhistcommand "SELECT 1 FROM DUAL" 1>/dev/null 2>/dev/null
if [ "$?" -eq 1 ]; then
  if [ "$debug" = yes ] ; then
    debugme
    log_info "$mysqlhistcommand"
  fi
  [ "$backuphist_verify" = 1 ] && log_error "Error: mysql client is unable to connect with the information you have provided. Please check your configuration and try again."
  [ "$backuphist_verify" = 0 ] && log_info "Warning: mysql client is unable to connect with the information you have provided. We recommend to have working backup history for monitoring and support of differentials. Without, all created backups will be full backups."

    mysqlhistcommand="sql_history_down "
    mysqldumpcommand="sql_history_down "
    mysqlhist_is_down=1
fi

if [[ "$mysqlhist_is_down:-0" == "0" ]]; then
    # Check that the database exists before continuing further
    $mysqlhistcommand "USE $backuphistschema"
    if [ "$?" -eq 1 ]; then
      [ "$backuphist_verify" = 1 ] && log_error "Error: The database '$backuphistschema' containing the history does not exist. Please check your configuration and try again."
      [ "$backuphist_verify" = 0 ] && log_info "Warning: The database '$backuphistschema' containing the history does not exist.  We recommend to have working backup history for monitoring and support of differentials. Without, all created backups will be full backups."
    fi

    check_table=$($mysqlhistcommand "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$backuphistschema' AND table_name='backup_history' ")
    if [ "$check_table" -eq 0 ]; then
        create_history_table # Create history table if it doesn't exist
    fi

    need_migrate_table=$($mysqlhistcommand "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$backuphistschema' AND table_name='backup_history' AND column_name='weekly'")
    if [ "$need_migrate_table" -eq 0 ]; then
        migrate_history_table # Migrate history table if it is old version
    fi
fi

mysqltargetcreate

config_check # Check vital configuration parameters

if [ "$force" = 0 ]; then
    galera_check # Check if minimum nodes are available on Galera cluster
    preflight_check # Run preflight check script to stop (for example) stop backup from running on primary nodes
else
    log_info "Skipping galera and preflight checks because --force is enabled"
fi

backer_upper # Execute the backup.

backup_cleanup # Cleanup old backups.

backup_failed_cleanup  # Cleanup old failed backups

endtime=$(date +"%Y-%m-%d %H:%M:%S")

backup_history_and_mark_failed

backup_write_config # Write configuration needed for restoring

mdbutil_backup

mdbutil_backup_cleanup

log_cleanup

if [ "$store_log_with_backup" = yes ]; then
    copy_secured_log_to_backup
fi

if ( [ "$log_status" = "FAILED" ] && [ "$mailon" = "failure" ] ) || [ "$mailon" = "all" ] ; then
    mail_log # Mail results to maillist.
fi

# run commands after backup, eventually
if [ "$log_status" = "SUCCEEDED" ] && [ ! -z "$run_after_success" ] ; then
    $run_after_success >> "$logfile" # run the command if backup was successful
elif [ "$log_status" = "FAILED" ] && [ ! -z "$run_after_fail" ] ; then
    $run_after_fail >> "$logfile" # run the command if backup had failed
fi

if [ "$debug" = yes ] ; then
    debugme
fi

[ "$force" == "1" ] && echo -e "\nForced full backup finished. The status was: $log_status - check the log file in ${log_path}. The backup path:\n${bulocation}" 

exit 0
