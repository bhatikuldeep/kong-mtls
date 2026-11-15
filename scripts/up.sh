#!/usr/bin/env bash
# make up: everything the demo needs, in order. Safe to run again: it only changes what's missing.
set -euo pipefail
cd "$(dirname "$0")/.."
set_env() { sed -i.bak "s#^$1=.*#$1=$2#" .env && rm -f .env.bak; }

# 1. Tools, Docker and the Konnect token
for tool in kongctl deck jq openssl curl; do
  command -v "$tool" >/dev/null || { echo "$tool not found: install mise, then run 'mise install' here"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker is not running"; exit 1; }
[ -f .env ] || cp .env.example .env
set -a; source .env; set +a
[ -n "${KONNECT_TOKEN:-}" ] || { echo "Set KONNECT_TOKEN in .env (a Konnect personal access token)"; exit 1; }
api="https://${KONNECT_REGION}.api.konghq.com"
# The token goes to the tools as environment variables and to curl on stdin, never on a command line
export KONGCTL_DEFAULT_KONNECT_PAT="$KONNECT_TOKEN"
konnect() { curl -sf -H @- "${api}$1" <<<"Authorization: Bearer ${KONNECT_TOKEN}"; }

# 2. Certificates, and kong/certs.yaml that loads the CA and the gateway's server certificate
bash scripts/certs.sh

# 3. Konnect: the control plane, the data plane certificate and the gateway config. Show the changes, then apply.
#    It only creates and updates (kongctl apply mode); make clean deletes.
#    On a re-run, first note whether the gateway config will change and which config hash Konnect expects now,
#    so step 6 can wait for the new config instead of accepting the old one.
before=""; changing=yes
old_id=$(konnect "/v2/control-planes?filter%5Bname%5D%5Beq%5D=mtls-identity" | jq -r '.data[0].id // empty')
if [ -n "$old_id" ]; then
  before=$(konnect "/v2/control-planes/${old_id}/expected-config-hash" | jq -r '.expected_hash // empty' || true)
  DECK_KONNECT_TOKEN="$KONNECT_TOKEN" deck gateway diff kong/certs.yaml kong/kong.yaml \
    --konnect-addr "$api" --konnect-control-plane-name mtls-identity 2>&1 \
    | grep -E "^ *(Created|Updated): 0$" | wc -l | grep -q 2 && changing=no   # make up never deletes
fi
kongctl plan --mode apply -f konnect/control-plane.yaml --base-dir . \
  --region "$KONNECT_REGION" --output-file plan.json
kongctl apply --plan plan.json --auto-approve --region "$KONNECT_REGION"
rm -f plan.json

# 4. The control plane's connection details, for the data plane
cp=$(konnect "/v2/control-planes?filter%5Bname%5D%5Beq%5D=mtls-identity" | jq -c '.data[0]')
[ "$cp" != "null" ] || { echo "control plane mtls-identity not found in Konnect"; exit 1; }
cp_host=$(jq -r '.config.control_plane_endpoint' <<<"$cp" | sed 's#^https://##')
tp_host=$(jq -r '.config.telemetry_endpoint' <<<"$cp" | sed 's#^https://##')
set_env KONG_CLUSTER_CONTROL_PLANE "${cp_host}:443"
set_env KONG_CLUSTER_SERVER_NAME "${cp_host}"
set_env KONG_CLUSTER_TELEMETRY_ENDPOINT "${tp_host}:443"
set_env KONG_CLUSTER_TELEMETRY_SERVER_NAME "${tp_host}"

# 5. The data plane and the echo upstream. Re-read .env first: values loaded in step 1 are stale.
set -a; source .env; set +a
docker compose --env-file .env up -d --wait

# 6. Wait until a data plane node runs the configuration Konnect expects. On a re-run the old
#    configuration still answers requests, so a route check alone would say "ready" too early.
cp_id=$(jq -r '.id' <<<"$cp")
for _ in $(seq 1 60); do
  want=$(konnect "/v2/control-planes/${cp_id}/expected-config-hash" | jq -r '.expected_hash // empty' || true)
  if [ "$changing" = yes ] && [ "$want" = "$before" ]; then sleep 2; continue; fi   # Konnect hasn't updated yet
  if [ -n "$want" ] && konnect "/v2/control-planes/${cp_id}/nodes" \
      | jq -e --arg h "$want" 'any(.items[]?; .config_hash == $h)' >/dev/null 2>&1; then
    echo "Ready: run 'make test'"; exit 0
  fi
  sleep 2
done
echo "The data plane has not loaded the configuration after 120 s: check 'docker compose logs kong'"; exit 1
