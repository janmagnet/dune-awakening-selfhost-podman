#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

[ -f .env ] && . ./.env
[ -f runtime/generated/battlegroup.env ] && . runtime/generated/battlegroup.env

[ -f runtime/generated/image-tags.env ] && . runtime/generated/image-tags.env
source runtime/scripts/runtime-env.sh
source runtime/scripts/image-tags.sh
require_quadlet_privileges || exit 1
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

SERVER_LOGIN_PASSWORD_SECRET="$(resolve_server_login_password_secret)"
USERNAME_SERVER_LOGIN_SECRET="$(resolve_username_server_login_secret)"
LOGIN_PASSWORD_SKEW_SECONDS="$(resolve_login_password_skew_seconds)"

SERVER_TITLE="$(resolve_server_title)"
SERVER_REGION="$(resolve_server_region)"
SERVER_IP="$(resolve_server_ip)"
BATTLEGROUP_ID="$(resolve_battlegroup_id)"
if [ -n "${DUNE_FAKE_K8S_SERVICEACCOUNT_DIR:-}" ]; then
  FAKE_K8S_SERVICEACCOUNT_DIR="$DUNE_FAKE_K8S_SERVICEACCOUNT_DIR"
else
  FAKE_K8S_SERVICEACCOUNT_DIR="$PWD/runtime/generated/dune-fake-k8s-serviceaccount-director"
fi


mkdir -p runtime/director/config
mkdir -p runtime/generated/director-bundle
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

[CB_Overland_S_08]
NumExtraServers=0

[CB_Story_BanditFortress01]
NumExtraServers=0

[CB_Dungeon_ThePit]
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

if [ -s runtime/generated/director-deepdesert-dual.ini ]; then
  cat runtime/generated/director-deepdesert-dual.ini >> runtime/director/config/director_config.ini
fi

cat >> runtime/director/config/director_config.ini <<EOF

[AuthenticationConfiguration]
DefaultScheme=BackendLogin
DefaultAuthenticateScheme=BackendLogin
DefaultChallengeScheme=BackendLogin
AuthenticationScheme=BackendLogin
RequireAuthenticatedSignIn=false

[BackendLoginConfiguration]
Secret=$USERNAME_SERVER_LOGIN_SECRET
UsernameServerLoginSecret=$USERNAME_SERVER_LOGIN_SECRET
ServerLoginPasswordSecret=$SERVER_LOGIN_PASSWORD_SECRET
ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET
UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET
LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS
LoginPasswordSkew=$LOGIN_PASSWORD_SKEW_SECONDS

[AuthenticationConfiguration:BackendLoginConfiguration]
Secret=$USERNAME_SERVER_LOGIN_SECRET
UsernameServerLoginSecret=$USERNAME_SERVER_LOGIN_SECRET
ServerLoginPasswordSecret=$SERVER_LOGIN_PASSWORD_SECRET
ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET
UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET
LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS
LoginPasswordSkew=$LOGIN_PASSWORD_SKEW_SECONDS

[AuthenticationConfiguration:SchemeMap:BackendLogin]
Secret=$USERNAME_SERVER_LOGIN_SECRET
UsernameServerLoginSecret=$USERNAME_SERVER_LOGIN_SECRET
ServerLoginPasswordSecret=$SERVER_LOGIN_PASSWORD_SECRET
ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET
UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET
LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS
LoginPasswordSkew=$LOGIN_PASSWORD_SKEW_SECONDS

[AuthenticationConfiguration:SchemeMap:BackendLogin:BackendLoginConfiguration]
Secret=$USERNAME_SERVER_LOGIN_SECRET
UsernameServerLoginSecret=$USERNAME_SERVER_LOGIN_SECRET
ServerLoginPasswordSecret=$SERVER_LOGIN_PASSWORD_SECRET
ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET
UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET
LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS
LoginPasswordSkew=$LOGIN_PASSWORD_SKEW_SECONDS

[ServerAuthenticationSecrets]
UsernameServerLoginSecret="$USERNAME_SERVER_LOGIN_SECRET"
ServerLoginPasswordSecret="$SERVER_LOGIN_PASSWORD_SECRET"
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

REPO_DIR="$(pwd)"

dune_systemctl stop dune-director.service 2>/dev/null || true
engine rm -f dune-director 2>/dev/null || true

ensure_quadlet_foundation

quadlet_write dune-director.container <<EOF
# Generated by runtime/scripts/start-director.sh. Do not edit by hand.
[Unit]
Description=Dune Awakening battlegroup director

