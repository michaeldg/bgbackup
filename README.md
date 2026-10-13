# bgbackup : mdbutil-tracker

bgbackup is a MySQL ecosystem wrapper script for setting up a daily database backup routine. It can be configured to run different types of backups, and send a status email upon completion.

bgbackup works with MariaDB, Percona, MySQL, Galera Cluster, WebscaleSQL, etc.

The backups are done with xtrabackup/innobackupex or mariabackup. bgbackup supports multiple backup types, such as:

 * Standalone directories, with optional compression (qpress) and encryption (xbcrypt - xtrabackup/innobackupex only).
 
 * Compressed tar archives with gzip and pigz (parallel gzip) support. bgbackup may support multiple compressors in future. 
 
 * Optional "prepared" stage for tar archives where logs are applied before compression.
 
 * Optional partial backup on specific database names.

> With MariaDB v10.2.19 or higher, MariaDB backup may be preferred over xtrabackup/innobackupex due to compatibility issues: https://mariadb.com/kb/en/library/percona-xtrabackup/
 
## Main features
 
### Scheduling

Set `fullbackday` to the day you would like full backups taken. The first backup of `fullbackday` will be full backups. All subsequent backups (including backups taken later the same day) will be incremental or differential based on the setting `differential`. 

### Incremental or Differential

Incremental backups contain only the changed data since the last successful full or incremental backup. While the size of each incremental is smaller than a differential, the time to restore is longer. Each incremental needs to be applied in reverse order to the previous incremental until reaching the full backup. 

Differential backups contain the changed data since the last successful full backup. The size of the differentials grow, but the time to restore is less than incrementals. Only the last successful differential needs applied to the last successful full backup. 

Incremental backups are performed by default. To enable differential backups, set `differential=yes`.  

### Automatic upgrade to Full when a Differential would grow too large

