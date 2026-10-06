# Local test-only image: mariadb:10.11 plus `bc`.
#
# mariadb-backup is already bundled in the official mariadb:10.11 image, but
# `bc` isn't, and bgbackup.sh's ceil()/max() helpers call it unconditionally
# at startup (used to auto-bump keepweekly/keepdaily) regardless of config.
# Baked into a local image instead of apt-get-installed per test run so
# every Docker-backed test starts a container in roughly the same time a
# plain `docker run` takes.
#
# Build once: docker build -f tests/docker/mariadb-with-bc.Dockerfile -t bgbackup-test-mariadb:local tests/docker
FROM mariadb:10.11
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends bc && rm -rf /var/lib/apt/lists/*
