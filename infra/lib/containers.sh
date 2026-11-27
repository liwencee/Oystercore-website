#!/usr/bin/env bash
# Rootless Podman for each environment user: subuid and subgid ranges, lingering (so the
# user's services start at boot), and the Quadlet files that define the two app containers.
# Sourced by bootstrap.sh. Needs lib/common.sh and lib/users.sh (the users exist first).
# shellcheck shell=bash


# --- subuid and subgid -------------------------------------------------------------
# Rootless containers need a block of ids to map into. Two users must never share one, or
# a process in one environment would own files in the other.

# ctr_subid_next FILE: first id after every range already handed out (at least OC_SUBID_MIN).
ctr_subid_next() {
  awk -F: -v min="$OC_SUBID_MIN" 'BEGIN {m = min} {e = $2 + $3; if (e > m) m = e} END {print m}' "$1"
}

# ctr_subid_has FILE USER: does USER have a range of at least OC_SUBID_COUNT ids?
ctr_subid_has() {
  awk -F: -v u="$2" -v c="$OC_SUBID_COUNT" '$1 == u && $3 >= c {f = 1} END {exit !f}' "$1"
}

ctr_ensure_subids() {
  local user=$1 start end
  local file
  for file in /etc/subuid /etc/subgid; do
    [[ -f $file ]] || install -m 0644 -o root -g root /dev/null "$file"
    if ! ctr_subid_has "$file" "$user"; then
      start=$(ctr_subid_next "$file")
      end=$((start + OC_SUBID_COUNT - 1))
      if [[ $file == /etc/subuid ]]; then
        usermod --add-subuids "$start-$end" -- "$user"
      else
        usermod --add-subgids "$start-$end" -- "$user"
      fi
      oc_changed "gave $user $file range $start-$end"
    fi
  done
}

# --- lingering ---------------------------------------------------------------------
# With lingering on, systemd starts the user's own service manager at boot instead of at
# login, so the containers start with the machine. (loginctl enable-linger only creates a
# file; in the test container there is no logind, so the file is made directly.)
ctr_ensure_linger() {
  local user=$1
  if [[ -e $OC_LINGER_DIR/$user ]]; then
    return 0
  fi
  if oc_container_mode; then
    install -d -m 0755 -o root -g root "$OC_LINGER_DIR"
    install -m 0644 -o root -g root /dev/null "$OC_LINGER_DIR/$user"
  else
    loginctl enable-linger "$user"
  fi
  oc_changed "enabled lingering for $user"
}

# --- Quadlet files -----------------------------------------------------------------
# ctr_current_image FILE: the Image= value of an existing Quadlet file, or nothing. The
# deploy script (Task 4) changes that one line; a rerun of the bootstrap must not undo it.
ctr_current_image() {
  [[ -f $1 ]] || return 0
  awk '/^Image=/ {print substr($0, 7); exit}' "$1"
}

