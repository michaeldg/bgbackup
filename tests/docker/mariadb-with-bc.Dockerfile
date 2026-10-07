# Local test-only image: mariadb:10.11 plus `bc` and `qpress`.
#
# mariadb-backup is already bundled in the official mariadb:10.11 image, but
# two things it needs aren't:
#
#   - `bc`: bgbackup.sh's ceil()/max() helpers call it unconditionally at
#     startup (used to auto-bump keepweekly/keepdaily) regardless of config.
#   - `qpress`: mariadb-backup's (deprecated) --compress produces .qp files,
#     and both --compress and --decompress shell out to an external
#     `qpress` binary rather than handling QuickLZ in-process. Not in
#     Ubuntu 22.04's own repos -- fetched directly from Percona's apt pool
#     (same jammy build Percona ships qpress for, since upstream qpress.com
#     doesn't publish its own packages).
#
# Baked into a local image instead of installed per test run so every
# Docker-backed test starts a container in roughly the same time a plain
# `docker run` takes.
#
# Build once: docker build -f tests/docker/mariadb-with-bc.Dockerfile -t bgbackup-test-mariadb:local tests/docker
FROM mariadb:10.11
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends bc curl ca-certificates && \
    curl -sLo /tmp/qpress.deb https://repo.percona.com/tools/apt/pool/main/q/qpress/qpress_11-3.jammy_amd64.deb && \
    dpkg -i /tmp/qpress.deb && \
    rm -f /tmp/qpress.deb && \
    rm -rf /var/lib/apt/lists/*
