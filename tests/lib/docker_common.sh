#!/bin/bash
#
# docker_common.sh
#
# Shared helpers for the live-Docker bgbackup.sh test suite. Sourced (not
# executed) by tests/test_docker_*.sh. Plain bash, no test framework --
# matches the style of tests/test_expand_hour_spec.sh and
# tests/test_daily_sequence_absent.sh, just factored out because the
# Docker-backed tests all need the same container lifecycle boilerplate
# (start a server, wait for it, mount the repo in read-only, bind-mount a
# host-visible scratch dir for backups/logs/config so the test can inspect
# files directly, tear everything down even on failure).
#
# A real backup tool (mariadb-backup / xtrabackup) needs local filesystem
# access to the server's datadir -- it isn't a pure network protocol -- so
# bgbackup.sh and the server it backs up always run inside the SAME
# container. Every helper here assumes that.

set -u

TDC_REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TDC_ROOT_PW="rootpass123"

# One row per flavor: docker image, the env var that image's entrypoint
# reads to set the root password, and the unix socket path that flavor's
# entrypoint configures by default. Both are small local images built by
# the Dockerfiles in tests/docker/ -- see those files for why each was
# necessary (mariadb:10.11 is missing `bc`, which bgbackup.sh calls
# unconditionally; percona/percona-server:8.0 doesn't ship xtrabackup at
# all and the package manager can't resolve its declared dependencies).
# Build both once before running these tests:
#   docker build -f tests/docker/mariadb-with-bc.Dockerfile -t bgbackup-test-mariadb:local tests/docker
#   docker build -f tests/docker/percona-with-xtrabackup.Dockerfile -t bgbackup-test-percona-xtrabackup:local tests/docker
tdc_image_for() {
    case "$1" in
        mariadb) echo "bgbackup-test-mariadb:local" ;;
        percona) echo "bgbackup-test-percona-xtrabackup:local" ;;
        *) echo "unknown flavor: $1" >&2; return 1 ;;
    esac
}

tdc_root_env_for() {
    case "$1" in
        mariadb) echo "MARIADB_ROOT_PASSWORD" ;;
        percona) echo "MYSQL_ROOT_PASSWORD" ;;
        *) echo "unknown flavor: $1" >&2; return 1 ;;
    esac
}

tdc_socket_for() {
    case "$1" in
        mariadb) echo "/run/mysqld/mysqld.sock" ;;
        percona) echo "/var/lib/mysql/mysql.sock" ;;
        *) echo "unknown flavor: $1" >&2; return 1 ;;
    esac
}

# backuptool= value bgbackup.cnf uses to select the tool for this flavor
# (1 = MariaDB Backup, 2 = XtraBackup -- see bgbackup.cnf.dist).
tdc_backuptool_for() {
    case "$1" in
        mariadb) echo "1" ;;
        percona) echo "2" ;;
        *) echo "unknown flavor: $1" >&2; return 1 ;;
    esac
}

# Builds the local test image for $1 if it isn't present yet, so a test
# file is runnable on a clean checkout without a separate manual build
# step. A no-op (fast `docker image inspect`) once the image exists.
tdc_ensure_image() {
    local flavor="$1" image dockerfile
    image=$(tdc_image_for "$flavor") || return 1
    docker image inspect "$image" >/dev/null 2>&1 && return 0

    case "$flavor" in
        mariadb) dockerfile="$TDC_REPO_ROOT/tests/docker/mariadb-with-bc.Dockerfile" ;;
        percona) dockerfile="$TDC_REPO_ROOT/tests/docker/percona-with-xtrabackup.Dockerfile" ;;
        *) echo "unknown flavor: $1" >&2; return 1 ;;
    esac
    echo "Building local test image $image (first run only)..." >&2
    docker build -f "$dockerfile" -t "$image" "$TDC_REPO_ROOT/tests/docker" >&2
}

# Starts a flavor's container named $2, bind-mounting a fresh host scratch
# dir (echoed on stdout) at /work and this repo read-only at /opt/bgbackup.
tdc_start() {
    local flavor="$1" name="$2"
    local image rootenv workdir
    image=$(tdc_image_for "$flavor") || return 1
    rootenv=$(tdc_root_env_for "$flavor") || return 1
    tdc_ensure_image "$flavor" || return 1
    workdir=$(mktemp -d /tmp/bgbackup_test.XXXXXX)

    docker run -d --name "$name" \
        -e "${rootenv}=${TDC_ROOT_PW}" \
        -v "$workdir:/work" \
        -v "$TDC_REPO_ROOT:/opt/bgbackup:ro" \
        "$image" >/dev/null

    echo "$workdir"
}

# Blocks until the server inside $1 answers a query, up to $2 seconds
# (default 60). Returns non-zero on timeout.
tdc_wait_ready() {
    local name="$1" timeout="${2:-60}" i
    for ((i = 0; i < timeout; i++)); do
        docker exec "$name" mysql -uroot -p"$TDC_ROOT_PW" -e "SELECT 1" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# Runs bgbackup.sh inside container $1 against config $2 (a path inside the
# container, typically /work/something.cnf). Extra args are passed through
# (e.g. -v, -f). Always run as root: the backup tool needs to read the
# datadir regardless of which unix user owns it, and bgbackup.sh's own
# writability checks on backupdir/logpath are moot for root.
tdc_run_bgbackup() {
    local name="$1" cnf="$2"
    shift 2
    docker exec -u root "$name" /opt/bgbackup/bgbackup.sh -c "$cnf" "$@"
}

# Runs a SQL statement inside container $1 as root and prints tab-separated
# rows (mysql -Bse style, no header).
tdc_sql() {
    local name="$1" query="$2"
    docker exec "$name" mysql -uroot -p"$TDC_ROOT_PW" -Bse "$query"
}

# Removes contents of /work as root (so host-owned-by-root files inside the
# bind mount can actually be unlinked), then removes the container, then
# removes the now-empty host scratch dir. Safe to call multiple times and
# safe to call when the container never started.
tdc_cleanup() {
    local name="$1" workdir="$2"
    if docker inspect "$name" >/dev/null 2>&1; then
        docker exec -u root "$name" sh -c 'rm -rf /work/* /work/.[!.]* 2>/dev/null' >/dev/null 2>&1
        docker rm -f "$name" >/dev/null 2>&1
    fi
    [ -n "${workdir:-}" ] && rm -rf "$workdir" 2>/dev/null
    return 0
}

# Extracts one function's source out of bgbackup.sh by name, the same way
# tests/test_expand_hour_spec.sh does it, so a test exercises the exact
# function currently shipped instead of a hand-copied drift-prone copy.
# Only safe for functions that end with a line containing exactly "}" at
# column 0 (true of every function in bgbackup.sh at the time of writing).
tdc_extract_function() {
    local func_name="$1" bgbackup_sh="$2"
    awk -v fn="$func_name" '
        $0 ~ "^function " fn "[[:space:]]*\\{" { found = 1 }
        found { print; if ($0 == "}") exit }
    ' "$bgbackup_sh"
}
