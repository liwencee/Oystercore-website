#!/usr/bin/env bash
# Nginx: the rendered site configuration, Cloudflare's client-certificate CA, the origin
# TLS certificate, and the Cloudflare real-IP list. The real-IP functions are shared with
# the weekly refresh (bin/oc-cloudflare-ips).
# Needs lib/common.sh and lib/firewall.sh (for the Cloudflare ranges).
# shellcheck shell=bash

OC_NEXT_STEPS=()
oc_next() { OC_NEXT_STEPS+=("$1"); }

# --- Cloudflare real IP ------------------------------------------------------------
# nginx_realip_content: the file body for FW_CF_V4 and FW_CF_V6. No timestamp, so the
# file only changes when Cloudflare's ranges do.
nginx_realip_content() {
  local c
  printf '%s\n' "# Managed by oc-cloudflare-ips (infra/lib/nginx.sh). Do not edit: the weekly timer rewrites it."
  printf '%s\n' "# Source: https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6"
  for c in "${FW_CF_V4[@]}" "${FW_CF_V6[@]}"; do
    printf 'set_real_ip_from %s;\n' "$c"
  done
  printf '%s\n' "real_ip_header CF-Connecting-IP;"
}

# nginx_test: run nginx -t, showing its output only on failure.
nginx_test() {
  oc_quiet nginx -t
}

# nginx_reload: reload a running nginx, or start it (not in container mode).
nginx_reload() {
  if oc_container_mode; then
    oc_log "container: nginx configuration tested, not reloaded"
    return 0
  fi
  systemctl enable nginx >/dev/null 2>&1
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi
}

# nginx_update_realip: write the real-IP file; if nginx rejects it, put the old one back.
nginx_update_realip() {
  local backup had=no before=$OC_CHANGES content
  oc_mktemp_into backup
  if [[ -f $OC_NGINX_REALIP ]]; then
    cp -p -- "$OC_NGINX_REALIP" "$backup"
    had=yes
  fi
  content=$(nginx_realip_content)
  oc_install_stdin "$OC_NGINX_REALIP" 0644 root root <<<"$content"
  if [[ $OC_CHANGES -eq $before ]]; then
    return 0
  fi
  if ! nginx_test; then
    if [[ $had == yes ]]; then
      cp -p -- "$backup" "$OC_NGINX_REALIP"
    else
      rm -f -- "$OC_NGINX_REALIP"
    fi
    oc_die "nginx rejected the new Cloudflare list; the previous list was restored"
  fi
  nginx_reload
}

