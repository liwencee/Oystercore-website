# Test image for infra/bootstrap.sh and infra/verify.sh.
#
# Plain Ubuntu 24.04 with no systemd running as init: there is no kernel to configure and
# no service manager, so the bootstrap runs with OC_CONTAINER=1 (it writes every file and
# skips what needs those) and the verifier with VERIFY_CONTAINER=1.
#
# Only the tools the test harness itself needs are installed here. Everything the server
# needs (MariaDB, Nginx, ClamAV, Podman, ...) is installed by the bootstrap, so the package
# step is tested too, and Podman's own Quadlet generator checks the container files.
# `systemd` is here only for `systemd-analyze verify`; `python3-minimal` only runs the
# small fake backends of the Nginx test (the real apps are containers).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg openssl iproute2 openssh-client shellcheck systemd python3-minimal \
    && rm -rf /var/lib/apt/lists/*

# The build context is infra/ (see infra/test/run.sh).
COPY . /opt/oc-infra
WORKDIR /opt/oc-infra
