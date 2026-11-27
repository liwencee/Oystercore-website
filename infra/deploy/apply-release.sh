#!/bin/bash
# apply-release.sh ENV SHA CMS-IMAGE-ID WEB-IMAGE-ID
#
# The only thing the deploy account may run as root. Installed root-owned and not writable by
# anyone else (/usr/local/lib/oc/deploy/apply-release.sh), reached through one sudoers entry
# (see infra/lib/users.sh). deploy-release.sh calls it after spooling the tarball; nobody else
# has a reason to.
#
# It NEVER trusts its caller. It checks every argument again with the same strict patterns,
# takes the tarball from one fixed file in a directory of its own, refuses anything that is
# not a regular file owned by the deploy user, caps the size, and holds an exclusive lock so
# two deploys can never overlap. It touches the environment's files and Podman only AS the
# environment's own user (runuser), never as root, so a link planted in that user's home
# cannot make root write somewhere else.
#
# What it does, in order:
#   1. checks the arguments, takes the lock, and checks the spool file (exit 2, 4, 5);
#   2. reads the two Quadlet files' current Image= lines (exit 7 if they are not as the
#      bootstrap wrote them);
#   3. loads the tarball with Podman, as the environment's user (exit 6 if it cannot be loaded);
#      The spool file is opened by a small helper with O_NOFOLLOW and O_NONBLOCK (a link, or a
#      named pipe put there in the meantime, is refused, not followed or waited for), and the
#      unpacking (gzip) runs as the environment's user too;
#   4. checks that the image ids Podman now holds are the ids CI sent, and that the tarball
#      brought in nothing else (no other name, and no image without a name either); if not, it
#      undoes the load and stops (exit 3, nothing changed);
#   5. rewrites ONLY the Image= line of oc-cms-<env>.container and oc-web-<env>.container,
#      regenerates the units (daemon-reload) and restarts both services;
#   6. waits up to 60 s for the CMS /_health and the web /healthz on localhost, and for the
#      RUNNING containers to be made from the new images (a service that answers is not enough:
#      the old container could still be the one answering);
#   7. on any failure after step 5 it puts the previous Image= lines back and restarts those
#      (or, if there is no previous release to go back to, or the two Image= lines cannot both be
#      put back, stops both services: a mixed pair is never started) and exits 1;
#   8. on success it keeps the 3 newest release tags of each image and removes older ones.
#
# Exit status: 0 done, 1 health check failed (rolled back) or another error after the change,
# 2 bad arguments, 3 image ids do not match or the tarball held other images (nothing
# changed), 4 another deploy is running, 5 spool file refused, 6 tarball could not be loaded,
# 7 the server is not set up as expected (the Quadlet files are not as the bootstrap wrote them, or
# the environment's user does not exist). 2, 3, 4, 5, 6 and 7 leave the server as it was.
#
# Test overrides (ignored whenever sudo started the script, so a caller cannot use them):
#   OC_ROOT           prefix for every path (a fake tree)
#   OC_PODMAN, OC_SYSTEMCTL, OC_CURL, OC_RUNUSER, OC_GZIP, OC_PERL   the programs to run instead of the real ones
#   OC_DEPLOY_USER    the user that must own the spool file (default oc-deploy)
#   OC_ENV_UID        the environment user's numeric id (default: looked up)
#   OC_HEALTH_TIMEOUT, OC_HEALTH_INTERVAL   seconds (default 60 and 2)
#   OC_MAX_TARBALL_BYTES   size limit (default 2147483648, or limits.conf next to this script)
#
# Nothing here prints a secret: only tags, image ids and paths.
# shellcheck shell=bash

# Where this script lives (worked out now, before main changes directory).
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

RE_ENV='^(prod|staging)$'
RE_SHA='^[0-9a-f]{40}$'
RE_ID='^sha256:[0-9a-f]{64}$'
# What an Image= line of ours may hold (the same pattern as the verifier's CTR-01).
RE_REF='^localhost/oc-(cms|web)(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$'

SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEFAULT_MAX_TARBALL_BYTES=2147483648
KEEP_TAGS=3

# The localhost ports of the apps (spec section 5). A unit test compares these with
# infra/lib/common.sh so the two cannot drift apart.
release_port() { # APP ENV
  case $1:$2 in
    cms:prod) echo 1337 ;;
    cms:staging) echo 1338 ;;
    web:prod) echo 4321 ;;
    web:staging) echo 4322 ;;
    *) return 1 ;;
  esac
}

