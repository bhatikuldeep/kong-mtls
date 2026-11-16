#!/usr/bin/env bash
# make test-edge (bonus): an edge in front of Kong ends TLS, like a CDN or WAF, checks the client certificate and
# passes it to Kong in the X-Client-Cert header. Kong's Header Cert Auth plugin checks it again and finds the consumer.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
edge_port=${EDGE_PORT:-7443}; kong_port=${GATEWAY_PORT:-8443}
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$3', got '$2')"; }

# request <edge|kong> <cert name or "-"> <path> [extra curl args]: sets $code, $body, $headers
request() {
  local to=$1 cert=$2 path=$3 host port; shift 3
  if [ "$to" = edge ]; then host=edge.example.test port=$edge_port; else host=api.example.test port=$kong_port; fi
  local args=(-s --resolve "${host}:${port}:127.0.0.1" --cacert certs/gateway-ca.crt -D /tmp/mtls-edge-h.$$)
  [ "$cert" = "-" ] || args+=(--cert "certs/$cert.crt" --key "certs/$cert.key")
  body=$(curl "${args[@]}" "$@" "https://${host}:${port}${path}")
  headers=$(tr -d '\r' < /tmp/mtls-edge-h.$$); rm -f /tmp/mtls-edge-h.$$
  code=$(head -1 <<<"$headers" | awk '{print $2}')
}
message()  { jq -r '.message // empty' <<<"$body" 2>/dev/null || true; }
upstream() { jq -r --arg h "$1" '.headers[$h][0] // "absent"' <<<"$body"; }
resp()     { awk -v h="$(tr 'A-Z' 'a-z' <<<"$1")" -F': ' 'tolower($1)==h {print $2}' <<<"$headers"; }
# A certificate is public: anyone who has seen it can copy it into a header. This is that copy.
copied=$(jq -sRr @uri certs/partner.crt)

echo "1. Through the edge"
request edge partner /edge/orders
check "partner: 200"                                 "$code" "200"
check "the consumer is found from the header"        "$(upstream X-Consumer-Username)" "partner.example.test"
check "its tier applies (silver)"                    "$(resp RateLimit-Limit)" "5"
request edge - /edge/orders
check "no certificate: 401"                          "$code $(message)" "401 No required TLS certificate header was sent"
request edge - /edge/orders -H "X-Client-Cert: ${copied}"
check "no certificate, copied header: edge drops it, 401" "$code $(message)" "401 No required TLS certificate header was sent"
request edge rogue /edge/orders
check "self-signed certificate: the edge refuses it, 400" "$code" "400"
request edge client-a /edge/orders
check "client-a, no consumer named after its certificate: 401" "$code $(message)" "401 TLS certificate failed verification"
request edge partner /edge/strict
check "secure_source left on, no trusted_ips: 403"   "$code $(message)" "403 Forbidden"

echo "2. Around the edge, straight to Kong"
request kong - /edge/orders -H "X-Client-Cert: ${copied}"
check "copied header without the origin header: no route, 404" "$code" "404"
request kong - /edge/orders -H "X-Client-Cert: ${copied}" -H "X-Origin-Verify: demo-origin-secret"
check "copied header and a leaked origin secret: accepted as partner" "$code $(upstream X-Consumer-Username)" "200 partner.example.test"

echo
echo "${pass} passed, ${fail} failed"
echo "The last check passes on purpose: the header is only as safe as the path to Kong. See the README."
[ "$fail" -eq 0 ]
