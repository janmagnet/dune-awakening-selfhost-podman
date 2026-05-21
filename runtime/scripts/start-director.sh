#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

[ -f .env ] && . ./.env
[ -f runtime/generated/battlegroup.env ] && . runtime/generated/battlegroup.env

[ -f runtime/generated/image-tags.env ] && . runtime/generated/image-tags.env
source runtime/scripts/runtime-env.sh
source runtime/scripts/image-tags.sh
WORLD_IMAGE_TAG="$(resolve_world_image_tag)"
IMAGE="registry.funcom.com/funcom/self-hosting/seabass-server-bg-director:${WORLD_IMAGE_TAG}"

TOKEN_FILE="runtime/secrets/funcom-token.txt"
RMQ_SECRET_FILE="runtime/secrets/rmq-http-token-auth-secret.txt"
FLS_APIKEY_FILE="runtime/secrets/fls-apikey.txt"

if [ ! -s "$TOKEN_FILE" ]; then
  echo "Missing Funcom token file: $TOKEN_FILE"
  exit 1
fi

if [ ! -s "$RMQ_SECRET_FILE" ]; then
  openssl rand -hex 32 > "$RMQ_SECRET_FILE"
  chmod 600 "$RMQ_SECRET_FILE"
fi

if [ ! -s "$FLS_APIKEY_FILE" ]; then
  openssl rand -hex 16 > "$FLS_APIKEY_FILE"
  chmod 600 "$FLS_APIKEY_FILE"
fi

FUNCOM_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
RMQ_HTTP_TOKEN_AUTH_SECRET="$(tr -d '\r\n' < "$RMQ_SECRET_FILE")"
FLS_APIKEY="$(tr -d '\r\n' < "$FLS_APIKEY_FILE")"

SERVER_TITLE="$(resolve_server_title)"
SERVER_REGION="$(resolve_server_region)"
SERVER_IP="$(resolve_server_ip)"
BATTLEGROUP_ID="$(resolve_battlegroup_id)"
if [ -n "${DUNE_FAKE_K8S_SERVICEACCOUNT_DIR:-}" ]; then
  FAKE_K8S_SERVICEACCOUNT_DIR="$DUNE_FAKE_K8S_SERVICEACCOUNT_DIR"
else
  FAKE_K8S_SERVICEACCOUNT_DIR="$PWD/runtime/generated/dune-fake-k8s-serviceaccount-director-$$"
fi

if [ "$SERVER_IP" = "auto" ]; then
  SERVER_IP="$(curl -4fsSL https://api.ipify.org || echo 127.0.0.1)"
fi

mkdir -p runtime/director/config
mkdir -p "$FAKE_K8S_SERVICEACCOUNT_DIR"

cat > runtime/director/config/director_config.ini <<'EOF'
[Battlegroup]
AuthorizationPreset=BattlegroupInternal

[InstancingModes]
Overmap=SingleServer
Survival_1=Dimension
DeepDesert_1=Dimension

[Server]
PlayerHardCap=40
ShouldUpdatePlayerCountOnFls=false
ForceLock=false
DauCap=1000000
WauCap=3360
HbsCap=1000000
AllowGroupTravel=false
ScalingResourceTarget=ServerSetScale

[Overmap]
PlayerHardCap=1000

[Survival_1]
PlayerHardCap=60
ShouldUpdatePlayerCountOnFls=true
NpeGrantDurationInMinutes=90

[DeepDesert_1]
PlayerHardCap=80
QueueFailMap=Overmap
QueueFailLocation=-32289.657183, -138433.689956, 500.000000

[CB_Dungeon_Hephaestus]
NumExtraServers=0

[CB_Dungeon_OldCarthag]
NumExtraServers=0

[CB_Ecolab_Bronze_Green_024]
NumExtraServers=0

[CB_Ecolab_Bronze_Green_089]
NumExtraServers=0

[CB_Ecolab_Bronze_Green_136]
NumExtraServers=0

[CB_Ecolab_Bronze_Green_152]
NumExtraServers=0

[CB_Ecolab_Bronze_Green_195]
NumExtraServers=0

[CB_Overland_M_01]
NumExtraServers=0

[CB_Overland_S_04]
NumExtraServers=0

[CB_Overland_S_05]
NumExtraServers=0