# --- messages and exits -----------------------------------------------------------------
say() {
  printf '[oc-deploy] %s\n' "$*" >&2 || true
  if [[ -z ${OC_ROOT:-} ]] && command -v logger >/dev/null 2>&1; then
    logger -t oc-apply-release -- "$*" >/dev/null 2>&1 || true
  fi
}
die() { # CODE MESSAGE...
  local code=$1
  shift
  say "ERROR: $*"
  exit "$code"
}

STATE=start # start -> loaded (the load may have added images) -> verified -> repointing (Quadlet files changed)
HAVE_LOCK=0
SPOOL_DIR_OK=0
SPOOL_ID=
declare -A BEFORE=()
declare -A BEFORE_IDS=()
EXPECT_CMS_ID=
EXPECT_WEB_ID=

# --- settings ---------------------------------------------------------------------------
setup() {
  if [[ -n ${SUDO_USER:-}${SUDO_UID:-}${SUDO_COMMAND:-} ]]; then
    unset OC_ROOT OC_PODMAN OC_SYSTEMCTL OC_CURL OC_RUNUSER OC_GZIP OC_PERL OC_DEPLOY_USER OC_ENV_UID \
      OC_HEALTH_TIMEOUT OC_HEALTH_INTERVAL OC_MAX_TARBALL_BYTES
  fi
  ROOT=${OC_ROOT:-}
  PODMAN=${OC_PODMAN:-/usr/bin/podman}
  SYSTEMCTL=${OC_SYSTEMCTL:-/usr/bin/systemctl}
  CURL=${OC_CURL:-/usr/bin/curl}
  RUNUSER=${OC_RUNUSER:-/usr/sbin/runuser}
  GZIP=${OC_GZIP:-/usr/bin/gzip}
  PERL=${OC_PERL:-/usr/bin/perl}
  DEPLOY_USER=${OC_DEPLOY_USER:-oc-deploy}
  HEALTH_TIMEOUT=60
  [[ ${OC_HEALTH_TIMEOUT:-} =~ ^[0-9]{1,4}$ ]] && HEALTH_TIMEOUT=$OC_HEALTH_TIMEOUT
  HEALTH_INTERVAL=2
  [[ ${OC_HEALTH_INTERVAL:-} =~ ^[0-9]+(\.[0-9]+)?$ ]] && HEALTH_INTERVAL=$OC_HEALTH_INTERVAL

  MAX_TARBALL=$DEFAULT_MAX_TARBALL_BYTES
  local conf line
  conf=$SCRIPT_DIR/limits.conf
  if [[ -f $conf && ! -L $conf ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ ^MAX_TARBALL_BYTES=([0-9]{1,13})$ ]]; then
        MAX_TARBALL=${BASH_REMATCH[1]}
      fi
    done <"$conf"
  fi
  [[ ${OC_MAX_TARBALL_BYTES:-} =~ ^[0-9]{1,13}$ ]] && MAX_TARBALL=$OC_MAX_TARBALL_BYTES
  # The tarball is gzip. Image layers (JavaScript, a Node binary) often shrink three to five
  # times, so the limit on what comes out is eight times the limit on what goes in (never
  # below 1 MiB). It stops a small file that expands without end from filling the disk.
  MAX_UNPACKED=$((MAX_TARBALL * 8))
  ((MAX_UNPACKED >= 1048576)) || MAX_UNPACKED=1048576

  SPOOL_DIR=$ROOT/var/lib/oc-deploy/spool
  SPOOL_FILE=$SPOOL_DIR/incoming.tar.gz
  LOCK_FILE=$ROOT/var/lib/oc-deploy/apply.lock
  ENV_HOME=$ROOT/home/oc-$ENV_NAME
  QDIR=$ENV_HOME/.config/containers/systemd
  CMS_PORT=$(release_port cms "$ENV_NAME")
  WEB_PORT=$(release_port web "$ENV_NAME")
  NEW_CMS=localhost/oc-cms:$SHA
  NEW_WEB=localhost/oc-web:$SHA
  if [[ -n ${OC_ENV_UID:-} ]]; then
    ENV_UID=$OC_ENV_UID
  else
    ENV_UID=$(id -u -- "oc-$ENV_NAME" 2>/dev/null) || die 7 "the user oc-$ENV_NAME does not exist (has the bootstrap run for $ENV_NAME?); nothing was changed"
  fi
  [[ $ENV_UID =~ ^[0-9]+$ ]] || die 7 "bad user id for oc-$ENV_NAME; nothing was changed"
}

