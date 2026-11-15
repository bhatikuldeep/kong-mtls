#!/usr/bin/env bash
# make test: one request per case, checking the status code, the message and the headers the upstream received.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
port=${GATEWAY_PORT:-8443}
url="https://api.example.test:${port}"
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$3', got '$2')"; }

# call <cert name or "-"> <path> [extra curl args]: sets $code, $body, $headers
call() {
  local cert=$1 path=$2; shift 2
  local args=(-s --resolve "api.example.test:${port}:127.0.0.1" --cacert certs/gateway-ca.crt -D /tmp/mtls-h.$$)
  [ "$cert" = "-" ] || args+=(--cert "certs/$cert.crt" --key "certs/$cert.key")
  body=$(curl "${args[@]}" "$@" "${url}${path}")
  headers=$(tr -d '\r' < /tmp/mtls-h.$$); rm -f /tmp/mtls-h.$$
  code=$(head -1 <<<"$headers" | awk '{print $2}')
}
field()    { jq -r "$1" <<<"$body" 2>/dev/null || echo "(not JSON)"; }   # a field of a JSON reply
upstream() { jq -r --arg h "$1" '.headers[$h][0] // "absent"' <<<"$body"; }   # a header as the upstream saw it
resp()     { awk -v h="$(tr 'A-Z' 'a-z' <<<"$1")" -F': ' 'tolower($1)==h {print $2}' <<<"$headers"; }

# Rate limits count per minute. If earlier runs used up this minute's calls for gold (10) or silver (5),
# wait for the next window, so every run checks the same things.
wait=0
for c in client-a:6 client-b:3; do
  call "${c%%:*}" /orders
  left=$(resp RateLimit-Remaining); reset=$(resp RateLimit-Reset)
  [ "${left:-0}" -lt "${c##*:}" ] && [ "${reset:-0}" -gt "$wait" ] && wait=$reset
done
[ "$wait" -gt 0 ] && { echo "Waiting ${wait}s for a fresh rate-limit window"; sleep $((wait + 1)); }

echo "1. Who gets in"
call - /orders
check "no certificate: 401"                      "$code $(jq -r .message <<<"$body")" "401 No required TLS certificate was sent"
call rogue /orders
check "self-signed, same name as client-a: 401" "$code $(jq -r .message <<<"$body")" "401 TLS certificate failed verification"
call client-d /orders
check "trusted CA, no consumer mapped: 401"      "$code $(jq -r .message <<<"$body")" "401 TLS certificate failed verification"
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${port}/orders")
check "another hostname (SNI): no route, 404"    "$code" "404"

echo "2. What the upstream learns about the caller"
call client-a /orders -H 'X-Consumer-Username: admin'
check "client-a: 200"                           "$code" "200"
check "X-Consumer-Username (spoofed admin replaced)"                      "$(upstream X-Consumer-Username)" "client-a"
check "X-Consumer-Custom-Id"                     "$(upstream X-Consumer-Custom-Id)" "app-1001"

echo "3. Limits per tier"
check "gold limit"                               "$(resp RateLimit-Limit)" "10"
call client-b /orders
check "silver limit"                             "$(resp RateLimit-Limit)" "5"
codes=""; limit=""
for _ in 1 2 3 4; do
  call client-c /orders
  [ -n "$limit" ] || limit=$(resp RateLimit-Limit)   # first answer, 200 or 429, so the count never varies
  codes="$codes $code"
  [ "$code" = "429" ] && break
done
check "bronze limit"                             "$limit" "3"
check "bronze: 429 within 4 calls ($codes )"     "$code $(jq -r .message <<<"$body")" "429 API rate limit exceeded"
call client-a /orders
check "gold client unaffected by bronze's limit" "$code" "200"

echo "4. Access per tier"
call client-b /reports
check "silver refused on /reports"                  "$code" "403"
call client-c /reports
check "bronze refused on /reports"                  "$code" "403"
call client-a /reports
check "gold allowed on /reports"                    "$code" "200"
check "X-Consumer-Groups (set by the ACL plugin)" "$(upstream X-Consumer-Groups)" "gold"

echo "5. Kong to the backend (Part 2)"
call - /inventory
check "Kong presents its certificate: 200"          "$code" "200"
check "the backend saw Kong's certificate"          "$(field .client_certificate)" "CN=kong-gateway"
check "no client identity sent"                    "$code consumer='$(field .consumer)'" "200 consumer=''"
call - /inventory -H 'X-Consumer-Username: admin'
check "unauthenticated route passes a client-set header" "$(field .consumer)" "admin"
code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${BACKEND_PORT:-9443}/")
check "the backend directly, no certificate: 400"   "$code" "400"
call client-a /inventory/whoami
check "bonus: client-a on /inventory/whoami: 200"   "$code" "200"
check "bonus: the backend learns the consumer"      "$(field .consumer)" "client-a"
check "bonus: still over Kong's certificate"        "$(field .client_certificate)" "CN=kong-gateway"
call - /inventory/whoami
check "bonus: no client certificate: 401"           "$code" "401"

echo "6. Konnect matches the files (no drift)"
cp_name=mtls-identity
diff_out=$(DECK_KONNECT_TOKEN="$KONNECT_TOKEN" deck gateway diff kong/certs.yaml kong/kong.yaml \
  --konnect-addr "https://${KONNECT_REGION}.api.konghq.com" --konnect-control-plane-name "$cp_name" 2>&1 | grep -E "^ *(Created|Updated|Deleted):" | tr -s " " | xargs)
check "deck gateway diff" "$diff_out" "Created: 0 Updated: 0 Deleted: 0"

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
