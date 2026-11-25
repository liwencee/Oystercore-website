#!/usr/bin/env bash
# Cases for the two hand-written parsers in verify.sh: the Nginx tokenizer (NET-03) and the
# Quadlet normaliser (CTR-01). Each case has the exact output it must give.
#
#   parser-cases.sh AWK            run every case with that awk (gawk, mawk, awk); exit status is
#                                  the number of wrong answers. The output does not name the awk,
#                                  so the outputs of two awks can be compared with diff.
#   parser-cases.sh AWK nginx      also ask the real Nginx (nginx -t) whether each case that is
#                                  meant to be valid really is, so the parser is only ever tested
#                                  on text Nginx itself accepts.
#
# The Nginx cases include the ones a reviewer used to get past NET-03: a quote or "${" or "}"
# in the middle of a word, a quoted "ssl", a "#" that is not a comment.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export OC_AWK=${1:?usage: parser-cases.sh AWK [nginx]}
mode=${2:-}
# shellcheck source=../verify.sh
source "$here/../verify.sh"

wrong=0
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
tls='ssl_certificate /etc/ssl/oc/origin.pem; ssl_certificate_key /etc/ssl/oc/origin.key;'

# ngx NAME VALID EXPECTED: the case's text comes on standard input.
ngx() {
  local name=$1 valid=$2 answer=$3 text got
  text=$(cat)
  got=$(nginx_servers <<<"$text")
  printf '== nginx: %s\n%s\n' "$name" "$got"
  if [[ $got != "$answer" ]]; then
    printf 'WRONG, wanted:\n%s\n' "$answer"
    wrong=$((wrong + 1))
  fi
  if [[ $mode == nginx && $valid == 1 ]]; then
    printf 'events {}\nhttp {\n%s\n}\n' "$text" >"$tmp/case.conf"
    if ! nginx -t -c "$tmp/case.conf" >"$tmp/nginx.out" 2>&1; then
      printf 'NGINX REFUSES THIS CASE (so it is not a valid test): %s\n' "$name" >&2
      sed 's/^/    /' "$tmp/nginx.out" >&2
      wrong=$((wrong + 1))
    fi
  fi
}

# qn NAME EXPECTED: the file's text comes on standard input; US is shown as |.
qn() {
  local name=$1 answer=$2 got
  cat >"$tmp/q.container"
  got=$(qnorm "$tmp/q.container" | tr '\037' '|')
  printf '== qnorm: %s\n%s\n' "$name" "$got"
  if [[ $got != "$answer" ]]; then
    printf 'WRONG, wanted:\n%s\n' "$answer"
    wrong=$((wrong + 1))
  fi
}

# --- the Nginx tokenizer ---------------------------------------------------------------
ngx "a normal multi-line server" 1 $'S|a.example b.example|1|0|0|on|/etc/ssl/oc/origin.pem|TLSv1.2 TLSv1.3\nT|1|0|0|0' <<EOF
server {
  listen 443 ssl;
  server_name a.example b.example;
  $tls
  ssl_verify_client on;
  ssl_client_certificate /etc/ssl/oc/origin.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  location / { return 404; }
}
EOF
ngx "a one-line server" 1 $'S|oneline.example|1|0|0|||\nT|1|0|0|0' <<EOF
server { listen 8443 ssl; server_name oneline.example; $tls }
EOF
ngx "server and { on separate lines" 1 $'S|twoline.example|1|0|0|||\nT|1|0|0|0' <<EOF
server
{
  listen 8444 ssl;
  server_name twoline.example;
  $tls
}
EOF
ngx "ssl on; instead of listen ssl" 1 $'S|sslon.example|1|0|0|||\nT|0|0|0|0' <<EOF
server { listen 8445; ssl on; server_name sslon.example; $tls }
EOF
ngx "two servers on one line" 1 $'S||0|0|0|||\nS|second.example|1|0|0|||\nT|1|0|0|0' <<EOF
server { listen 8449; return 404; } server { listen 8450 ssl; server_name second.example; $tls }
EOF
ngx "server{ with no space" 1 $'S||1|0|0|||\nT|1|0|0|0' <<EOF
server{ listen 8452 ssl; $tls }
EOF
ngx "quotes, a comment with a brace, and \${var} in a string" 1 $'S|q.example|1|0|0|off||\nT|1|0|0|0' <<EOF
map \$request_uri \$x { default \$request_uri; ~^(?<p>/t/[a-z]+/) "\${p}[token]"; }
server { listen 443 ssl; $tls ssl_verify_client "off"; # comment { with brace
  server_name q.example; }