# --- running things as the environment's user --------------------------------------------
# A clean environment of its own: nothing from the caller (not even sudo's variables) goes in, and
# no descriptor either. Descriptor 7 holds the deploy lock (a flock belongs to the open file, so
# every copy of the descriptor holds it): rootless Podman leaves a long-lived "pause" process
# behind, and one that inherited descriptor 7 would keep every later deploy out (exit 4) for as
# long as it lives. Every child therefore starts with 7 closed (7>&-). (The spool file used to be
# held on descriptor 9; it is opened by the helper below, so there is no 9 to close any more.)
env_run() { # PROGRAM ARGS...
  "$RUNUSER" -u "oc-$ENV_NAME" -- env -i "PATH=$SAFE_PATH" "LC_ALL=C" "HOME=$ENV_HOME" \
    "XDG_RUNTIME_DIR=/run/user/$ENV_UID" "$@" 7>&-
}
podman_run() { env_run "$PODMAN" "$@"; }
# A lingering user's own systemd manager, reached through its bus socket in /run/user/<uid>
# (the same way lib/containers.sh talks to it).
systemctl_user() { env_run "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ENV_UID/bus" "$SYSTEMCTL" --user "$@"; }
# File work on the environment's files, as that user.
as_env() { "$RUNUSER" -u "oc-$ENV_NAME" -- env -i "PATH=$SAFE_PATH" "LC_ALL=C" "$@" 7>&-; }

# --- the Quadlet files ------------------------------------------------------------------
qfile() { printf '%s/oc-%s-%s.container' "$QDIR" "$1" "$ENV_NAME"; }