[CB_Overland_S_06]
NumExtraServers=0

[CB_Overland_S_07]
NumExtraServers=0

[CB_Story_BanditFortress01]
NumExtraServers=0

[SH_Arrakeen]
PlayerHardCap=80
ShouldUpdatePlayerCountOnFls=false
AllowGroupTravel=false
NumExtraServers=0
MinServers=0

[SH_HarkoVillage]
PlayerHardCap=80
ShouldUpdatePlayerCountOnFls=false
AllowGroupTravel=false
NumExtraServers=0
MinServers=0

[Story_ArtOfKanly]
PlayerHardCap=30
ShouldUpdatePlayerCountOnFls=false
AllowGroupTravel=false
NumExtraServers=0

[Story_Faction_Outpost_Atre]
PlayerHardCap=1
ShouldUpdatePlayerCountOnFls=false
AllowGroupTravel=false
NumExtraServers=0

[Story_Faction_Outpost_Hark]
PlayerHardCap=1
ShouldUpdatePlayerCountOnFls=false
AllowGroupTravel=false
NumExtraServers=0

[Story_HeighlinerDungeon]
PlayerHardCap=1
ShouldUpdatePlayerCountOnFls=false
AllowGroupTravel=false
NumExtraServers=0
EOF

cat > "$FAKE_K8S_SERVICEACCOUNT_DIR/namespace" <<'EOF'
funcom-seabass-dune-docker
EOF

cat > "$FAKE_K8S_SERVICEACCOUNT_DIR/token" <<'EOF'
fake-token
EOF

# Same intentional trick as TextRouter for now:
# invalid CA makes IGWO init fail non-fatally instead of trying to call a missing API server.
: > "$FAKE_K8S_SERVICEACCOUNT_DIR/ca.crt"

chmod -R 755 "$FAKE_K8S_SERVICEACCOUNT_DIR"
chmod -R 755 runtime/director/config

docker network create dune-net 2>/dev/null || true
docker rm -f dune-director 2>/dev/null || true

docker run -d \
  --name dune-director \
  --network dune-net \
  --restart unless-stopped \
  -p 127.0.0.1:11717:11717/tcp \
  -v "$PWD/runtime/director/config/director_config.ini:/Tools/Battlegroups/Director/BattlegroupDirector/director_config.ini:ro" \
  -v "$FAKE_K8S_SERVICEACCOUNT_DIR:/run/secrets/kubernetes.io/serviceaccount:ro" \
  -e "KUBERNETES_SERVICE_HOST=igwo.local" \
  -e "KUBERNETES_SERVICE_PORT=6443" \
  -e "KUBERNETES_SERVICE_PORT_HTTPS=6443" \
  -e "KUBERNETES_SERVICE_PATH=/run/secrets/kubernetes.io/serviceaccount" \
  -e "BATTLEGROUP=$BATTLEGROUP_ID" \
  -e "BATTLEGROUP_DISPLAY_NAME=$BATTLEGROUP_ID" \
  -e "BATTLEGROUP_TITLE=$SERVER_TITLE" \
  -e "BATTLEGROUP_REGION_NAME=$SERVER_REGION" \
  -e "FuncomLiveServices__ServiceAuthToken=$FUNCOM_TOKEN" \
  -e "FuncomLiveServices__RmqTlsEnabled=true" \
  -e "RMQ_HTTP_TOKEN_AUTH_SECRET=$RMQ_HTTP_TOKEN_AUTH_SECRET" \
  -e "fls-apikey=$FLS_APIKEY" \
  -e "HOST_DATACENTER_ID=${SERVER_PROVIDER:-dune-docker}" \
  -e "HOST_DATACENTER_IP_ADDRESS=$SERVER_IP" \
  -e "ASPNETCORE_URLS=http://0.0.0.0:11717" \
  -e "DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE=false" \
  -e "Database_address=dune-postgres:5432" \
  -e "Database_name=dune" \
  -e "Database_user=dune" \
  -e "Database_password=dune" \
  "$IMAGE" \
  --RMQGameHostname=dune-rmq-game \
  --RMQGamePort=5672 \
  --RMQAdminHostname=dune-rmq-admin \
  --RMQAdminPort=5672

sleep 12

docker ps --filter "name=dune-director" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "=== director logs ==="
docker logs --tail 160 dune-director
