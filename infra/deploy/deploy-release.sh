#!/bin/bash
# deploy-release ENV                  (SHA CMS-IMAGE-ID WEB-IMAGE-ID in $SSH_ORIGINAL_COMMAND; tarball on stdin)
#
# The SSH forced command of the deploy account (oc-deploy). There is one deploy key PER
# ENVIRONMENT, and each key's line in the root-owned authorized_keys file fixes the environment:
#
#     command="/usr/local/lib/oc/deploy/deploy-release prod",restrict ssh-ed25519 AAAA... oc-deploy-prod
#     command="/usr/local/lib/oc/deploy/deploy-release staging",restrict ssh-ed25519 AAAA... oc-deploy-staging
#
# So whatever the client asks for, this program runs instead, with the environment as its one
# argument; a staging key can never deploy production, and a client cannot name an environment.
# The client's own command line arrives in $SSH_ORIGINAL_COMMAND (sshd passes it no other way).
# CI asks for exactly
#
#     0123...(40 hex) sha256:...(64 hex) sha256:...(64 hex)
#
# (the commit, the CMS image id and the web image id) and sends the gzip tarball of the two images
# (docker save) on standard input. A word naming an environment there, or any other number of
# words, is refused: exit 2, nothing else happens.
#
# This program runs as the unprivileged deploy user. It checks the values strictly, takes a lock so
# two uploads cannot overlap (exit 4), copies standard input into the one spool file, capped in size
# (exit 5), and then hands over to the root-owned apply-release.sh through the one sudo rule the
# deploy user has. Whatever apply-release.sh exits with is this program's exit status. The spool
# file is deleted afterwards in every case.
#
# It reads, writes and runs nothing else: the spool directory is the only place the deploy user
# can write (a folder root created for it). The environment, secrets and apps are out of reach.
#
# Test overrides (a client cannot set them: sshd passes only LANG and LC_* from the client):
#   OC_ROOT, OC_SUDO, OC_APPLY_RELEASE, OC_MAX_TARBALL_BYTES
# shellcheck shell=bash
set -Eeuo pipefail
export LC_ALL=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
unset BASH_ENV ENV CDPATH
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

# Exactly the shape CI sends after the environment; the same patterns as apply-release.sh.
RE_REST='^[0-9a-f]{40} sha256:[0-9a-f]{64} sha256:[0-9a-f]{64}$'
RE_ENV='^(prod|staging)$'
RE_SHA='^[0-9a-f]{40}$'
RE_ID='^sha256:[0-9a-f]{64}$'
DEFAULT_MAX_TARBALL_BYTES=2147483648

say() { printf '[oc-deploy] %s\n' "$*" >&2 || true; }
die() {
  local code=$1
  shift
  say "ERROR: $*"
  exit "$code"
}

HAVE_LOCK=0
SPOOL_FILE=""
PART_FILE=""

# shellcheck disable=SC2317  # run by the EXIT trap
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  if [[ $HAVE_LOCK == 1 ]]; then
    rm -f -- "$PART_FILE" "$SPOOL_FILE" 2>/dev/null
  fi
  exit "$rc"
}

main() {
  local root=${OC_ROOT:-} sudo_bin=${OC_SUDO:-/usr/bin/sudo}
  local apply=${OC_APPLY_RELEASE:-/usr/local/lib/oc/deploy/apply-release.sh}
  local max=$DEFAULT_MAX_TARBALL_BYTES conf line size rc=0
  local env_name sha cms_id web_id
  local -a words=()

  # --- the environment: the one argument the forced command of the key line gives (the key fixes
  # it; nothing the client sends can change it). Then the three values the client sends.
  [[ $# -eq 1 ]] || die 2 "this program is started by the forced command of a deploy key, with the environment as its one argument"
  [[ $1 =~ $RE_ENV ]] || die 2 "the environment must be exactly prod or staging"
  env_name=$1
  [[ -n ${SSH_ORIGINAL_COMMAND:-} ]] || die 2 "no command given. This account only runs deploys: ssh ... 'SHA CMS-IMAGE-ID WEB-IMAGE-ID' < images.tar.gz"
  [[ $SSH_ORIGINAL_COMMAND =~ $RE_REST ]] || die 2 "the command must be exactly: SHA CMS-IMAGE-ID WEB-IMAGE-ID (the environment is fixed by the key, and is not part of the command)"
  IFS=' ' read -r -a words <<<"$SSH_ORIGINAL_COMMAND"
  [[ ${#words[@]} -eq 3 ]] || die 2 "expected three values"
  [[ ${words[0]} =~ $RE_SHA ]] || die 2 "the commit must be exactly 40 lower-case hex characters"
  [[ ${words[1]} =~ $RE_ID ]] || die 2 "the CMS image id must be sha256: and 64 lower-case hex characters"
  [[ ${words[2]} =~ $RE_ID ]] || die 2 "the web image id must be sha256: and 64 lower-case hex characters"
  sha=${words[0]}
  cms_id=${words[1]}
  web_id=${words[2]}

  # --- the size limit: the same file apply-release.sh reads
  conf=$SCRIPT_DIR/limits.conf
  if [[ -f $conf && ! -L $conf ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ ^MAX_TARBALL_BYTES=([0-9]{1,13})$ ]]; then
        max=${BASH_REMATCH[1]}
      fi
    done <"$conf"
  fi
  [[ ${OC_MAX_TARBALL_BYTES:-} =~ ^[0-9]{1,13}$ ]] && max=$OC_MAX_TARBALL_BYTES

  local spool_dir=$root/var/lib/oc-deploy/spool
  [[ -d $spool_dir && ! -L $spool_dir ]] || die 5 "the spool directory $spool_dir is missing or is a symbolic link"
  SPOOL_FILE=$spool_dir/incoming.tar.gz
  PART_FILE=$spool_dir/incoming.tar.gz.part

  # --- one upload at a time. The lock stays held until this program exits, which is after
  # apply-release.sh has finished with the spool file.
  trap cleanup EXIT
  exec 8>>"$spool_dir/.lock"
  flock -n 8 || die 4 "another deploy is already running; nothing was changed"
  HAVE_LOCK=1
  # A dropped connection must not stop us halfway through a deploy.
  trap '' HUP PIPE
  trap 'exit 143' TERM
  trap 'exit 130' INT

  # --- standard input into the spool file: at most one byte more than the limit is read, so
  # an endless stream cannot fill the disk, and a file over the limit is detected.
  rm -f -- "$PART_FILE" "$SPOOL_FILE"
  head -c "$((max + 1))" >"$PART_FILE"
  size=$(stat -c %s -- "$PART_FILE")
  [[ $size -gt 0 ]] || die 5 "no tarball arrived on standard input"
  [[ $size -le $max ]] || die 5 "the tarball is too large (more than $max bytes)"
  mv -f -- "$PART_FILE" "$SPOOL_FILE"
  say "received $size bytes for $env_name $sha"

  # --- hand over to root, through the one sudo rule. Nothing is passed but the four checked
  # values; standard input is closed so nothing reads it by accident.
  "$sudo_bin" -n -- "$apply" "$env_name" "$sha" "$cms_id" "$web_id" </dev/null || rc=$?
  exit "$rc"
}

main "$@"
