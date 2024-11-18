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

# Error function
function log_error() {
    if [ "$syslog" = yes ] ; then
        logger -p local0.notice -t bgrestore "$*"
    fi
    printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" 1>&2
    if [ "$mailon" = "failure" ] || [ "$mailon" = "all" ] ; then
        mail_log
    fi
    exit 1
}

# Function to create innobackupex/mariabackup command
function innocreate {
    mhost=$(hostname)
    [ -n "$instance_name" ] && mhost=$mhost"-$instance_name"
    innocommand="$innobackupex"
    [ -n "$defaults_file" ] && innocommand=$innocommand" --defaults-file=$defaults_file"
    [ -n "$defaults_extra_file" ] && innocommand=$innocommand" --defaults-file=$defaults_extra_file"
    if [[ "$has_innobackupex" == 0 ]] ; then innocommand=$innocommand" --backup --target-dir" ; fi
    dirdate=$(date +%Y-%m-%d_%H-%M-%S)
    alreadyfull=$($mysqlhistcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE DATE(end_time) = CURDATE() AND butype = 'Full' AND status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at IS NULL")
    anyfull=$($mysqlhistcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE butype = 'Full' AND status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at IS NULL")
    if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
        if ( ( [ "$(date +%A)" = "$fullbackday" ] || [ "$fullbackday" = "Everyday" ]) && [ "$alreadyfull" -eq 0 ] ) || [ "$anyfull" -eq 0 ] || [ "$fullbackday" = "Always" ]; then
            butype=Full
            dirname="$backupdir/full-$dirdate"
            innocommand="$innocommand $dirname"
        else
            if [ "$differential" = yes ] ; then
                butype=Differential
                diffbase=$($mysqlhistcommand "SELECT bulocation FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND butype = 'Full' AND deleted_at IS NULL ORDER BY start_time DESC LIMIT 1")
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
                incbase=$($mysqlhistcommand "SELECT bulocation FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at IS NULL ORDER BY start_time DESC LIMIT 1")
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
    elif [ "$bktype" = "archive" ] ; then

        [ ! -d $backupdir/.lsn ] && mkdir $backupdir/.lsn
        [ ! -d $backupdir/.lsn_full ] && mkdir $backupdir/.lsn_full

	#if tempfolder is not set then  use /tmp
	if [ -z "$tempfolder" ]	
         then
   		tempfolder=/tmp
	fi
 
	# verify the tempfolder directory exists
	if [ ! -d "$tempfolder" ]
	then
    		log_info "Error: $tempfolder  directory not found"
    		log_error "The configured directory for tempfolders does not exist. Please create this first."
	fi

	# verify user running script has permissions needed to write to tempfolder  directory
	if [ ! -w "$tempfolder" ]; then
    		log_info "Error: $tempfolder  directory is not writable."
    		log_error "Verify the user running this script has write access to the configured tempfolder directory."
	fi


        if [ "$(date +%A)" = "$fullbackday" ] || [ "$fullbackday" = "Everyday" ] ; then
            butype=Full
            innocommand=$innocommand" $tempfolder --stream=$arctype --extra-lsndir=$backupdir/.lsn_full"
            arcname="$backupdir/full-$dirdate.$arctype.gz"
        else
            if [ "$differential" = yes ] ; then
                butype=Differential
                innocommand=$innocommand" $tempfolder --stream=$arctype"
                if [ "$has_innobackupex == "1" ] ; then innocommand=$innocommand" --incremental" ; fi
                innocommand=$innocommand" --incremental-basedir=$backupdir/.lsn_full --extra-lsndir=$backupdir/.lsn"
                arcname="$backupdir/diff-$dirdate.$arctype.gz"
            else
                butype=Incremental
                innocommand=$innocommand" $tempfolder --stream=$arctype"
                if [ "$has_innobackupex == "1" ] ; then innocommand=$innocommand" --incremental" ; fi
                innocommand=$innocommand" --incremental-basedir=$backupdir/.lsn --extra-lsndir=$backupdir/.lsn"
                arcname="$backupdir/inc-$dirdate.$arctype.gz"
            fi
        fi
    fi
    if [ -n "$databases" ] && [ "$bktype" = "prepared-archive" ]; then innocommand=$innocommand" --databases=$databases"; fi
    [ ! -z "$backupuser" ] && innocommand=$innocommand" --user=$backupuser"
    [ ! -z "$backuppass" ] && innocommand=$innocommand" --password=$backuppass"
    [ ! -z "$socket" ] && innocommand=$innocommand" --socket=$socket"
    [ ! -z "$host" ] && innocommand=$innocommand" --host=$host"
    [ ! -z "$hostport" ] && innocommand=$innocommand" --port=$hostport"
    if [ "$galera" = yes ] ; then innocommand=$innocommand" --galera-info" ; fi
    if [ "$slave" = yes ] ; then innocommand=$innocommand" --slave-info" ; fi
    if [ "$parallel" = yes ] ; then innocommand=$innocommand" --parallel=$threads" ; fi
    if [ "$compress" = yes ] ; then innocommand=$innocommand" --compress --compress-threads=$threads" ; fi
    if [ "$encrypt" = yes ] ; then innocommand=$innocommand" --encrypt=AES256 --encrypt-key-file=$cryptkey" ; fi
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
        echo "Increasing open files limit to $openfilelimit"
        ulimit -n "$openfilelimit"
    fi
    if [ "$galera" = yes ] ; then
        log_info "Enabling WSREP desync."
        $mysqltargetcommand "SET GLOBAL wsrep_desync=ON"
    fi
    log_info "Beginning ${butype} Backup"
    log_info "Executing $(basename $innobackupex) command: $(echo "$innocommand" | sed -e 's/password=.* /password=XXX /g')"
    if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
        $innocommand 2>> "$logfile"
        log_check
        if [ "$encrypt" = yes ] && [ "$log_status" = "SUCCEEDED" ] ; then
        checkpointsdecrypt
    fi
    fi
    if [ "$bktype" = "archive" ] ; then
        $innocommand 2>> "$logfile" | $computil -c > "$arcname"
        log_check
    fi
    if [ "$galera" = yes ] ; then
        log_info "Disabling WSREP desync."
        queue=1
        until [ "$queue" -eq 0 ]; do
            queue=$($mysqltargetcommand" \"show global status like 'wsrep_local_recv_queue';\" -ss" | awk '{ print $2 }')
            echo "Current queue is $queue, if there is still a queue we wait until we disable desync mode"
            sleep 10
        done
        $mysqltargetcommand "SET GLOBAL wsrep_desync=OFF;"
    fi
    if [ "$monyog" = yes ] ; then
        log_info "Enabling MONyog alerts"
        monyog enable
        sleep 30
    fi
    if [ "$log_status" = "SUCCEEDED" ] && [ "$bktype" == "prepared-archive" ] ; then
        backup_prepare
    fi
    log_info "$butype backup $log_status"
    log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
}

# Function to write configuration
function backup_write_config {
    conf_file_path="${bulocation}/bgbackup.cnf"
    echo "# Backup configuration - to make sure the restore uses the same tool version. Newer version might also work." > $conf_file_path
    echo "butype=${butype}" >> $conf_file_path
    echo "backuptool=${backuptool}" >> $conf_file_path
    echo "xtrabackup_version=${xtrabackup_version}" >> $conf_file_path
    echo "server_version=${server_version}" >> $conf_file_path
    echo "compress=${compress}" >> $conf_file_path
    echo "encrypt=${encrypt}" >> $conf_file_path
    echo "cryptkey=${cryptkey}" >> $conf_file_path
    echo "galera=${galera}" >> $conf_file_path
    echo "slave=${slave}" >> $conf_file_path
    if [ "$butype" = "Differential" ]; then
        echo "incbase=$diffbase" >> $conf_file_path
    elif [ "$butype" == "Incremental" ]; then
        echo "incbase=$incbase" >> $conf_file_path
    fi

    log_info "Wrote backup configuration file $conf_file_path"
    # VALUES (UUID(), "$mhost", "$starttime", "$endtime", "$weekly", "$monthly", "$yearly", "$bulocation", "$logfile", "$log_status", "$butype", "$bktype", "$arctype", "$compress", "$encrypt", "$cryptkey", "$galera", "$slave", "$threads", "$xtrabackup_version", "$server_version", "$backup_size", NULL)
}

# Function to prepare backup
function backup_prepare {
    if [ "$backuptool" == "1" ] ; then
        prepcommand="$innobackupex --prepare --target-dir $dirname"
    else
        prepcommand="$innobackupex $dirname --apply-log"
    fi
    if [ -n "$databases" ]; then prepcommand=$prepcommand" --export"; fi
    log_info "Preparing backup."
    $prepcommand 2>> "$logfile"
    log_check
    log_info "Backup prepare complete."
    log_info "Archiving backup."
    tar cf "$dirname.tar.gz" -C "$dirname" -I "$computil" . && rm -rf "$dirname"
    log_info "Archiving complete."
}

# Function to build mysql history command
function mysqlhistcreate {
    mysql=$(command -v mysql)
    mysqlhistcommand="$mysql"
    [ -n "$backuphist_defaults_file" ] && mysqlhistcommand=$mysqlhistcommand" --defaults-file=$backuphist_defaults_file"
    [ -n "$backuphist_defaults_extra_file" ] && mysqlhistcommand=$mysqlhistcommand" --defaults-file=$backuphist_defaults_extra_file"
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
    [ -n "$defaults_extra_file" ] && mysqltargetcommand=$mysqltargetcommand" --defaults-file=$defaults_extra_file"
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
    [ -n "$backuphist_defaults_extra_file" ] && mysqldumpcommand=$mysqldumpcommand" --defaults-file=$backuphist_defaults_extra_file"
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
bktype varchar(20) DEFAULT NULL,
arctype varchar(20) DEFAULT NULL,
compressed varchar(5) DEFAULT NULL,
encrypted varchar(5) DEFAULT NULL,
cryptkey varchar(255) DEFAULT NULL,
galera varchar(5) DEFAULT NULL,
slave varchar(5) DEFAULT NULL,
threads tinyint(2) DEFAULT NULL,
xtrabackup_version varchar(120) DEFAULT NULL,
server_version varchar(50) DEFAULT NULL,
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
ADD INDEX hostname_endtime (hostname, end_time),
ADD INDEX hostname_status_deleted (hostname, status, deleted_at)
EOF
)
    $mysqlhistcommand "$altertable" >> "$logfile"
    log_info "backup history table migrated"
}


# Function to write backup history to database
function backup_history {
    server_version=$($mysqlhistcommand "SELECT @@version")
    xtrabackup_version=$(xtrabackup --version 2>&1|grep 'based')
    if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
        backup_size=$(du -sm "$dirname" | awk '{ print $1 }')"M"
        bulocation="$dirname"
    elif [ "$bktype" = "archive" ] ; then
        backup_size=$(du -sm "$arcname" | awk '{ print $1 }')"M"
        bulocation="$arcname"
    fi

    weekly=0
    monthly=0
    yearly=0

    [ "${keepweekly:-0}" -gt "0" ] && weekly=$($mysqlhistcommand "SELECT IF(COUNT(*) > 0, 0, 1) AS weekly FROM $backuphistschema.backup_history WHERE hostname='$mhost' AND YEAR(end_time) = YEAR('$endtime') AND WEEK(end_time) = WEEK('$endtime') AND status='SUCCEEDED' AND weekly=1")
    [ "${keepmonthly:-0}" -gt "0" ] && monthly=$($mysqlhistcommand "SELECT IF(COUNT(*) > 0, 0, 1) AS monthly FROM $backuphistschema.backup_history WHERE hostname='$mhost' AND YEAR(end_time) = YEAR('$endtime') AND MONTH(end_time) = MONTH('$endtime') AND status='SUCCEEDED' AND monthly=1")
    [ "${keepyearly:-0}" -gt "0" ] && yearly=$($mysqlhistcommand "SELECT IF(COUNT(*) > 0, 0, 1) AS yearly FROM $backuphistschema.backup_history WHERE hostname='$mhost' AND YEAR(end_time) = YEAR('$endtime') AND status='SUCCEEDED' AND yearly=1")

    historyinsert=$(cat <<EOF
INSERT INTO $backuphistschema.backup_history (uuid, hostname, start_time, end_time, weekly, monthly, yearly, bulocation, logfile, status, butype, bktype, arctype, compressed, encrypted, cryptkey, galera, slave, threads, xtrabackup_version, server_version, backup_size, deleted_at)
VALUES (UUID(), "$mhost", "$starttime", "$endtime", "$weekly", "$monthly", "$yearly", "$bulocation", "$logfile", "$log_status", "$butype", "$bktype", "$arctype", "$compress", "$encrypt", "$cryptkey", "$galera", "$slave", "$threads", "$xtrabackup_version", "$server_version", "$backup_size", NULL)
EOF
)
    $mysqlhistcommand "$historyinsert"
    #verify insert
    verifyinsert=$($mysqlhistcommand "select count(*) from $backuphistschema.backup_history where hostname='$mhost' and end_time='$endtime'")
    if [ "$verifyinsert" -eq 1 ]; then
        log_info "Backup history database record inserted successfully."
    else
        log_error "Backup history database record NOT inserted successfully!"
    fi
}

# Function to cleanup backups.
function backup_cleanup {
    if [ $log_status = "SUCCEEDED" ] && [ $butype = "Full" ]; then

        log_info "Marking expired week backups as deletable backup"
        $mysqlhistcommand "UPDATE $backuphistschema.backup_history SET weekly=2 WHERE hostname='$mhost' AND weekly=1 AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP() - (604800 * ($keepweekly + 1))"

        log_info "Marking expired month backups as deletable backup"
        $mysqlhistcommand "UPDATE $backuphistschema.backup_history SET monthly=2 WHERE hostname='$mhost' AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP() - (86400*31 * ($keepmonthly + 1))"

        log_info "Marking expired year backups as deletable backup"
        $mysqlhistcommand "UPDATE $backuphistschema.backup_history SET yearly=2 WHERE hostname='$mhost' AND UNIX_TIMESTAMP(end_time) < UNIX_TIMESTAMP() - (86400*366 * ($keepyearly + 1))"

        log_info "Checking backups to clean up - $keepdaily to keep."
        limitoffset=$((keepdaily-1))
        delcount=$($mysqlhistcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE yearly <> 1 AND monthly <> 1 AND weekly <> 1 AND end_time < (SELECT end_time FROM $backuphistschema.backup_history WHERE butype = 'Full' AND hostname = '$mhost' AND yearly <> 1 AND monthly <> 1 AND weekly <> 1 ORDER BY end_time DESC LIMIT $limitoffset,1) AND hostname = '$mhost' AND status = 'SUCCEEDED' AND deleted_at IS NULL")
        if [ "$delcount" -gt 0 ]; then
            deletecmd=$($mysqlhistcommand "SELECT bulocation FROM $backuphistschema.backup_history WHERE yearly <> 1 AND monthly <> 1 AND weekly <> 1 AND end_time < (SELECT end_time FROM $backuphistschema.backup_history WHERE butype = 'Full' AND hostname = '$mhost' AND weekly <> 1 AND monthly <> 1 AND yearly <> 1 ORDER BY end_time DESC LIMIT $limitoffset,1) AND hostname = '$mhost' AND status = 'SUCCEEDED' AND deleted_at IS NULL")
            eval "$deletecmd" | while read -r todelete; do
                log_info "Deleted backup $todelete"
                rm -Rf "$todelete"
                markdeleted=$($mysqlhistcommand "UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE bulocation = '$todelete' AND hostname = '$mhost' AND status = 'SUCCEEDED'")
            done
        else
            log_info "No backups to delete at this time."
        fi
    elif [ $log_status = "SUCCEEDED" ] && [ $butype != "Full" ]; then
        log_info "Not deleting any backups as this is not a full backup run."
    else
        log_info "Backup failed. No backups deleted at this time."
    fi
}

# Function to dump $backuphistschema schema
function mdbutil_backup {
    if [ $backuphistschema != "" ] &&  [ $log_status = "SUCCEEDED" ]; then
        mysqldumpcreate
        mdbutildumpfile="$backupdir"/"$backuphistschema".backup_history-"$dirdate".sql
        $mysqldumpcommand > "$mdbutildumpfile" 2>&1 |grep -v "A partial dump from a server that has GTIDs will by default include the GTIDs "
        log_info "Backup history table dumped to $mdbutildumpfile"
    fi
}

# Function to cleanup mdbutil backups
function mdbutil_backup_cleanup {
    if [ $log_status = "SUCCEEDED" ]; then
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

# Function to check config parameters
function config_check {
    if [[ "$bktype" = "archive" || "$bktype" = "prepared-archive" ]] && [ "$compress" = "yes" ] ; then
        log_info "Archive backup type selected, disabling built-in compression."
        compress="no"
    fi
    if [[ "$computil" != "gzip" && "$computil" != "pigz"* ]] && [ "$bktype" = "archive" ]; then
        log_error "Fatal: $computil compression method is unsupported."
    fi

    if [ "$galera" = "yes" ]; then
        has_galera=$($mysqltargetcommand "SHOW GLOBAL VARIABLES LIKE 'wsrep_provider_options'" | grep 'wsrep_provider'|grep 'libgalera' | wc -l)
        if [ "$has_galera" -eq 0 ]; then
            log_info "Disabling galera flow control is enabled, but galera library is not loaded. Not disabling galera flow control."
            galera="error"
        fi
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
    log_info "bktype: " "$bktype"
    log_info "arctype: " "$arctype"
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
    log_info "queue: " "$queue"
    log_info "butype: " "$butype"
    log_info "log_status: " "$log_status"
    log_info "budirdate: " "$budirdate"
    log_info "innocommand: " "$innocommand"
    log_info "prepcommand: " "$prepcommand"
    log_info "dirname: " "$dirname"
    log_info "mhost: " "$mhost"
    log_info "budir: " "$budir"
    log_info "run_after_success: " "$run_after_success"
    log_info "run_after_fail: " "$run_after_fail"
}

############################################
# Begin script

# we trap control-c
trap sigint INT

scriptdir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# find and source the config file
etccnf=${1:-/etc/bgbackup.cnf}

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

if [ ! -d "$logpath" ]; then
    echo "Error: Log dir $logpath not found"
    exit 1
fi

if [ ! -w "$logpath" ]; then
    echo "Error: Log dir $logpath not writeable"
    exit 1
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

mysqlhistcreate

mysqltargetcreate

# Check that mysql client can connect
$mysqlhistcommand "SELECT 1 FROM DUAL" 1>/dev/null
if [ "$?" -eq 1 ]; then
  if [ "$debug" = yes ] ; then
    debugme
    log_info "$mysqlhistcommand"
  fi
  log_error "Error: mysql client is unable to connect with the information you have provided. Please check your configuration and try again."
fi

# Check that the database exists before continuing further
$mysqlhistcommand "USE $backuphistschema"
if [ "$?" -eq 1 ]; then
    log_error "Error: The database '$backuphistschema' containing the history does not exist. Please check your configuration and try again."
fi

check_table=$($mysqlhistcommand "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$backuphistschema' AND table_name='backup_history' ")
if [ "$check_table" -eq 0 ]; then
    create_history_table # Create history table if it doesn't exist
fi

need_migrate_table=$($mysqlhistcommand "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$backuphistschema' AND table_name='backup_history' AND column_name='weekly'")
if [ "$need_migrate_table" -eq 0 ]; then
    migrate_history_table # Migrate history table if it is old version
fi

mysqltargetcreate

config_check # Check vital configuration parameters

galera_check # Check if minimum nodes are available on Galera cluster

preflight_check # Run preflight check script to stop (for example) stop backup from running on primary nodes

backer_upper # Execute the backup.

backup_cleanup # Cleanup old backups.

endtime=$(date +"%Y-%m-%d %H:%M:%S")

backup_history

backup_write_config # Write configuration needed for restoring

mdbutil_backup

mdbutil_backup_cleanup

log_cleanup

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

exit
