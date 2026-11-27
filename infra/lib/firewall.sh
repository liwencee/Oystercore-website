#!/usr/bin/env bash
# ufw: deny inbound by default, allow SSH, and open ports 80 and 443 only to Cloudflare's
# published address ranges. The range handling is shared with the weekly refresh
# (bin/oc-cloudflare-ips), so it does not read any server.env setting.
# Needs lib/common.sh.
# shellcheck shell=bash

FW_CF_V4=()
FW_CF_V6=()
FW_CF_COMMENT=oc-cloudflare
FW_SSH_COMMENT=oc-ssh
FW_CF_PORTS=80,443

# --- Cloudflare ranges -------------------------------------------------------------
fw_valid_v4() {
  local c=$1 i pfx
  [[ $c =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  for i in 1 2 3 4; do
    ((10#${BASH_REMATCH[i]} <= 255)) || return 1
  done
  pfx=$((10#${BASH_REMATCH[5]}))
  # Cloudflare's widest range is a /13. Anything wider would open the firewall to far
  # more than Cloudflare, so it is refused.
  ((pfx >= 12 && pfx <= 32))
}

fw_valid_v6() {
  local c=$1 pfx
  [[ $c =~ ^[0-9a-f:]+/([0-9]{1,3})$ ]] || return 1
  [[ $c == *:*:* && $c != *:::* ]] || return 1
  pfx=$((10#${BASH_REMATCH[1]}))
  ((pfx >= 29 && pfx <= 128))
}

# fw_fetch_list KIND DEST: copy ips-v4 or ips-v6 to DEST, from OC_CF_IPS_DIR (tests) or
# from Cloudflare over HTTPS.
fw_fetch_list() {
  local kind=$1 dest=$2
  if [[ -n ${OC_CF_IPS_DIR:-} ]]; then
    [[ -r $OC_CF_IPS_DIR/ips-$kind ]] || oc_die "missing $OC_CF_IPS_DIR/ips-$kind"
    cp -- "$OC_CF_IPS_DIR/ips-$kind" "$dest"
  else
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --max-time 30 --retry 3 -o "$dest" -- "https://www.cloudflare.com/ips-$kind" ||
      oc_die "could not download Cloudflare's ips-$kind list (nothing was changed)"
  fi
}

# fw_parse_list KIND FILE: validate every line and append it to FW_CF_V4 or FW_CF_V6.
fw_parse_list() {
  local kind=$1 file=$2 line n=0
  local -a found=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(oc_trim "${line%$'\r'}")
    line=${line,,}
    [[ -n $line ]] || continue
    if [[ $kind == v4 ]]; then
      fw_valid_v4 "$line" || oc_die "Cloudflare ips-v4 holds an unexpected line '$line'; refusing to use the list"
    else
      fw_valid_v6 "$line" || oc_die "Cloudflare ips-v6 holds an unexpected line '$line'; refusing to use the list"
    fi
    found+=("$line")
    n=$((n + 1))
  done <"$file"
  # Cloudflare publishes about 15 IPv4 and 7 IPv6 ranges. Far fewer or far more means the
  # download is wrong, and a wrong list must not replace a good one.
  if [[ $kind == v4 ]]; then
    ((n >= 5 && n <= 100)) || oc_die "Cloudflare ips-v4 has $n ranges, which is not plausible; refusing to use it"
    mapfile -t FW_CF_V4 < <(printf '%s\n' "${found[@]}" | sort -u)
  else
    ((n >= 3 && n <= 100)) || oc_die "Cloudflare ips-v6 has $n ranges, which is not plausible; refusing to use it"
    mapfile -t FW_CF_V6 < <(printf '%s\n' "${found[@]}" | sort -u)
  fi
}

fw_load_cloudflare_ips() {
  local f4 f6
  oc_mktemp_into f4
  oc_mktemp_into f6
  fw_fetch_list v4 "$f4"
  fw_fetch_list v6 "$f6"
  fw_parse_list v4 "$f4"
  fw_parse_list v6 "$f6"
}

# --- rules -------------------------------------------------------------------------
# One line per user rule, as `ufw show added` prints them, without the comment.
fw_rule_keys() {
  local line
  ufw show added 2>/dev/null | while IFS= read -r line; do
    [[ $line == "ufw "* ]] || continue
    printf '%s\n' "${line% comment *}"
  done
}

# Rules carrying our Cloudflare comment, without the comment.
fw_cf_rule_keys() {
  local line
  ufw show added 2>/dev/null | while IFS= read -r line; do
    [[ $line == "ufw "*" comment '$FW_CF_COMMENT'" ]] || continue
    printf '%s\n' "${line% comment *}"
  done
}

fw_cf_key() { printf 'ufw allow from %s to any port %s proto tcp' "$1" "$FW_CF_PORTS"; }

# fw_sync_cloudflare: add missing Cloudflare rules first, then delete stale ones, so
# Cloudflare is never locked out in between.
fw_sync_cloudflare() {
  local cidr key
  local -A want=() have=()
  local -a cur=()
  mapfile -t cur < <(fw_cf_rule_keys)
  for key in "${cur[@]}"; do
    [[ -n $key ]] && have[$key]=1
  done
  for cidr in "${FW_CF_V4[@]}" "${FW_CF_V6[@]}"; do
    key=$(fw_cf_key "$cidr")
    want[$key]=1
    if [[ -z ${have[$key]:-} ]]; then
      oc_quiet ufw allow from "$cidr" to any port "$FW_CF_PORTS" proto tcp comment "$FW_CF_COMMENT"
      oc_changed "ufw: allow $FW_CF_PORTS from $cidr"
    fi
  done
  for key in "${!have[@]}"; do
    if [[ -z ${want[$key]:-} ]]; then
      cidr=${key#ufw allow from }
      cidr=${cidr%% *}
      oc_quiet ufw --force delete allow from "$cidr" to any port "$FW_CF_PORTS" proto tcp
      oc_changed "ufw: removed stale Cloudflare range $cidr"
    fi
  done
}

fw_ssh_key() { printf 'ufw allow %s/tcp' "$OC_SSH_PORT"; }

# fw_baseline: default policies. ufw rewrites its files (new modification times) even when
# a setting is already right, so a setting is only applied when it differs.
fw_baseline() {
  local f=/etc/default/ufw
  if ! grep -q '^DEFAULT_INPUT_POLICY="DROP"' "$f"; then
    oc_quiet ufw default deny incoming
    oc_changed "ufw: default deny incoming"
  fi
  if ! grep -q '^DEFAULT_OUTPUT_POLICY="ACCEPT"' "$f"; then
    oc_quiet ufw default allow outgoing
    oc_changed "ufw: default allow outgoing"
  fi
  if ! grep -q '^DEFAULT_FORWARD_POLICY="DROP"' "$f"; then
    oc_quiet ufw default deny routed
    oc_changed "ufw: default deny routed"
  fi
  if ! grep -q '^LOGLEVEL=low$' /etc/ufw/ufw.conf; then
    oc_quiet ufw logging low
    oc_changed "ufw: logging low"
  fi
}

# fw_has_rule KEY: is that exact rule present? (Not a grep pipe: with pipefail, grep -q
# closing the pipe early would make a present rule look absent.)
fw_has_rule() {
  local k
  local -a keys=()
  mapfile -t keys < <(fw_rule_keys)
  for k in "${keys[@]}"; do
    [[ $k == "$1" ]] && return 0
  done
  return 1
}

fw_add_ssh_rule() {
  local key
  key=$(fw_ssh_key)
  if ! fw_has_rule "$key"; then
    oc_quiet ufw allow "$OC_SSH_PORT/tcp" comment "$FW_SSH_COMMENT"
    oc_changed "ufw: allow SSH on $OC_SSH_PORT/tcp"
  fi
}

# fw_prune_unmanaged: delete every user rule that is not the SSH rule or a Cloudflare
# rule. Run only after SSH is confirmed on its new port. The firewall is defined by these
# scripts, so a rule added by hand (or left by the image) does not survive a rerun.
fw_prune_unmanaged() {
  local key cidr
  local -A want=()
  local -a cur=() args=()
  want[$(fw_ssh_key)]=1
  for cidr in "${FW_CF_V4[@]}" "${FW_CF_V6[@]}"; do
    want[$(fw_cf_key "$cidr")]=1
  done
  mapfile -t cur < <(fw_rule_keys)
  for key in "${cur[@]}"; do
    [[ -n $key ]] || continue
    if [[ -z ${want[$key]:-} ]]; then
      read -r -a args <<<"${key#ufw }"
      if oc_quiet ufw --force delete "${args[@]}"; then
        oc_changed "ufw: removed unmanaged rule '$key'"
      else
        oc_warn "could not remove the unmanaged ufw rule '$key'; remove it by hand (verify.sh NET-02 will fail until then)"
      fi
    fi
  done
}

fw_enable() {
  local status
  if oc_container_mode; then
    oc_log "container: ufw rules written, firewall not activated (no kernel here)"
    return 0
  fi
  status=$(ufw status 2>/dev/null || true)
  if [[ $status == "Status: active"* ]]; then
    oc_log "ufw already active"
    return 0
  fi
  oc_quiet ufw --force enable
  oc_changed "ufw enabled"
}
