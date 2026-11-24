#!/usr/bin/env bash
# Runs inside the test container, after the bootstrap (called by container-run.sh).
# Starts Nginx with the REAL rendered configuration and four fake backends on the real
# ports, then checks behaviour with curl. The only change: Cloudflare's origin-pull CA is
# swapped for a test CA for the duration, because only Cloudflare holds a certificate
# signed by the real one. The real CA is put back at the end.
#
# Usage: nginx-behaviour.sh WORKDIR     Exit status: the number of failed checks.
set -uo pipefail
export LC_ALL=C

work=${1:?work directory}
d="$work/nginx-test"
real_ca=/etc/nginx/oc/cloudflare-origin-pull-ca.pem
failed=0

ok() { printf 'ok     - %s\n' "$*"; }
notok() {
  printf 'NOT OK - %s\n' "$*"
  failed=$((failed + 1))
}
# check DESCRIPTION ACTUAL EXPECTED
check() {
  if [[ $2 == "$3" ]]; then ok "$1"; else notok "$1 (got '$2', wanted '$3')"; fi
}
# check_match DESCRIPTION ACTUAL REGEX
check_match() {
  if [[ $2 =~ $3 ]]; then ok "$1"; else notok "$1 (got '$2', wanted /$3/)"; fi
}

mkdir -p "$d"
cp -- "$real_ca" "$d/real-ca.pem"
pids=()
# shellcheck disable=SC2317  # called from the EXIT trap
cleanup() {
  nginx -s stop >/dev/null 2>&1 || true
  local p
  for p in "${pids[@]}"; do kill "$p" >/dev/null 2>&1 || true; done
  cp -- "$d/real-ca.pem" "$real_ca"
}
trap cleanup EXIT

# --- a test CA, a client certificate it signed, and one from a different CA ---------
mkca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
    -subj "/CN=$1" -keyout "$d/$1.key" -out "$d/$1.pem" >/dev/null 2>&1
}
mkclient() {
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=client-$1" \
    -keyout "$d/client-$1.key" -out "$d/client-$1.csr" >/dev/null 2>&1
  openssl x509 -req -in "$d/client-$1.csr" -CA "$d/$1.pem" -CAkey "$d/$1.key" -CAcreateserial \
    -days 2 -out "$d/client-$1.crt" >/dev/null 2>&1
}
mkca test-origin-pull-ca
mkca rogue-ca
mkclient test-origin-pull-ca
mkclient rogue-ca
cp -- "$d/test-origin-pull-ca.pem" "$real_ca"

# --- fake backends: they answer with what they received ----------------------------
# (The apps themselves are containers now and the test image has no container runtime, so
# Nginx is tested against small stand-ins on the real localhost ports.)
cat >"$d/backend.py" <<'EOF'
import http.server
import json
import sys
import threading