[Container]
ContainerName=dune-director
Image=${IMAGE}
Pull=never
Network=dune-net.network
PublishPort=127.0.0.1:11717:11717/tcp
Volume=${REPO_DIR}/runtime/director/config/director_config.ini:/Tools/Battlegroups/Director/BattlegroupDirector/director_config.ini:ro,z
Volume=${REPO_DIR}/runtime/generated/director-bundle:/opt/dune-director-bundle:z
Volume=${FAKE_K8S_SERVICEACCOUNT_DIR}:/run/secrets/kubernetes.io/serviceaccount:ro,z
Environment="DOTNET_BUNDLE_EXTRACT_BASE_DIR=/opt/dune-director-bundle"
Environment="KUBERNETES_SERVICE_HOST=igwo.local"
Environment="KUBERNETES_SERVICE_PORT=6443"
Environment="KUBERNETES_SERVICE_PORT_HTTPS=6443"
Environment="KUBERNETES_SERVICE_PATH=/run/secrets/kubernetes.io/serviceaccount"
Environment="BATTLEGROUP=${BATTLEGROUP_ID}"
Environment="BATTLEGROUP_DISPLAY_NAME=${BATTLEGROUP_ID}"
Environment="BATTLEGROUP_TITLE=${SERVER_TITLE}"
Environment="BATTLEGROUP_REGION_NAME=${SERVER_REGION}"
Environment="FuncomLiveServices__ServiceAuthToken=${FUNCOM_TOKEN}"
Environment="FuncomLiveServices__RmqTlsEnabled=true"
Environment="RMQ_HTTP_TOKEN_AUTH_SECRET=${RMQ_HTTP_TOKEN_AUTH_SECRET}"
Environment="AuthenticationConfiguration__DefaultScheme=BackendLogin"
Environment="AuthenticationConfiguration__DefaultAuthenticateScheme=BackendLogin"
Environment="AuthenticationConfiguration__DefaultChallengeScheme=BackendLogin"
Environment="AuthenticationConfiguration__AuthenticationScheme=BackendLogin"
Environment="AuthenticationConfiguration__RequireAuthenticatedSignIn=false"
Environment="DUNE_SERVER_LOGIN_PASSWORD_SECRET=${SERVER_LOGIN_PASSWORD_SECRET}"
Environment="DUNE_USERNAME_SERVER_LOGIN_SECRET=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="DUNE_LOGIN_PASSWORD_SKEW_SECONDS=${LOGIN_PASSWORD_SKEW_SECONDS}"
Environment="BackendLoginConfiguration__Secret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="BackendLoginConfiguration__UsernameServerLoginSecret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="BackendLoginConfiguration__ServerLoginPasswordSecret=${SERVER_LOGIN_PASSWORD_SECRET}"
Environment="BackendLoginConfiguration__ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET"
Environment="BackendLoginConfiguration__UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET"
Environment="BackendLoginConfiguration__LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS"
Environment="BackendLoginConfiguration__LoginPasswordSkew=${LOGIN_PASSWORD_SKEW_SECONDS}"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__Secret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__UsernameServerLoginSecret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__ServerLoginPasswordSecret=${SERVER_LOGIN_PASSWORD_SECRET}"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS"
Environment="AuthenticationConfiguration__BackendLoginConfiguration__LoginPasswordSkew=${LOGIN_PASSWORD_SKEW_SECONDS}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__Secret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__UsernameServerLoginSecret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__ServerLoginPasswordSecret=${SERVER_LOGIN_PASSWORD_SECRET}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__LoginPasswordSkew=${LOGIN_PASSWORD_SKEW_SECONDS}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__Secret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__UsernameServerLoginSecret=${USERNAME_SERVER_LOGIN_SECRET}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__ServerLoginPasswordSecret=${SERVER_LOGIN_PASSWORD_SECRET}"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__ServerLoginPasswordSecretEnvironmentVariable=DUNE_SERVER_LOGIN_PASSWORD_SECRET"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__UsernameServerLoginSecretEnvironmentVariable=DUNE_USERNAME_SERVER_LOGIN_SECRET"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__LoginPasswordSkewEnvironmentVariable=DUNE_LOGIN_PASSWORD_SKEW_SECONDS"
Environment="AuthenticationConfiguration__SchemeMap__BackendLogin__BackendLoginConfiguration__LoginPasswordSkew=${LOGIN_PASSWORD_SKEW_SECONDS}"
Environment="HOST_DATACENTER_ID=${SERVER_PROVIDER:-dune-docker}"
Environment="HOST_DATACENTER_IP_ADDRESS=${SERVER_IP}"
Environment="ASPNETCORE_URLS=http://0.0.0.0:11717"
Environment="DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE=false"
Environment="Database_address=dune-postgres:5432"
Environment="Database_name=dune"
Environment="Database_user=dune"
Environment="Database_password=dune"
PodmanArgs=--env=fls-apikey=${FLS_APIKEY}
Exec=--RMQGameHostname=dune-rmq-game --RMQGamePort=5672 --RMQAdminHostname=dune-rmq-admin --RMQAdminPort=5672

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

quadlet_reload
dune_systemctl start dune-director.service

sleep 12

engine ps --filter "name=dune-director" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
echo "=== director logs ==="
engine logs --tail 160 dune-director
