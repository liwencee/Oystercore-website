#!/usr/bin/env bash
# Package installation: Ubuntu packages (Nginx, ClamAV, rootless Podman, hardening tools)
# and MariaDB 11.4 from MariaDB's own apt repository, with a signed-by key whose
# fingerprint is pinned. There is no Node on the host: the apps run in containers.
# Sourced by bootstrap.sh. Needs lib/common.sh.
# shellcheck shell=bash

# The pinned fingerprint of MariaDB's repository signing key (primary key). It is checked
# against the downloaded key before the key is trusted. If MariaDB rotates its key, the
# bootstrap stops with a clear message and these lines are the only thing to review.
PKG_MARIADB_URL=https://mariadb.org/mariadb_release_signing_key.pgp
PKG_MARIADB_FPR=177F4010FE56CA3336300305F1656F24C74CD1D8
PKG_MARIADB_RING=/etc/apt/keyrings/oc-mariadb.gpg
PKG_MARIADB_REPO=https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/ubuntu

# What the server needs. Recommended packages are not installed: less to patch.
# The Podman group: podman and its OCI runtime (crun), uidmap for rootless user namespaces,
# slirp4netns for rootless outbound networking, netavark (with iptables) and aardvark-dns for the per-
# environment network and name lookup, catatonit as the container init, and
# dbus-user-session so each environment user gets a systemd user manager.
PKG_BASE=(
  ca-certificates curl gnupg openssl sudo tzdata logrotate iproute2 procps
  openssh-server ufw fail2ban python3-systemd unattended-upgrades auditd lynis
  nginx clamav-daemon clamav-freshclam systemd-timesyncd
  podman crun uidmap slirp4netns netavark aardvark-dns iptables catatonit dbus-user-session
)

# Docker has a daemon that runs as root, and its group is effectively root. The spec keeps
# it off the server (section 5). These are the packages and files that would mean it is there.
PKG_DOCKER_PACKAGES=(docker.io docker-ce docker-ce-cli docker-engine moby-engine containerd containerd.io)

# pkg_docker_found: prints what shows Docker is installed, one item per line.
pkg_docker_found() {
  local p
  for p in "${PKG_DOCKER_PACKAGES[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      printf 'package %s\n' "$p"
    fi
  done
  if oc_have dockerd; then
    printf 'program dockerd\n'
  fi
  if [[ -S /var/run/docker.sock || -S /run/docker.sock ]]; then
    printf 'socket /var/run/docker.sock\n'
  fi
}

pkg_apt() {
  # apt's output is shown only if it fails: dpkg is very chatty.
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l APT_LISTCHANGES_FRONTEND=none \
    oc_quiet apt-get -y -qq -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
    -o DPkg::Lock::Timeout=300 "$@"
}

# pkg_keyring_fpr FILE: the fingerprint of the primary key in FILE.
# A throwaway GnuPG home keeps the root user's own keyring out of it.
pkg_keyring_fpr() {
  # Runs inside $(...), so it cleans up after itself instead of using oc_mktemp_into.
  local file=$1 home out
  home=$(mktemp -d -t "oc.XXXXXX")
  out=$(GNUPGHOME=$home gpg --batch --quiet --show-keys --with-colons -- "$file" 2>/dev/null |
    awk -F: '/^pub:/ {want = 1; next} /^sub:/ {want = 0} want && /^fpr:/ {print $10; want = 0}') || true
  rm -rf -- "$home"
  printf '%s' "$out"
}

# pkg_install_keyring URL DEST FPR
# Downloads an armored key, insists it holds exactly one primary key with the pinned
# fingerprint, and stores it dearmored as DEST. Skipped when DEST already matches.
pkg_install_keyring() {
  local url=$1 dest=$2 fpr=$3 tmp bin home found
  if [[ -f $dest && $(pkg_keyring_fpr "$dest") == "$fpr" ]]; then
    return 0
  fi
  oc_mktemp_into tmp
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --max-time 60 --retry 3 -o "$tmp" -- "$url" || oc_die "could not download the signing key from $url"
  found=$(pkg_keyring_fpr "$tmp")
  [[ $found == "$fpr" ]] ||
    oc_die "the signing key from $url does not have the expected fingerprint (expected $fpr, got ${found:-none}). Not trusting it."
  oc_mktemp_into home "" -d
  oc_mktemp_into bin
  GNUPGHOME=$home gpg --batch --quiet --dearmor <"$tmp" >"$bin" || oc_die "could not convert the key from $url"
  oc_ensure_dir /etc/apt/keyrings 0755 root root
  oc_install_tmp "$bin" "$dest" 0644 root root
}

pkg_add_repositories() {
  pkg_install_keyring "$PKG_MARIADB_URL" "$PKG_MARIADB_RING" "$PKG_MARIADB_FPR"
  oc_install_stdin /etc/apt/sources.list.d/oc-mariadb.sources 0644 root root <<EOF
# Managed by infra/bootstrap.sh
Types: deb
URIs: $PKG_MARIADB_REPO
Suites: noble
Components: main
Signed-By: $PKG_MARIADB_RING
EOF
}

pkg_install_all() {
  local ver found
  found=$(pkg_docker_found)
  if [[ -n $found ]]; then
    oc_die "Docker is installed here ($(tr '\n' ',' <<<"$found" | sed 's/,$//')). The spec keeps Docker off this server: its daemon runs as root and its group is effectively root. Remove it first (for example: apt-get purge docker.io containerd), then rerun."
  fi
  oc_log "installing prerequisites"
  pkg_apt update
  pkg_apt install --no-install-recommends ca-certificates curl gnupg openssl
  pkg_add_repositories
  oc_log "refreshing package lists"
  pkg_apt update
  if ! oc_container_mode; then
    oc_log "applying pending updates"
    pkg_apt upgrade
  fi
  oc_log "installing server packages (this takes a few minutes the first time)"
  # MariaDB is pinned to the 11.4 series: if the repository is missing, apt fails here
  # instead of quietly installing Ubuntu's older 10.11.
  pkg_apt install --no-install-recommends "${PKG_BASE[@]}" 'mariadb-server=1:11.4.*'
  ver=$(podman --version 2>/dev/null | awk '{print $3}')
  [[ -n $ver ]] || oc_die "podman was not installed"
  oc_version_ge "$ver" "$OC_MIN_PODMAN" || oc_die "Podman $ver is older than $OC_MIN_PODMAN, which Quadlet needs"
  oc_log "Podman $ver, $(mariadbd --version 2>/dev/null | awk '{print $1, $3}'), $(nginx -v 2>&1)"
}