# ctr_render TEMPLATE ENV KEEP_IMAGE: print a Quadlet file. Values are put in with bash
# pattern replacement, so nothing is evaluated. KEEP_IMAGE (may be empty) replaces the
# placeholder Image= line.
ctr_render() {
  local template=$1 env=$2 keep=$3 line uid gid host_port internal_port
  uid=$(oc_env_uid "$env")
  gid=$(oc_env_gid "$env")
  [[ -n $uid && -n $gid ]] || oc_die "the user oc-$env does not exist yet"
  case $template in
    *oc-cms.container.template)
      host_port=$(oc_cms_port "$env")
      internal_port=$OC_CMS_INTERNAL_PORT
      ;;
    *)
      host_port=$(oc_web_port "$env")
      internal_port=$OC_WEB_INTERNAL_PORT
      ;;
  esac
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == Image=* && -n $keep ]]; then
      line="Image=$keep"
    fi
    line=${line//@@ENV@@/$env}
    line=${line//@@UID@@/$uid}
    line=${line//@@GID@@/$gid}
    line=${line//@@HOST_PORT@@/$host_port}
    line=${line//@@INTERNAL_PORT@@/$internal_port}
    line=${line//@@CMS_INTERNAL_PORT@@/$OC_CMS_INTERNAL_PORT}
    line=${line//@@MARIADB_SOCKET@@/$OC_MARIADB_SOCKET}
    line=${line//@@CLAMD_SOCKET@@/$OC_CLAMD_SOCKET}
    line=${line//@@MARIADB_RUN_DIR@@/$OC_MARIADB_RUN_DIR}
    line=${line//@@CLAMD_RUN_DIR@@/$OC_CLAMD_RUN_DIR}
    printf '%s\n' "$line"
  done <"$template"
}

# ctr_install_quadlet ENV: the user's folders, the environment's network, and the two
# container files. The files belong to the environment user (the deploy script runs as that
# user), but live in its home, which the apps cannot write: only /var/lib/oc/<env> is mounted.
ctr_install_quadlet() {
  local env=$1 user="oc-$1" home qdir name template rendered keep dest
  home=$(oc_env_home "$env")
  qdir=$(oc_env_quadlet_dir "$env")
  oc_ensure_dir "$home" 0700 "$user" "$user"
  oc_ensure_dir "$home/.config" 0700 "$user" "$user"
  oc_ensure_dir "$home/.config/containers" 0700 "$user" "$user"
  oc_ensure_dir "$qdir" 0700 "$user" "$user"
  oc_install_stdin "$qdir/oc-$env.network" 0640 "$user" "$user" <<EOF
# Managed by infra/bootstrap.sh. The private network of the $env environment: the two
# containers reach each other by name here, and nothing else can reach them.
[Network]
NetworkName=oc-$env
EOF
  for name in cms web; do
    template="$OC_INFRA_DIR/quadlet/oc-$name.container.template"
    dest="$qdir/oc-$name-$env.container"
    [[ -f $template ]] || oc_die "missing $template"
    keep=$(ctr_current_image "$dest")
    oc_mktemp_into rendered
    ctr_render "$template" "$env" "$keep" >"$rendered"
    if grep -q '@@' -- "$rendered"; then
      oc_die "the Quadlet template for $name still has unreplaced @@...@@ markers"
    fi
    oc_install_stdin "$dest" 0640 "$user" "$user" <"$rendered"
  done
}

# ctr_user_systemctl ENV ARGS...: systemctl --user, as the environment user.
ctr_user_systemctl() {
  local env=$1 uid
  shift
  uid=$(oc_env_uid "$env")
  runuser -u "oc-$env" -- env "HOME=$(oc_env_home "$env")" "XDG_RUNTIME_DIR=/run/user/$uid" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" systemctl --user "$@"
}

# ctr_reload ENV: make the environment user's systemd regenerate the services from the
# Quadlet files, and check that both services now exist. The containers are NOT started:
# there is no image yet. They start with the first deploy (Task 4), and at boot after that.
ctr_reload() {
  local env=$1 uid i name
  if oc_container_mode; then
    return 0
  fi
  uid=$(oc_env_uid "$env")
  for i in $(seq 1 30); do
    [[ -S /run/user/$uid/bus ]] && break
    sleep 1
    if [[ $i -eq 30 ]]; then
      oc_die "the systemd user manager of oc-$env did not start (lingering is on; see: systemctl status user@$uid)"
    fi
  done
  ctr_user_systemctl "$env" daemon-reload
  for name in oc-cms-$env oc-web-$env; do
    ctr_user_systemctl "$env" cat "$name.service" >/dev/null 2>&1 ||
      oc_die "Podman's Quadlet generator did not produce $name.service for oc-$env. Look at: journalctl -b _UID=$uid, and run /usr/libexec/podman/quadlet -dryrun -user as that user."
  done
}

# ctr_setup_env ENV: everything rootless Podman needs for one environment.
ctr_setup_env() {
  local env=$1 before=$OC_CHANGES
  ctr_ensure_subids "oc-$env"
  ctr_ensure_linger "oc-$env"
  ctr_install_quadlet "$env"
  if [[ $OC_CHANGES -ne $before ]] || ! oc_container_mode; then
    ctr_reload "$env"
  fi
}