# read_image APP: prints the Image= value of the file; exit 7 unless the file is as expected:
# a regular file, exactly one Image= line, no other spelling of Image (Quadlet accepts
# "Image = x", which the edit below would miss), and a local oc image of the right app.
read_image() {
  local app=$1 f out strict loose value
  f=$(qfile "$app")
  [[ -d $QDIR && ! -L $QDIR && -f $f && ! -L $f ]] || die 7 "$f is missing or is not a plain file"
  # shellcheck disable=SC2016  # an awk program: the $ signs are awk's, not the shell's
  out=$(as_env awk '
    /^Image=/ {strict++; value = substr($0, 7)}
    /^[ \t]*Image[ \t]*=/ {loose++}
    END {printf "%d %d %s\n", strict, loose, value}' "$f") || die 7 "could not read $f"
  read -r strict loose value <<<"$out"
  [[ $strict == 1 && $loose == 1 ]] || die 7 "$f must have exactly one line 'Image=...' (found $strict, and $loose in any spelling)"
  [[ $value =~ $RE_REF && $value == "localhost/oc-$app"[:@]* ]] || die 7 "the Image= line of $f is not a local oc-$app image"
  printf '%s' "$value"
}

# set_image APP REF: rewrite only the Image= line. sed -i, run as the file's own user, keeps
# the owner and mode and every other byte (also a missing newline at the end). REF is checked
# first, so it has nothing in it that sed would treat as syntax.
set_image() {
  local app=$1 ref=$2 f
  [[ $ref =~ $RE_REF && $ref == "localhost/oc-$app"[:@]* ]] || die 1 "refusing to write the image reference '$ref'"
  f=$(qfile "$app")
  as_env sed -i -e "0,/^Image=/s|^Image=.*\$|Image=$ref|" "$f"
}

# --- images -----------------------------------------------------------------------------
norm_id() { printf '%s' "${1#sha256:}"; }
# One line per tag: id|creation time|name. The id is bare hex. The creation time is Podman's
# {{.CreatedAt}}, "2026-03-23 21:33:59 +0000 UTC", which sorts as text (Podman 4.9 prints
# {{.Created}} as "8 months ago", so that field cannot be used).
list_images() { podman_run image ls --format '{{.Id}}|{{.CreatedAt}}|{{.Repository}}:{{.Tag}}'; }
# fill_names LISTING NAME-OF-ASSOC-ARRAY: the images by name, as "id" (bare hex).
fill_names() {
  local listing=$1 id created name
  local -n into=$2
  into=()
  while IFS='|' read -r id created name; do
    [[ -n $name && $name != *'<none>'* ]] || continue
    # shellcheck disable=SC2034,SC2004  # into is a nameref to the caller's array
    into[$name]=$(norm_id "$id")
  done <<<"$listing"
}

# fill_ids LISTING NAME-OF-ASSOC-ARRAY: every image id in the listing (bare hex), named or not.
fill_ids() {
  local listing=$1 id created name
  # shellcheck disable=SC2178  # into is a nameref to the caller's array
  local -n into=$2
  into=()
  while IFS='|' read -r id created name; do
    [[ -n $id ]] || continue
    # shellcheck disable=SC2034,SC2004  # into is a nameref to the caller's array
    into[$(norm_id "$id")]=1
  done <<<"$listing"
}

# Undo a load: remove every name that did not exist before, put back every name that the tarball
# moved to another image, and remove every image that has no name and was not here before (a
# tarball can bring those in too, and moving a name back leaves the image that held it without
# one). Safe to run at any point after BEFORE and BEFORE_IDS were filled.
undo_load() {
  local listing name oldid id created
  local -A now=()
  listing=$(list_images 2>/dev/null) || {
    say "WARNING: could not list images to undo the load"
    return 0
  }
  fill_names "$listing" now
  for name in "${!now[@]}"; do
    if [[ -z ${BEFORE[$name]+x} ]]; then
      podman_run rmi -- "$name" >/dev/null 2>&1 || say "WARNING: could not remove the image $name"
    elif [[ ${BEFORE[$name]} != "${now[$name]}" ]]; then
      oldid=${BEFORE[$name]}
      podman_run tag -- "$oldid" "$name" >/dev/null 2>&1 || say "WARNING: could not put $name back on its old image"
    fi
  done
  listing=$(list_images 2>/dev/null) || {
    say "WARNING: could not list images to remove the untagged ones the load added"
    return 0
  }
  while IFS='|' read -r id created name; do
    [[ -n $id && $name == *'<none>'* ]] || continue
    id=$(norm_id "$id")
    [[ -z ${BEFORE_IDS[$id]+x} ]] || continue
    podman_run rmi -- "$id" >/dev/null 2>&1 || say "WARNING: could not remove the untagged image $id"
  done <<<"$listing"
}

# --- health -----------------------------------------------------------------------------
# running_image APP: the id (bare hex) of the image the RUNNING container oc-<app>-<env> was made from.
# (podman container inspect --format {{.ImageID}}: the id, not the name; checked against Podman 4.9.3.)
running_image() {
  local id
  id=$(podman_run container inspect --format '{{.ImageID}}' "oc-$1-$ENV_NAME" 2>/dev/null) || return 1
  id=$(norm_id "${id%%$'\n'*}")
  [[ $id =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$id"
}
# images_current: each running container was made from the image the release says it should be (the
# ids in EXPECT_CMS_ID and EXPECT_WEB_ID; an empty one is not checked). A service that answers its
# health check could still be the OLD container, if the restart did not replace it.
images_current() {
  local app want got
  for app in cms web; do
    want=EXPECT_${app^^}_ID
    want=${!want}
    [[ -n $want ]] || continue
    got=$(running_image "$app") || return 1
    [[ $got == "$want" ]] || return 1
  done
}
health_once() {
  "$CURL" -fsS --noproxy '*' --max-time 3 -o /dev/null "http://127.0.0.1:$CMS_PORT/_health" >/dev/null 2>&1 &&
    "$CURL" -fsS --noproxy '*' --max-time 3 -o /dev/null "http://127.0.0.1:$WEB_PORT/healthz" >/dev/null 2>&1 &&
    systemctl_user is-active --quiet "oc-cms-$ENV_NAME.service" >/dev/null 2>&1 &&
    systemctl_user is-active --quiet "oc-web-$ENV_NAME.service" >/dev/null 2>&1 &&
    images_current
}
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) app got want
  while :; do
    health_once && return 0
    ((SECONDS >= deadline)) && break
    sleep "$HEALTH_INTERVAL"
  done
  # say why, if the services answered but the containers are not the ones expected
  for app in cms web; do
    want=EXPECT_${app^^}_ID
    [[ -n ${!want} ]] || continue
    got=$(running_image "$app") || got="(no running container)"
    [[ $got == "${!want}" ]] || say "the running oc-$app container is made from $got, not from the expected image ${!want}"
  done
  return 1
}

restart_both() {
  systemctl_user daemon-reload && systemctl_user restart "oc-cms-$ENV_NAME.service" "oc-web-$ENV_NAME.service"
}

# --- rollback ---------------------------------------------------------------------------
rollback() {
  local app cur prev_var restored=1
  say "the new release failed; rolling back"
  for app in cms web; do
    prev_var=PREV_${app^^}
    cur=$(read_image "$app" 2>/dev/null) || cur=""
    if [[ $cur != "${!prev_var}" ]]; then
      set_image "$app" "${!prev_var}" || say "WARNING: could not put the Image= line of oc-$app back"
      cur=$(read_image "$app" 2>/dev/null) || cur=""
      [[ $cur == "${!prev_var}" ]] || restored=0
    fi
  done
  systemctl_user daemon-reload || say "WARNING: daemon-reload failed during the rollback"
  if [[ $restored == 0 ]]; then
    # One file is back and the other is not: restarting would run the CMS of one release with the
    # website of another. Neither is started; both are stopped, and the owner is told.
    systemctl_user stop "oc-cms-$ENV_NAME.service" "oc-web-$ENV_NAME.service" ||
      say "WARNING: could not stop the services"
    say "WARNING: the two Image= lines could not both be put back, so the services are left stopped (never a mixed pair). Look at $(qfile cms) and $(qfile web), then restart them by hand."
  elif [[ $PREV_EXISTS == 1 ]]; then
    systemctl_user restart "oc-cms-$ENV_NAME.service" "oc-web-$ENV_NAME.service" ||
      say "WARNING: restarting the previous release failed"
    EXPECT_CMS_ID=$PREV_CMS_ID
    EXPECT_WEB_ID=$PREV_WEB_ID
    if wait_healthy; then
      say "rolled back: the previous release ($PREV_CMS, $PREV_WEB) is running and healthy again"
    else
      say "WARNING: rolled back to the previous release, but it is not healthy either; look at: journalctl --user -u oc-cms-$ENV_NAME as oc-$ENV_NAME"
    fi
  else
    systemctl_user stop "oc-cms-$ENV_NAME.service" "oc-web-$ENV_NAME.service" ||
      say "WARNING: could not stop the services"
    say "there is no previous release to go back to; the services are left stopped"
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  set +e
  case $STATE in
    loaded) undo_load ;;
    repointing) rollback ;;
    *) ;;
  esac
  # Remove the spool file, but only the very file this run looked at (same device and inode),
  # while the lock is ours and the directory is the real one: rm must never follow a link out
  # of the directory, and must never delete a newer upload.
  if [[ $HAVE_LOCK == 1 && $SPOOL_DIR_OK == 1 && -n $SPOOL_ID && ! -L $SPOOL_FILE ]] &&
    [[ $(stat -c '%d:%i' -- "$SPOOL_FILE" 2>/dev/null) == "$SPOOL_ID" ]]; then
    rm -f -- "$SPOOL_FILE" 2>/dev/null
  fi
  case $rc in
    0 | 2 | 3 | 4 | 5 | 6 | 7) ;;
    *) rc=1 ;;
  esac
  if [[ $STATE == repointing && $rc -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}

# --- the spool file ---------------------------------------------------------------------
# The spool file is a path in a folder the deploy user can write, so it can be swapped for something
# else at any moment. Bash cannot open a file with O_NOFOLLOW (a link is not followed) and O_NONBLOCK
# (a named pipe does not make open wait for ever), so a small perl program opens it: with both flags,
# and looks at what it opened (fstat on the descriptor it holds, so there is no gap between the look
# and the use). It runs twice: once to say what the file is, and once to stream it (at most MAX
# bytes) into the unpacking, where it opens the file again and refuses anything but the very file
# the first run described (same device and inode), a regular file owned by the deploy user.
# shellcheck disable=SC2016  # a perl program: the $ signs are perl's, not the shell's
SPOOL_PERL='
use strict; use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK :mode);
my ($mode, $path, $max, $want_id, $want_uid) = @ARGV;
sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or do { print STDERR "spool: cannot open $path safely: $!\n"; exit 20 };
my @st = stat($fh) or do { print STDERR "spool: cannot look at the open file: $!\n"; exit 21 };
my $id = "$st[0]:$st[1]";
if ($mode eq "facts") {
  printf "%s|%s|%d|%d|%d\n", $id, (S_ISREG($st[2]) ? "regular" : "other"), $st[4], $st[3], $st[7];
  exit 0;
}
if (!S_ISREG($st[2])) { print STDERR "spool: not a regular file\n"; exit 22 }
if ($id ne $want_id) { print STDERR "spool: the file was replaced after it was checked\n"; exit 23 }
if ($st[4] != $want_uid || $st[3] != 1) { print STDERR "spool: the owner or the number of links changed after the check\n"; exit 24 }
binmode(STDOUT);
my $left = $max;
while ($left > 0) {
  my $buf;
  my $n = sysread($fh, $buf, $left < 65536 ? $left : 65536);
  if (!defined $n) { print STDERR "spool: read failed: $!\n"; exit 25 }
  last if $n == 0;
  my $off = 0;
  while ($off < $n) {
    my $w = syswrite(STDOUT, $buf, $n - $off, $off);
    if (!defined $w) { print STDERR "spool: write failed: $!\n"; exit 26 }
    $off += $w;
  }
  $left -= $n;
}
exit 0;
'
# spool_perl MODE ARGS...: the helper, with descriptor 7 (the lock) closed like for every other child.
spool_perl() { "$PERL" -e "$SPOOL_PERL" -- "$@" 7>&-; }