EOF
ngx "an upstream server directive is not a server block" 1 $'S||0|0|0|||\nT|0|0|0|0' <<'EOF'
upstream u { server 127.0.0.1:1; keepalive 16; }
server { listen 80; return 301 https://$host$request_uri; }
EOF
ngx "an if block with parentheses and a quoted word" 1 $'S|l.example|1|0|0|||\nT|1|0|0|0' <<EOF
server { listen 8453 ssl; $tls if (\$request_method = "TRACE") { return 403; } server_name l.example; }
EOF
ngx "a listen outside any server" 0 $'T|0|1|1|0' <<'EOF'
stream { listen 9443 ssl; }
EOF
ngx "unbalanced braces" 0 $'T|1|0|0|1' <<'EOF'
server { listen 443 ssl;
EOF

# What the reviewer used to get past NET-03 (each is a TLS server with no client certificate).
ngx "a quote in the middle of a word (add_header X a'b;) before a quoted \"ssl\"" 1 \
  $'S|a.test|0|0|0|||\nS|q.test|1|0|0|||\nS|c.test|0|0|0|||\nT|1|0|0|0' <<EOF
server { listen 80; add_header X a'b; server_name a.test; }
server { listen 8443 "ssl"; server_name q.test; $tls }
server { listen 81; add_header Y c'd; server_name c.test; }
EOF
ngx "\${ in a value (default_type \${a;) before a quoted \"ssl\", then a} in the next server" 1 \
  $'S|b.test|1|0|0|||\nS|n.test|0|0|0|||\nT|1|0|0|0' <<EOF
server { default_type \${a; listen 8454 "ssl"; server_name b.test; $tls }
server { return 200 a}; server_name n.test; }
EOF
ngx "} inside a word (add_header X a}b;)" 1 $'S|c.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { listen 8455 ssl; add_header X a}b; server_name c.test; $tls }
EOF
ngx "\${ in the middle of a word (default_type b\${y;)" 1 $'S|d.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { default_type b\${y; listen 8456 ssl; server_name d.test; $tls }
EOF
ngx "a double-quoted \"ssl\" in a listen" 1 $'S|e.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { listen 8457 "ssl"; server_name e.test; $tls }
EOF
ngx "a single-quoted 'quic' in a listen" 0 $'S|f.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { listen 8458 'quic'; server_name f.test; $tls }
EOF
ngx "a # in the middle of a word is not a comment" 1 $'S|g.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { add_header X a#b; listen 8459 ssl; server_name g.test; $tls }
EOF
ngx "a # at the start of a word is a comment (the listen after it is not read)" 1 $'S|h.test|0|0|0|||\nT|0|0|0|0' <<'EOF'
server { listen 8080; # listen 443 ssl;
  server_name h.test; }
EOF
ngx "an escaped quote and an escaped ; are part of their words" 1 $'S|i.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { add_header X "a\\"b"; add_header Y c\\;d; listen 8460 ssl; server_name i.test; $tls }
EOF
ngx "a quoted string that runs over two lines hides the listen inside it" 1 $'S|j.test|0|0|0|||\nT|0|0|0|0' <<'EOF'
server { add_header X "line one
line two; listen 443 ssl;"; server_name j.test; }
EOF
ngx "a quoted directive name" 1 $'S|k.test|1|0|0|||\nT|1|0|0|0' <<EOF
server { "listen" 8461 ssl; server_name k.test; $tls }
EOF
ngx "a ) after a quoted word starts the next word, so the } after it is not a block end" 1 $'S|a )}|1|0|0|||\nT|1|0|0|0' <<EOF
server { server_name "a")}; listen 8470 ssl; $tls }
EOF
ngx "a ) after a quoted listen word is part of the next word, so there is no ssl" 0 $'S|p.test|0|0|0|||\nT|0|0|0|0' <<'EOF'
server { listen 8471 "x")ssl; server_name p.test; }
EOF
ngx "a quoted word followed by a letter is an error (the last field of T is 1)" 0 $'S||1|0|0|||\nT|1|0|0|1' <<'EOF'
server { listen 8472 "ssl"x; }
EOF
ngx "two quoted words with nothing between them is an error (the last field of T is 1)" 0 $'S||0|0|0|||\nT|0|0|0|1' <<'EOF'
server { listen 8473 "a""b"; }
EOF

# The independent count that must agree with the parser (and the quote refusal).
check_count() { # NAME TEXT EXPECTED-TLS EXPECTED-QUOTED
  local tls_n quoted_n
  tls_n=$(nginx_tls_listen_count "$2")
  quoted_n=$(nginx_quoted_listen_count "$2")
  printf '== counts: %s: tls=%s quoted=%s\n' "$1" "$tls_n" "$quoted_n"
  if [[ $tls_n != "$3" || $quoted_n != "$4" ]]; then
    printf 'WRONG, wanted tls=%s quoted=%s\n' "$3" "$4"
    wrong=$((wrong + 1))
  fi
}
check_count "plain ssl" 'server { listen 443 ssl; }' 1 0
check_count "no ssl" 'server { listen 80; }' 0 0
check_count "double-quoted ssl" 'server { listen 8443 "ssl"; }' 1 1
check_count "single-quoted quic" "server { listen 8443 'quic'; }" 1 1
# shellcheck disable=SC2016  # the text is an Nginx configuration, not shell: ${ must stay as it is
check_count "ssl after a hidden \${" 'server { default_type ${a; listen 443 "ssl"; }' 1 1
check_count "two listens" 'server { listen 443 ssl; listen [::]:443 ssl; listen 80; }' 2 0
check_count "a comment is not read" $'server { listen 80; # listen 443 ssl;\n}' 0 0

# --- the Quadlet normaliser ------------------------------------------------------------
qn "spaces and a tab around the =" $'Container|PodmanArgs|--privileged\nContainer|AddCapability|ALL' <<'EOF'
[Container]
PodmanArgs = --privileged
  AddCapability	= ALL
EOF
qn "a comment line ending in a backslash does not swallow the next line (ExecStartPre)" \
  $'Service||a comment line ends with a backslash\nService|ExecStartPre|/usr/bin/podman run -d --privileged -v /:/host x' <<'EOF'
[Service]
; note \
ExecStartPre=/usr/bin/podman run -d --privileged -v /:/host x
EOF
qn "a # comment ending in a backslash before PodmanArgs=--privileged" \
  $'Container||a comment line ends with a backslash\nContainer|PodmanArgs|--privileged' <<'EOF'
[Container]
# note \
PodmanArgs=--privileged
EOF
qn "a ; comment ending in a backslash before PodmanArgs=--read-only=false" \
  $'Container||a comment line ends with a backslash\nContainer|PodmanArgs|--read-only=false' <<'EOF'
[Container]
; note \
PodmanArgs=--read-only=false
EOF
qn "a Key=value line is continued by a trailing backslash" $'Container|PodmanArgs|--memory=1g  --privileged' <<'EOF'
[Container]
PodmanArgs=--memory=1g \
--privileged
EOF
qn "a comment inside a continued line is reported, and the line still joins" \
  $'Container||a comment line inside a continued line\nContainer|PodmanArgs|--memory=1g  --privileged' <<'EOF'
[Container]
PodmanArgs=--memory=1g \
# inside
--privileged
EOF
qn "a section header ending in a backslash does not join the next line" \
  $'Container||a line that is not Key=value ends with a backslash\nContainer|ExecStartPre|x' <<'EOF'
[Container]
[Service] \
ExecStartPre=x
EOF
qn "a line that is not Key=value is reported" $'Container||garbage' <<'EOF'
[Container]
garbage
EOF
qn "a Windows line ending is dropped" $'Container|Image|localhost/oc-web:x' <<<$'[Container]\r\nImage=localhost/oc-web:x\r'

printf '== %s case(s) answered wrongly\n' "$wrong"
exit "$wrong"
