#!/usr/bin/env bash
# make clean: remove everything this repo created: containers, the Konnect control plane (with its
# config and data plane certificate), the certificates and the generated decK file.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env: nothing to clean"; exit 0; }
set -a; source .env; set +a
export KONGCTL_DEFAULT_KONNECT_PAT="$KONNECT_TOKEN"   # an environment variable, never a command-line flag

docker compose --env-file .env down --volumes --remove-orphans 2>/dev/null || true

if [ -f certs/dp.crt ] && [ -f kong/certs.yaml ]; then
  kongctl plan --mode delete -f konnect/control-plane.yaml --base-dir . \
    --region "$KONNECT_REGION" --output-file plan.json
  kongctl delete --plan plan.json --auto-approve --region "$KONNECT_REGION"
  rm -f plan.json
fi

rm -rf certs kong/certs.yaml
for k in KONG_CLUSTER_CONTROL_PLANE KONG_CLUSTER_SERVER_NAME KONG_CLUSTER_TELEMETRY_ENDPOINT KONG_CLUSTER_TELEMETRY_SERVER_NAME; do
  sed -i.bak "s#^$k=.*#$k=#" .env && rm -f .env.bak
done
echo "Clean: containers, the Konnect control plane and the certificates are gone (.env keeps your token)"