# --- site configuration ------------------------------------------------------------
# nginx_render TEMPLATE: print the configuration. The part between @@BEGIN env@@ and
# @@END env@@ is repeated once per environment. Values are substituted with bash
# pattern replacement, so nothing is ever evaluated.
nginx_render() {
  local template=$1 line env b robots web_host cms_host web_port cms_port
  local in_block=0
  local -a block=()
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      '@@BEGIN env@@')
        in_block=1
        block=()
        continue
        ;;
      '@@END env@@')
        in_block=0
        for env in "${OC_ENV_LIST[@]}"; do
          if [[ $env == prod ]]; then
            robots='# production website: indexable'
          else
            robots='add_header X-Robots-Tag "noindex, nofollow" always;'
          fi
          web_host=$(oc_web_host "$env")
          cms_host=$(oc_cms_host "$env")
          web_port=$(oc_web_port "$env")
          cms_port=$(oc_cms_port "$env")
          for b in "${block[@]}"; do
            b=${b//@@ENV@@/$env}
            b=${b//@@WEB_HOST@@/$web_host}
            b=${b//@@CMS_HOST@@/$cms_host}
            b=${b//@@WEB_PORT@@/$web_port}
            b=${b//@@CMS_PORT@@/$cms_port}
            b=${b//@@WEB_ROBOTS@@/$robots}
            printf '%s\n' "$b"
          done
        done
        continue
        ;;
      *) ;;
    esac
    if ((in_block)); then
      block+=("$line")
    else
      printf '%s\n' "$line"
    fi
  done <"$template"
}

# nginx_ensure_ca: Cloudflare's Authenticated Origin Pulls CA, copied from the repository.
nginx_ensure_ca() {
  local src="$OC_INFRA_DIR/nginx/cloudflare-origin-pull-ca.pem"
  [[ -f $src ]] || oc_die "missing $src"
  openssl x509 -in "$src" -noout 2>/dev/null || oc_die "$src is not a valid certificate"
  openssl x509 -in "$src" -noout -checkend 15552000 >/dev/null 2>&1 ||
    oc_warn "the Cloudflare origin pull CA in the repository expires within 180 days; check Cloudflare's documentation for a new one"
  oc_ensure_dir "$OC_NGINX_DIR" 0755 root root
  oc_install_file "$src" "$OC_NGINX_CA" 0644 root root
}

# nginx_note_placeholder: remind the owner, on every run, while the placeholder certificate is in use.
nginx_note_placeholder() {
  local subject
  subject=$(openssl x509 -in "$OC_TLS_CERT" -noout -subject 2>/dev/null || true)
  if [[ $subject == *oc-placeholder* ]]; then
    oc_next "REPLACE THE PLACEHOLDER TLS CERTIFICATE. In Cloudflare, create an Origin Certificate for *.$OC_DOMAIN and $OC_DOMAIN, save it as $OC_TLS_CERT and its key as $OC_TLS_KEY (key mode 0600, owner root), then run: systemctl reload nginx. Until then Cloudflare's Full (strict) mode will refuse this server. infra/verify.sh shows a WARN for it."
  fi
}

# nginx_ensure_origin_cert: the owner installs a Cloudflare origin certificate at
# /etc/ssl/oc/origin.pem and origin.key. Until then a self-signed placeholder lets nginx
# start (Cloudflare's "Full (strict)" mode will refuse it, which is the point).
nginx_ensure_origin_cert() {
  local env tmpk tmpc san="" hosts
  oc_ensure_dir "$OC_TLS_DIR" 0750 root root
  if [[ -s $OC_TLS_CERT && -s $OC_TLS_KEY ]]; then
    oc_fix_perms "$OC_TLS_CERT" 0644 root root
    oc_fix_perms "$OC_TLS_KEY" 0600 root root
    nginx_note_placeholder
    return 0
  fi
  if [[ -e $OC_TLS_CERT || -e $OC_TLS_KEY ]]; then
    oc_die "only one of $OC_TLS_CERT and $OC_TLS_KEY exists (or one is empty). Provide both, or remove both to get a placeholder."
  fi
  for env in "${OC_ENV_LIST[@]}"; do
    san+="DNS:$(oc_web_host "$env"),DNS:$(oc_cms_host "$env"),"
  done
  hosts=${san%,}
  (
    umask 077
    tmpk=$(mktemp -p "$OC_TLS_DIR" ".oc-tmp.XXXXXX")
    tmpc=$(mktemp -p "$OC_TLS_DIR" ".oc-tmp.XXXXXX")
    trap 'rm -f -- "$tmpk" "$tmpc"' EXIT
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 365 \
      -subj "/CN=oc-placeholder-do-not-trust" -addext "subjectAltName=$hosts" \
      -keyout "$tmpk" -out "$tmpc" >/dev/null 2>&1
    chmod 0644 -- "$tmpc"
    mv -n -- "$tmpk" "$OC_TLS_KEY"
    mv -n -- "$tmpc" "$OC_TLS_CERT"
  ) || oc_die "could not create the placeholder TLS certificate"
  oc_changed "created a placeholder self-signed certificate at $OC_TLS_CERT"
  nginx_note_placeholder
}

# nginx_install_site: render, install, test, and put the old files back if nginx objects.
nginx_install_site() {
  local rendered backup had=no before=$OC_CHANGES
  oc_mktemp_into rendered
  nginx_render "$OC_INFRA_DIR/nginx/oc.conf.template" >"$rendered"
  if grep -q '@@' -- "$rendered"; then
    oc_die "the Nginx template still has unreplaced @@...@@ markers"
  fi
  oc_mktemp_into backup
  if [[ -f $OC_NGINX_CONF ]]; then
    cp -p -- "$OC_NGINX_CONF" "$backup"
    had=yes
  fi
  oc_install_stdin "$OC_NGINX_CONF" 0644 root root <"$rendered"
  # Ubuntu's welcome site would clash with our default servers.
  if [[ -e /etc/nginx/sites-enabled/default || -L /etc/nginx/sites-enabled/default ]]; then
    rm -f -- /etc/nginx/sites-enabled/default
    oc_changed "removed the default Nginx site"
  fi
  if ! nginx_test; then
    if [[ $had == yes ]]; then
      cp -p -- "$backup" "$OC_NGINX_CONF"
    else
      rm -f -- "$OC_NGINX_CONF"
    fi
    oc_die "nginx rejected the new configuration; the previous one was restored"
  fi
  if [[ $OC_CHANGES -ne $before ]]; then
    nginx_reload
  elif ! oc_container_mode && ! systemctl is-active --quiet nginx; then
    nginx_reload
  fi
}
