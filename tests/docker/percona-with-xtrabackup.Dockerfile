# Local test-only image: Percona Server 8.0 with a working `xtrabackup` binary.
#
# percona/percona-server:8.0 does not ship xtrabackup, and installing the
# percona-xtrabackup-80 RPM via microdnf fails because its declared
# dependency libev.so.4 is not resolvable from any repo enabled in that
# image (EPEL 9 only ships libev-source/libev-libevent-devel for x86_64, not
# a prebuilt libev runtime package; the UBI CodeReady-Builder repo doesn't
# carry it either).
#
# The official percona/percona-xtrabackup:8.0 image *does* have a working
# xtrabackup binary, and `ldd` on it shows no actual runtime dependency on
# libev at all -- the RPM-level dependency appears to be for a helper
# (e.g. xbcloud) we don't need here. So instead of fighting the package
# manager, this just copies the working binary plus the one shared library
# percona-server:8.0 doesn't already carry (a private, versioned
# libprotobuf-lite bundled next to xtrabackup) out of that image.
#
# xtrabackup's own --decrypt/--decompress modes (used by the restore-side
# round-trip checks in the encryption/compression tests) shell out to the
# external `xbcrypt` and `zstd` binaries rather than handling either
# in-process, so both need to be present too: xbcrypt is copied from the
# same xtrabackup image for the same reason as the binary itself, and zstd
# installs cleanly from the UBI base repo (unlike percona-xtrabackup-80,
# it has no unresolvable dependency).
#
# Build once: docker build -f tests/docker/percona-with-xtrabackup.Dockerfile -t bgbackup-test-percona-xtrabackup:local tests/docker
FROM percona/percona-xtrabackup:8.0 AS xtrabackup

FROM percona/percona-server:8.0
USER root
COPY --from=xtrabackup /usr/bin/xtrabackup /usr/bin/xtrabackup
COPY --from=xtrabackup /usr/bin/xbcrypt /usr/bin/xbcrypt
COPY --from=xtrabackup /usr/lib/private/libprotobuf-lite.so.3.19.4 /usr/lib/private/libprotobuf-lite.so.3.19.4
RUN ldconfig && \
    microdnf install -y bc zstd >/dev/null 2>&1 && \
    microdnf clean all >/dev/null 2>&1
USER mysql