Since a Differential is cumulative since the last Full (not since the last Differential), a one-off event that touches a large chunk of the database -- a migration, for example -- makes every Differential taken for the rest of the cycle bigger, not just the one that first captured it. To guard against that, bgbackup projects the size of this cycle's remaining Differentials (previous differential's size x differentials still expected before the next scheduled Full, this run included) before taking one; if that projection exceeds `diffupgradepct` (default `150`, i.e. 150% of the Full's own size), it takes a Full instead and logs a warning explaining why.

This only applies with `differential=yes`; incremental mode is unaffected. It's reactive with a one-run lag -- it can't know how big *today's* Differential will be until it's taken, so the Differential that first captures a size spike will still come out oversized. What it prevents is every subsequent day compounding further on top of an already-bloated chain.

### Automatic upgrade to Full when the server or backup tool version has changed

A Differential is only meaningful applied on top of the exact Full it was taken against. If the MySQL/MariaDB server or the xtrabackup/mariabackup tool has been upgraded (or downgraded) since the last Full backup, bgbackup takes a Full instead of a Differential this run and logs why, rather than chaining a Differential from a new version onto a Full from an old one.

This only applies with `differential=yes`. Both the server version (`mysqld -V`) and the backup tool version are compared against what was recorded for the last successful Full; either one differing is enough to trigger the upgrade.

### Emails

Details about all backups are emailed to all email addresses listed in MAILLIST if `mailonsuccess` is enabled. Otherwise, only details about failed backups are emailed. 

### Logging

In addition to logging to a log file, output can also be logged to syslog. 

### Backup History

Details about each backup are logged in the database (`backuphistschema`.backup_history) for easier monitoring in MONyog, Nagios, Cacti, etc. This table is also used by innobackupex to find the backup base directory for incremental and differential backups and for cleanup of old backups.

### Encryption

xbcrypt encryption (AES256) is supported for the directory backup type with xtrabackup; MariaDB Backup cannot encrypt.

`cryptkey` is the path of the file holding the key, which xtrabackup reads with `--encrypt-key-file`, so the key never appears on a command line, in the log or in the backup history. The file must hold exactly 32 bytes, without a trailing newline, and be readable by root only (see "Continue setup" below). With `encrypt=yes`, bgbackup refuses to start, before logging anything, when `cryptkey` is not the path of a readable 32-byte file; the error message does not show the value, in case it is a key.

Each backup records the fingerprint of its key, not the key or the key file's path: `cryptkey_fingerprint=` in the backup's own `bgbackup.cnf`, and the `cryptkey` column of `backup_history` (NULL when the backup is not encrypted). The fingerprint is the first 16 hex digits of the SHA-256 of the label `bgbackup key fingerprint v1`, a NUL byte and the key file's bytes:
```
{ printf 'bgbackup key fingerprint v1\0'; cat /etc/my.cnf.d/backupscript.key; } | sha256sum | cut -c1-16
```
On the host that restores, this tells which key file a backup needs when several keys are in use; the restore tool fgrestore prints it with `-F <key file>...`. The label keeps the fingerprint from being the key file's plain checksum, and 16 hex digits (64 bits) tell keys apart while revealing less. Like any fingerprint, it only protects a key that is random: generate keys as shown below, never pick one by hand.

Keep a copy of the key away from the database hosts. Without it, no encrypted backup can be restored.

### Compression

bgbackup supports two different compression modes:

 * qpress for standalone directory backup types. Each file is compressed individually.

 * gzip and pigz (parallel gzip) for tar archive backup types. Additional support for other compressors will be added in the future.

### Galera

If Galera option is set to yes, the script will enable wsrep_desync on the node being backed up. When the backup is finished, it will check for wsrep_local_recv_queue to return to zero before disabling wsrep_desync. 

### MONYog support

Option to disable MONyog alerts before, and enable after. 

### Run external commands after backup

Optionally set external commands to be run after successful or failed backup, respectively.

## Important upgrade notes

If a prior version which used innobackupex's --history option was used, there is a checkmigrate option in the config to migrate those records to the new table.

**Encryption key in a file.** Earlier versions passed `cryptkey` to xtrabackup as the key itself (`--encrypt-key=`), although this README and `bgbackup.cnf.dist` described it as the path of a key file. With `encrypt=yes`, a configuration that holds the key itself in `cryptkey` now makes bgbackup refuse to start. Such a key has been exposed: it was on the command line of every backup, in every log (the redaction of the log copy stored with each backup never worked), in the `cryptkey` column of `backup_history` and in the history dumps bgbackup writes next to the backups. Rotate it:

1. Save the old key in a file, to restore the backups taken with it (the same key read from a file decrypts them), and keep it only as long as those backups are kept:
   ```
   (umask 077; . /etc/bgbackup.cnf; printf '%s' "$cryptkey" > /etc/my.cnf.d/backupscript-old.key)
   ```
2. Create a new key file (see "Continue setup" below), point `cryptkey` at it, and take a Full backup right away (`bgbackup.sh -f`), so no Differential or Incremental is based on a backup encrypted with the old key.
3. Clear the old values from `backup_history` (fingerprints, 16 hex digits, are kept), and delete the old logs and the `<backuphistschema>.backup_history-*.sql` dumps in `backupdir` that hold the old key:
   ```
   UPDATE mdbutil.backup_history SET cryptkey = NULL WHERE cryptkey IS NOT NULL AND cryptkey NOT REGEXP '^[0-9a-f]{16}$';
   ```

## Setup instructions

**Using xtrabackup/innobackupex**

Install xtrabackup, qpress, mailx as needed: <br />
```
Yum example:
yum install http://www.percona.com/downloads/percona-release/redhat/0.1-4/percona-release-0.1-4.noarch.rpm
yum install percona-xtrabackup
yum install mailx
yum install qpress
```

**Using mariabackup**

Install mariabackup, qpress, mailx as needed: <br />
```
Yum example:
echo <<EOF > /etc/yum.repos.d/mariadb.repo
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.2/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF
yum install MariaDB-backup
yum install mailx
yum install qpress
```

**Continue setup**

If you encrypt backups (xtrabackup only), create the encryption key file: 32 random bytes, no trailing newline, readable by root only: <br />
```
(umask 077; openssl rand -base64 24 | tr -d '\n' > /etc/my.cnf.d/backupscript.key)
```

Create the MDB Utilities schema/database (replace backuphistschema with the value of `backuphistschema`): <br />
```
CREATE DATABASE mdbutil;
```

Create the backup user (change backupuser to the value of `backupuser`, backuppass to the value of `backuppass`, and backuphistschema to the value of `mdbutil`): <br />
```
GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO 'backupuser'@'localhost' IDENTIFIED BY 'backuppass';
GRANT ALL PRIVILEGES ON mdbutil.* TO 'backupuser'@'localhost';
FLUSH PRIVILEGES; 
```

If backing up Galera, SUPER is also needed to enable/disable wsrep_desync. 

```
GRANT SUPER ON *.* TO 'backupuser'@'localhost';
```

Add this info to bottom of /etc/my.cnf (MySQL) or new /etc/my.cnf.d/xtrabackup.cnf (MariaDB) (change the paths to your paths): <br />
```
[xtrabackup]
port = 3306
socket = /path/to/socket
datadir = /path/to/datadir
innodb_data_home_dir = /path/to/innodb_data_home_dir
```

> Change to `[mariabackup]` when using mariabackup.

Lock down permissions on config file(s) (changing the paths as necessary): <br />
```
chown mysql /etc/my.cnf
chmod 400 /etc/my.cnf

chown mysql /etc/my.cnf.d/xtrabackup.cnf
chmod 400 /etc/my.cnf.d/xtrabackup.cnf

chown root:root /etc/my.cnf.d/backupscript.key
chmod 600 /etc/my.cnf.d/backupscript.key

chown mysql /etc/bgbackup.cnf
chmod 400 /etc/bgbackup.cnf
```