# open_spool: refuse anything but a plain, single-link, non-empty regular file owned by the deploy
# user and not over the limit. SPOOL_ID, SPOOL_SIZE and SPOOL_UID are what the helper saw on the
# file it opened; the stream later insists on the same file.
open_spool() {
  local facts type owner links size want_uid
  [[ -d $SPOOL_DIR && ! -L $SPOOL_DIR ]] || die 5 "the spool directory $SPOOL_DIR is missing or is a symbolic link"
  SPOOL_DIR_OK=1
  [[ ! -L $SPOOL_FILE ]] || die 5 "the spool file is a symbolic link; refusing it"
  [[ -f $SPOOL_FILE ]] || die 5 "the spool file is missing or is not a regular file"
  facts=$(spool_perl facts "$SPOOL_FILE" 2>&1) || die 5 "the spool file cannot be opened safely (a link, or not a plain file): ${facts:0:200}"
  IFS='|' read -r SPOOL_ID type owner links size <<<"$facts"
  [[ $SPOOL_ID =~ ^[0-9]+:[0-9]+$ && $type =~ ^[a-z]+$ && $owner =~ ^[0-9]+$ && $links =~ ^[0-9]+$ && $size =~ ^[0-9]+$ ]] ||
    die 5 "cannot look at the spool file: ${facts:0:200}"
  [[ $type == regular ]] || die 5 "the spool file is not a regular file"
  want_uid=$(id -u -- "$DEPLOY_USER" 2>/dev/null) || die 5 "the deploy user $DEPLOY_USER does not exist"
  [[ $owner == "$want_uid" ]] || die 5 "the spool file is not owned by $DEPLOY_USER (owner id $owner)"
  [[ $links == 1 ]] || die 5 "the spool file has $links hard links; refusing it"
  [[ $size -gt 0 ]] || die 5 "the spool file is empty"
  [[ $size -le $MAX_TARBALL ]] || die 5 "the spool file is too large ($size bytes; the limit is $MAX_TARBALL)"
  SPOOL_SIZE=$size
  SPOOL_UID=$owner
}

