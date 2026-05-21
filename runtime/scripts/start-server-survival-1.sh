#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

[ -f .env ] && . ./.env
[ -f runtime/generated/battlegroup.env ] && . runtime/generated/battlegroup.env

[ -f runtime/generated/image-tags.env ] && . runtime/generated/image-tags.env
source runtime/scripts/runtime-env.sh
source runtime/scripts/image-tags.sh
WORLD_IMAGE_TAG="$(resolve_world_image_tag)"
IMAGE="registry.funcom.com/funcom/self-hosting/seabass-server:${WORLD_IMAGE_TAG}"

TOKEN_FILE="runtime/secrets/funcom-token.txt"
RMQ_SECRET_FILE="runtime/secrets/rmq-http-token-auth-secret.txt"
FLS_APIKEY_FILE="runtime/secrets/fls-apikey.txt"

FUNCOM_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
RMQ_HTTP_TOKEN_AUTH_SECRET="$(tr -d '\r\n' < "$RMQ_SECRET_FILE")"
FLS_APIKEY="$(tr -d '\r\n' < "$FLS_APIKEY_FILE")"

SERVER_TITLE="$(resolve_server_title)"
SERVER_REGION="$(resolve_server_region)"
SERVER_IP="$(resolve_server_ip)"
BATTLEGROUP_ID="$(resolve_battlegroup_id)"
MEMORY="${DUNE_MEMORY_SURVIVAL_1:-12g}"
PARTITION_ID="${DUNE_SURVIVAL_PARTITION_ID:-1}"
if [ -n "${DUNE_FAKE_K8S_SERVICEACCOUNT_DIR:-}" ]; then
  FAKE_K8S_SERVICEACCOUNT_DIR="$DUNE_FAKE_K8S_SERVICEACCOUNT_DIR"
else
  FAKE_K8S_SERVICEACCOUNT_DIR="$PWD/runtime/generated/dune-fake-k8s-serviceaccount-survival-1-$$"
fi

if [ "$SERVER_IP" = "auto" ]; then
  SERVER_IP="$(curl -4fsSL https://api.ipify.org || echo 127.0.0.1)"
fi

# MultiHome should be an IP actually assigned to the VPS network interface.
MULTIHOME_IP="${SERVER_BIND_IP:-auto}"
if [ "$MULTIHOME_IP" = "auto" ]; then
  MULTIHOME_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi

mkdir -p runtime/game/survival-1/Saved
mkdir -p runtime/game/artifacts
mkdir -p "$FAKE_K8S_SERVICEACCOUNT_DIR"
mkdir -p runtime/container
python3 runtime/scripts/usersettings.py materialize Survival_1 "$PWD/runtime/game/survival-1/Saved" "$PARTITION_ID"

cat > "$FAKE_K8S_SERVICEACCOUNT_DIR/namespace" <<'EOF'
funcom-seabass-dune-docker
EOF
cat > "$FAKE_K8S_SERVICEACCOUNT_DIR/token" <<'EOF'
fake-token
EOF
: > "$FAKE_K8S_SERVICEACCOUNT_DIR/ca.crt"
chmod -R 755 "$FAKE_K8S_SERVICEACCOUNT_DIR"

mapfile -t SIETCH_RUNTIME_ARGS < <(runtime/scripts/sietches.sh runtime-args Survival_1 "$PARTITION_ID" 2>/dev/null || true)

docker rm -f dune-server-survival-1 2>/dev/null || true

docker run -d \
  --name dune-server-survival-1 \
  --network host \
  --restart unless-stopped \
  --privileged \
  --cap-add SYS_ADMIN \
  --security-opt seccomp=unconfined \
  --memory "$MEMORY" \
  --memory-reservation "$MEMORY" \
  -v "$PWD/runtime/game/survival-1/Saved:/home/dune/server/DuneSandbox/Saved" \
  -v "$PWD/runtime/game/artifacts:/home/dune/artifacts" \
  -v "$PWD/runtime/container:/opt/dune-local:ro" \
  -v "$FAKE_K8S_SERVICEACCOUNT_DIR:/run/secrets/kubernetes.io/serviceaccount:ro" \
  -e "POD_UID=docker-survival-1" \
  -e "POD_NAME=${BATTLEGROUP_ID}-sg-survival-1-pod-1" \
  -e "POD_IP=$MULTIHOME_IP" \
  -e "EXTERNAL_ADDRESS_OVERRIDE=$SERVER_IP" \
  -e "NODE_NAME=$(hostname)" \
  -e "SERVER_INDEX=1" \
  -e "FARM_NAME=$BATTLEGROUP_ID" \
  -e "BATTLEGROUP_NAME=$BATTLEGROUP_ID" \
  -e "BATTLEGROUP=$BATTLEGROUP_ID" \
  -e "BATTLEGROUP_DISPLAY_NAME=$BATTLEGROUP_ID" \
  -e "BATTLEGROUP_TITLE=$SERVER_TITLE" \
  -e "FC_CRASHREPORTER_LOGS=/home/dune/server/DuneSandbox/Saved/CrashReporterLogs" \
  -e "FuncomLiveServices__ServiceAuthToken=$FUNCOM_TOKEN" \
  -e "FuncomLiveServices__RmqTlsEnabled=true" \
  -e "RMQ_HTTP_TOKEN_AUTH_SECRET=$RMQ_HTTP_TOKEN_AUTH_SECRET" \
  -e "fls-apikey=$FLS_APIKEY" \
  "$IMAGE" \
  /opt/dune-local/run-server.sh \
  Survival_1 \
  "-FarmRegion=$SERVER_REGION" \
  "-ini:engine:[FuncomLiveServices]:ServiceAuthToken=$FUNCOM_TOKEN" \
  -RMQGameTlsEnabled=true \
  "ServerName=$BATTLEGROUP_ID" \
  "-MultiHome=$MULTIHOME_IP" \
  -DatabaseName=dune \
  -DatabaseHost=127.0.0.1:15432 \
  -DatabaseUser=dune \
  -DatabasePassword=dune \
  "-PartitionIndex=$PARTITION_ID" \
  "-ini:engine:[URL]:Port=7778" \
  "-ini:engine:[URL]:IGWPort=7888" \
  -battlegroup-director-url=127.0.0.1:11717 \
  --RMQGameHostname=127.0.0.1 \
  --RMQGamePort=31982 \
  --RMQAdminHostname=127.0.0.1 \
  --RMQAdminPort=32573 \
  "${SIETCH_RUNTIME_ARGS[@]}" \
  -stdout \
  -FullStdOutLogOutput

sleep 20

docker ps --filter "name=dune-server-survival-1" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "=== survival logs ==="
docker logs --tail 180 dune-server-survival-1

runtime/scripts/publish-sietch-overrides.sh restart >/dev/null 2>&1 || true