def make(port):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def reply(self, head=False):
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            body = json.dumps(
                {
                    "port": port,
                    "method": self.command,
                    "url": self.path,
                    "host": self.headers.get("Host"),
                    "xff": self.headers.get("X-Forwarded-For"),
                    "xfp": self.headers.get("X-Forwarded-Proto"),
                },
                separators=(",", ":"),
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Powered-By", "fake-app")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def do_GET(self):
            self.reply()

        def do_POST(self):
            self.reply()

        def do_PUT(self):
            self.reply()

        def do_HEAD(self):
            self.reply(head=True)

    return Handler


for p in sys.argv[1:]:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", int(p)), make(int(p)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
EOF
python3 "$d/backend.py" 4321 4322 1337 1338 >"$d/backend.log" 2>&1 &
pids+=($!)
nginx -t >/dev/null 2>&1 || {
  nginx -t
  exit 1
}
nginx
for _ in $(seq 1 30); do
  ss -H -ltn | awk '$4 ~ /:443$/ {f = 1} END {exit !f}' &&
    ss -H -ltn | awk '$4 ~ /:4321$/ {f = 1} END {exit !f}' && break
  sleep 0.3
done

web=www.example.test
cms=cms.example.test
stg=staging.example.test
cmsstg='cms-staging.example.test'
good=(--cert "$d/client-test-origin-pull-ca.crt" --key "$d/client-test-origin-pull-ca.key")
rogue=(--cert "$d/client-rogue-ca.crt" --key "$d/client-rogue-ca.key")

# curl to HOST at 127.0.0.1:443. Extra curl arguments follow the host.
c() {
  local host=$1
  shift
  curl -sk --max-time 15 --resolve "$host:443:127.0.0.1" "$@"
}
code() { # HOST PATH [curl args]
  local host=$1 path=$2
  shift 2
  c "$host" -o /dev/null -w '%{http_code}' "$@" "https://$host$path"
}
body() {
  local host=$1 path=$2
  shift 2
  c "$host" "$@" "https://$host$path"
}

printf 'Authenticated Origin Pulls\n'
check "no client certificate: refused (400)" "$(code "$web" /)" 400
check "a certificate from another CA: refused (400)" "$(code "$web" / "${rogue[@]}")" 400
check "Cloudflare's CA signed the certificate: served (200)" "$(code "$web" / "${good[@]}")" 200

printf 'Routing to the right app and port\n'
check_match "www -> web app, prod port 4321" "$(body "$web" / "${good[@]}")" '"port":4321'
check_match "cms -> Strapi, prod port 1337" "$(body "$cms" / "${good[@]}")" '"port":1337'
check_match "staging -> web app, staging port 4322" "$(body "$stg" / "${good[@]}")" '"port":4322'
check_match "cms-staging -> Strapi, staging port 1338" "$(body "$cmsstg" / "${good[@]}")" '"port":1338'
check_match "www /media/ passes through to the web app" "$(body "$web" /media/x.png "${good[@]}")" '"port":4321.*"url":"/media/x.png"'
check_match "cms /media/ passes through to Strapi" "$(body "$cms" /media/x.png "${good[@]}")" '"port":1337.*"url":"/media/x.png"'
check_match "cms /transfer/ passes through to Strapi" "$(body "$cms" /transfer/upload/abc "${good[@]}")" '"port":1337.*"url":"/transfer/upload/abc"'
check_match "the upstream sees https and the original host" "$(body "$web" / "${good[@]}")" '"host":"www.example.test".*"xfp":"https"'

printf 'Dotfiles\n'
check "/.env is denied" "$(code "$web" /.env "${good[@]}")" 404
check "/.git/config is denied" "$(code "$web" /.git/config "${good[@]}")" 404
check "a dotfile under /media/ is denied" "$(code "$cms" /media/.hidden "${good[@]}")" 404
check "a dotfile on the CMS is denied" "$(code "$cms" /admin/.env "${good[@]}")" 404
check "/.well-known/ stays reachable" "$(code "$web" /.well-known/security.txt "${good[@]}")" 200

printf 'Client address\n'
check_match "a spoofed X-Forwarded-For is replaced by the real peer" \
  "$(body "$web" / "${good[@]}" -H 'X-Forwarded-For: 6.6.6.6' -H 'CF-Connecting-IP: 7.7.7.7')" '"xff":"127.0.0.1"'

printf 'Refusing what it should not answer\n'
rc=0
c evil.test -o /dev/null "${good[@]}" https://evil.test/ || rc=$?
if [[ $rc -ne 0 ]]; then
  ok "an unknown host name gets no TLS handshake (curl exit $rc)"
else
  notok "an unknown host name was answered"
fi
rc=0
curl -s --max-time 10 -o /dev/null -H 'Host: evil.test' http://127.0.0.1/ || rc=$?
# nginx closes the connection without a reply (444): curl reports 52 (empty reply) or 56 (reset).
if [[ $rc -eq 52 || $rc -eq 56 ]]; then ok "an unknown host on port 80 gets no answer (curl exit $rc)"; else notok "an unknown host on port 80 was answered (curl exit $rc)"; fi
rc=0
curl -s --max-time 10 -o /dev/null http://127.0.0.1/ || rc=$?
if [[ $rc -eq 52 || $rc -eq 56 ]]; then ok "a request straight to the IP on port 80 gets no answer (curl exit $rc)"; else notok "a request straight to the IP on port 80 was answered (curl exit $rc)"; fi
check "port 80 for a known host redirects to HTTPS" \
  "$(curl -s --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "$web:80:127.0.0.1" "http://$web/a/b?c=1")" "301 https://$web/a/b?c=1"

printf 'Limits and banner\n'
check "a 31 MB body is refused (413)" "$(head -c 31M /dev/zero | code "$cms" /x "${good[@]}" --data-binary @-)" 413
check "a 31 MB upload chunk is refused too (413)" "$(head -c 31M /dev/zero | code "$cms" /transfer/upload/t "${good[@]}" --data-binary @-)" 413
check "a 2 MB body is accepted" "$(head -c 2M /dev/zero | code "$cms" /x "${good[@]}" --data-binary @-)" 200
hdr=$(c "$web" -I "${good[@]}" "https://$web/" | tr -d '\r')
if grep -qix 'server: nginx' <<<"$hdr"; then ok "the Server header shows no version"; else notok "the Server header shows a version: $(grep -i '^server' <<<"$hdr")"; fi
if grep -qi '^x-powered-by' <<<"$hdr"; then notok "X-Powered-By is passed on"; else ok "X-Powered-By from the app is removed"; fi
check_match "the staging site is marked noindex" "$(c "$stg" -I "${good[@]}" "https://$stg/" | tr -d '\r')" 'X-Robots-Tag: noindex'
check_match "the CMS is marked noindex" "$(c "$cms" -I "${good[@]}" "https://$cms/" | tr -d '\r')" 'X-Robots-Tag: noindex'
if c "$web" -I "${good[@]}" "https://$web/" | tr -d '\r' | grep -qi '^x-robots-tag'; then
  notok "the production website is marked noindex"
else
  ok "the production website is not marked noindex"
fi

printf 'Logs\n'
code "$cms" /transfer/download/SUPERSECRETTOKEN123 "${good[@]}" >/dev/null
sleep 0.5
if grep -q 'SUPERSECRETTOKEN123' /var/log/nginx/*.log 2>/dev/null; then
  notok "a transfer token reached an Nginx log"
else
  ok "a transfer token is kept out of the access log"
fi
if grep -q '/transfer/download/\[token\]' /var/log/nginx/oc-prod-cms.access.log; then
  ok "the access log shows /transfer/download/[token] instead"
else
  notok "the redacted transfer line is missing from the access log"
fi

exit "$failed"