# load_pipeline: the spool file, at most MAX_TARBALL bytes of it, unpacked (as the environment's user,
# at most MAX_UNPACKED bytes of output) into podman load (also as that user). No child holds the lock.
load_pipeline() {
  spool_perl stream "$SPOOL_FILE" "$MAX_TARBALL" "$SPOOL_ID" "$SPOOL_UID" |
    as_env "$GZIP" -dc |
    head -c "$MAX_UNPACKED" 7>&- |
    podman_run load
}

# quote_output: text that came out of a tool that read the tarball, made safe for a CI log: only
# printable ASCII (a carriage return or an escape cannot hide a line), at most 20 lines, and every line
# starts with a fixed prefix, so no line can begin with "::" (a GitHub Actions workflow command).
quote_output() {
  tr -c '[:print:]\n' '?' | head -n 20 | sed 's/^/[podman] /'
}

# --- the arguments ----------------------------------------------------------------------
check_args() {
  [[ $# -eq 4 ]] || die 2 "usage: apply-release.sh prod|staging SHA CMS-IMAGE-ID WEB-IMAGE-ID"
  [[ $1 =~ $RE_ENV ]] || die 2 "the environment must be exactly prod or staging"
  [[ $2 =~ $RE_SHA ]] || die 2 "the commit must be exactly 40 lower-case hex characters"
  [[ $3 =~ $RE_ID ]] || die 2 "the CMS image id must be sha256: and 64 lower-case hex characters"
  [[ $4 =~ $RE_ID ]] || die 2 "the web image id must be sha256: and 64 lower-case hex characters"
  ENV_NAME=$1
  SHA=$2
  CMS_ID=$3
  WEB_ID=$4
}

# --- keeping the 3 newest tags ----------------------------------------------------------
prune_old() {
  local listing app id created name n bad=0
  local -a rows=()
  listing=$(list_images 2>/dev/null) || {
    say "WARNING: could not list images; old releases were not pruned"
    return 0
  }
  for app in cms web; do
    rows=()
    while IFS='|' read -r id created name; do
      [[ $name =~ ^localhost/oc-$app:[0-9a-f]{40}$ ]] || continue
      [[ $created =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ \+0000\ UTC$ ]] || bad=1
      rows+=("$created|$name")
    done <<<"$listing"
    if [[ $bad == 1 ]]; then
      say "WARNING: the image list has creation times in an unexpected form; old releases were not pruned"
      return 0
    fi
    n=0
    while IFS='|' read -r created name; do
      [[ -n $name ]] || continue
      n=$((n + 1))
      ((n > KEEP_TAGS)) || continue
      # The release that is running now, and the one before it, are never removed.
      [[ $name != "$NEW_CMS" && $name != "$NEW_WEB" && $name != "$PREV_CMS" && $name != "$PREV_WEB" ]] || continue
      if podman_run rmi -- "$name" >/dev/null 2>&1; then
        say "removed the old release $name"
      else
        say "WARNING: could not remove $name (it may be in use)"
      fi
    done < <(printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1r -k2,2)
  done
}

main() {
  set -Eeuo pipefail
  export LC_ALL=C PATH=$SAFE_PATH
  umask 077
  unset BASH_ENV ENV CDPATH
  cd /

  check_args "$@"
  trap on_exit EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # A dropped SSH connection must not stop a deploy halfway, and a write to a closed
  # output must not either.
  trap '' HUP PIPE
  setup

  # --- 1. one deploy at a time, and a spool file that can be trusted
  [[ -d $(dirname -- "$LOCK_FILE") ]] || die 1 "$(dirname -- "$LOCK_FILE") does not exist"
  [[ ! -L $LOCK_FILE ]] || die 1 "the lock file is a symbolic link"
  exec 7>>"$LOCK_FILE"
  flock -n 7 || die 4 "another deploy is already running; nothing was changed"
  HAVE_LOCK=1
  open_spool
  say "deploying $SHA to $ENV_NAME (spool file $SPOOL_SIZE bytes)"

  # --- 2. what is deployed now
  PREV_CMS=$(read_image cms)
  PREV_WEB=$(read_image web)
  PREV_EXISTS=0
  PREV_CMS_ID=
  PREV_WEB_ID=
  if podman_run image exists "$PREV_CMS" >/dev/null 2>&1 && podman_run image exists "$PREV_WEB" >/dev/null 2>&1; then
    PREV_EXISTS=1
    # the ids of the release that runs now, so a rollback can check that it is the one running again
    PREV_CMS_ID=$(norm_id "$(podman_run image inspect --format '{{.Id}}' "$PREV_CMS" 2>/dev/null | head -n 1)")
    PREV_WEB_ID=$(norm_id "$(podman_run image inspect --format '{{.Id}}' "$PREV_WEB" 2>/dev/null | head -n 1)")
  fi

  # --- 3. load the images
  local listing ref id i name problem=""
  local -a want_refs=("$NEW_CMS" "$NEW_WEB") want_ids=()
  want_ids=("$(norm_id "$CMS_ID")" "$(norm_id "$WEB_ID")")
  listing=$(list_images) || die 1 "could not list the images of oc-$ENV_NAME"
  fill_names "$listing" BEFORE
  fill_ids "$listing" BEFORE_IDS
  for i in 0 1; do
    ref=${want_refs[$i]}
    id=${want_ids[$i]}
    if [[ -n ${BEFORE[$ref]+x} && ${BEFORE[$ref]} != "$id" ]]; then
      die 3 "$ref already exists here with a different image id; a release tag is never overwritten. Deploy a new commit instead. Nothing was changed."
    fi
  done
  STATE=loaded # from here on a failure removes what the load added
  local loadout
  if ! loadout=$(load_pipeline 2>&1); then
    say "podman could not load the tarball (what it said is quoted, and is not ours):"
    printf '%s\n' "$loadout" | quote_output >&2 || true
    die 6 "the tarball could not be loaded; nothing was changed"
  fi

  # --- 4. the ids must be the ones CI sent, and nothing else may have come in
  local -A after=() after_ids=()
  listing=$(list_images) || die 1 "could not list the images of oc-$ENV_NAME after the load"
  fill_names "$listing" after
  fill_ids "$listing" after_ids
  local got
  for i in 0 1; do
    ref=${want_refs[$i]}
    id=${want_ids[$i]}
    # The id Podman reports for the tag, compared with the id CI got from Docker. Podman
    # prints the bare hex and Docker prints sha256:<hex>, so the prefix is dropped on both sides.
    if ! got=$(podman_run image inspect --format '{{.Id}}' "$ref" 2>/dev/null) || [[ -z $got ]]; then
      problem+=" $ref was not in the tarball;"
    elif [[ $(norm_id "$got") != "$id" ]]; then
      problem+=" the image id of $ref ($(norm_id "$got")) does not match the id CI sent ($id);"
    fi
  done
  for name in "${!after[@]}"; do
    [[ $name == "$NEW_CMS" || $name == "$NEW_WEB" ]] && continue
    if [[ -z ${BEFORE[$name]+x} ]]; then
      problem+=" the tarball also held the image $name;"
    elif [[ ${BEFORE[$name]} != "${after[$name]}" ]]; then
      problem+=" the tarball moved the existing tag $name to another image;"
    fi
  done
  # an image with no name: the two images CI sent are named, so anything else that is new is not theirs
  for id in "${!after_ids[@]}"; do
    [[ -z ${BEFORE_IDS[$id]+x} && $id != "${want_ids[0]}" && $id != "${want_ids[1]}" ]] || continue
    problem+=" the tarball also held an image with no name ($id);"
  done
  if [[ -n $problem ]]; then
    die 3 "the loaded images do not match what CI sent:$problem nothing was changed (the load is undone)"
  fi
  say "loaded $NEW_CMS and $NEW_WEB; the image ids match"
  STATE=verified

  # --- 5. point the units at the new tags and restart
  STATE=repointing
  set_image cms "$NEW_CMS"
  set_image web "$NEW_WEB"
  [[ $(read_image cms) == "$NEW_CMS" && $(read_image web) == "$NEW_WEB" ]] || die 1 "the Image= lines were not rewritten as intended"
  # shellcheck disable=SC2034  # read through an indirect expansion in images_current
  EXPECT_CMS_ID=${want_ids[0]}
  # shellcheck disable=SC2034
  EXPECT_WEB_ID=${want_ids[1]}
  restart_both || die 1 "the services did not restart"

  # --- 6. wait for both health checks
  say "waiting up to ${HEALTH_TIMEOUT}s for /_health on $CMS_PORT and /healthz on $WEB_PORT"
  wait_healthy || die 1 "the new release did not become healthy, with both running containers made from the new images, within ${HEALTH_TIMEOUT}s"

  STATE=finished
  say "healthy: $ENV_NAME now runs $SHA"
  # --- 8. housekeeping, which never fails a good deploy
  prune_old || true
  say "done"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
