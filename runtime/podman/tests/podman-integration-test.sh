#!/usr/bin/env bash
# Runs the docker shim against real rootful Podman. Run as root on a disposable
# host (CI runner, VM): it builds dune-orchestrator:dev and runs the
# dune-orchestrator container under a throwaway Compose project.
set -euo pipefail

cd "$(dirname "$0")/../../.."
[ "$(id -u)" -eq 0 ] || {
  echo "Run as root." >&2
  exit 1
}
command -v podman >/dev/null 2>&1 || {
  echo "podman is required." >&2
  exit 1
}

PROJECT="dunepodmantest"
export COMPOSE_PROJECT_NAME="$PROJECT"
export SERVER_IP=127.0.0.1 SERVER_TITLE="Podman shim test" SERVER_REGION=Europe
# shellcheck source=runtime/podman/path.sh
. runtime/podman/path.sh

if podman container exists dune-orchestrator \
  && [ "$(podman inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' dune-orchestrator)" != "$PROJECT" ] \
  && [ "${DUNE_PODMAN_TEST_FORCE:-0}" != "1" ]; then
  echo "A dune-orchestrator container from a real installation exists; refusing to replace it." >&2
  echo "Set DUNE_PODMAN_TEST_FORCE=1 to run anyway on a disposable host." >&2
  exit 1
fi

cleanup() {
  podman rm --force --time 0 dune-orchestrator dune-shim-restore-probe >/dev/null 2>&1 || true
  if [ "$owner_check_started" = 1 ]; then
    podman rm --force --time 0 dune-autoscaler dune-director dune-postgres >/dev/null 2>&1 || true
  fi
  [ -z "$owner_repo" ] || rm -rf "$owner_repo"
  for volume in dune-server dune-steam dune-cache dune-generated dune-work; do
    podman volume rm --force "${PROJECT}_${volume}" >/dev/null 2>&1 || true
  done
  podman rmi --force localhost/dune-shim-prune-probe:1 >/dev/null 2>&1 || true
  podman volume rm dune-shim-volume-probe >/dev/null 2>&1 || true
}
owner_check_started=0
owner_repo=""
trap cleanup EXIT

systemctl start podman.socket >/dev/null 2>&1 || true

failures=0
check() {
  local description="$1"
  shift
  if "$@" >/dev/null; then
    echo "ok   $description"
  else
    echo "FAIL $description" >&2
    failures=$((failures + 1))
  fi
}
running_services() { docker compose ps --status running --services; }

echo "Building and starting the orchestrator through the shim..."
docker compose up -d --build orchestrator
for _ in $(seq 1 60); do
  [ "$(running_services)" = "orchestrator" ] && break
  sleep 2
done

check "compose ps reports the running orchestrator" test "$(running_services)" = "orchestrator"
check "compose exec runs in the orchestrator" test "$(docker compose exec -T orchestrator id -un)" = "root"
check "the docker CLI inside the orchestrator reaches Podman" \
  sh -c 'docker compose exec -T orchestrator docker info --format "{{.ServerVersion}}" | grep -q .'
check "the orchestrator health check passes" podman healthcheck run dune-orchestrator
# shellcheck disable=SC2016 # Expanded by the inner bash.
check "upstream resolves the project from the emulated volumes and labels" \
  test "$(env -u COMPOSE_PROJECT_NAME bash -c '. runtime/scripts/compose-project.sh; dune_resolve_compose_project_name "$PWD"')" = "$PROJECT"
check "a non-root container that mounts docker.sock reaches Podman" \
  sh -c 'docker run --rm --user 1000:1000 --entrypoint docker -v /var/run/docker.sock:/var/run/docker.sock dune-orchestrator:dev ps --filter "name=^/dune-orchestrator\$" --format "{{.Names}}" | grep -qx dune-orchestrator'
# The autoscaler and the Coriolis coordinator start containers that mount
# docker.sock from inside their own container (for example when a game farm
# restart recreates the autoscaler).
nested_ps='docker run --rm --entrypoint docker -v /var/run/docker.sock:/var/run/docker.sock dune-orchestrator:dev ps --filter name=^/dune-orchestrator$ --format {{.Names}}'
check "a container started from inside a stack container reaches Podman" \
  sh -c "docker run --rm --user 1000:1000 --entrypoint bash -v /var/run/docker.sock:/var/run/docker.sock dune-orchestrator:dev -lc '$nested_ps' | grep -qx dune-orchestrator"

started="$(docker inspect -f '{{.State.StartedAt}}' dune-orchestrator)"
check "StartedAt uses Docker's RFC 3339 form ($started)" grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9.]+Z' <<<"$started"
check "date parses StartedAt" date -d "$started" +%s
check "logs --since accepts StartedAt" docker logs --since "$started" dune-orchestrator

container_image="$(docker inspect --format '{{.Image}}' dune-orchestrator)"
check "a container's image ID matches image inspect ($container_image)" \
  test "$container_image" = "$(docker image inspect --format '{{.Id}}' dune-orchestrator:dev)"
check "the image ID matches image ls --no-trunc" \
  sh -c "docker image ls --no-trunc --format '{{.ID}}' | grep -qx '$container_image'"

podman tag dune-orchestrator:dev localhost/dune-shim-prune-probe:1
docker builder prune --force --all >/dev/null
check "builder prune keeps tagged images" podman image exists localhost/dune-shim-prune-probe:1
check "system df reports a Build Cache row" sh -c 'docker system df --format "{{.Type}}|{{.Reclaimable}}" | grep -q "^Build Cache|"'
check "upstream storage diagnostics run on Podman" runtime/scripts/storage.sh diagnostics

# start-postgres.sh creates dune-postgres-data on every start.
docker volume create dune-shim-volume-probe >/dev/null
check "volume create returns an existing volume like Docker" \
  test "$(docker volume create dune-shim-volume-probe)" = "dune-shim-volume-probe"
podman volume rm dune-shim-volume-probe >/dev/null

docker create --name dune-shim-restore-probe --restart unless-stopped --entrypoint sleep dune-orchestrator:dev 600 >/dev/null
runtime/podman/restore-containers.sh >/dev/null
check "boot restore starts unless-stopped containers" \
  test "$(podman inspect --format '{{.State.Status}}' dune-shim-restore-probe)" = "running"
podman stop --time 0 dune-shim-restore-probe >/dev/null
runtime/podman/restore-containers.sh >/dev/null
check "boot restore leaves operator-stopped containers alone" \
  test "$(podman inspect --format '{{.State.Status}}' dune-shim-restore-probe)" = "exited"
docker rm -f dune-shim-missing dune-shim-restore-probe >/dev/null 2>&1 || true
check "rm -f removes existing containers when another named one is missing" \
  sh -c '! podman container exists dune-shim-restore-probe'

# A checkout cloned by a regular user. Upstream runs the autoscaler as the owner
# of the checkout, while dune init, which runs as root here, gives runtime/ to
# root (DUNE_HOST_UID=0); host setup makes root the owner so that both agree.
if podman container exists dune-autoscaler || podman container exists dune-director \
  || podman container exists dune-postgres; then
  echo "SKIP the autoscaler ownership checks: a dune-autoscaler, dune-director or dune-postgres container exists."
else
  owner_repo="$(mktemp -d)"
  mkdir -p "$owner_repo/runtime" "$owner_repo/.git"
  cp -a runtime/scripts runtime/podman "$owner_repo/runtime/"
  printf 'SERVER_IP=127.0.0.1\nDUNE_HOST_UID=1000\nDUNE_HOST_GID=1000\n' >"$owner_repo/.env"
  chown -R 1000:1000 "$owner_repo"
  # shellcheck source=runtime/podman/lib/owner.sh
  . runtime/podman/lib/owner.sh
  dune_podman_make_root_owner "$owner_repo" >/dev/null
  check "host setup makes root the owner of a user's checkout" \
    test "$(stat -c '%u:%g' "$owner_repo" "$owner_repo/.git" | sort -u)" = "0:0"
  check "host setup points DUNE_HOST_UID and DUNE_HOST_GID at root" \
    test "$(grep -c -x -E 'DUNE_HOST_[UG]ID=0' "$owner_repo/.env")" = 2

  owner_check_started=1
  podman run -d --name dune-director --entrypoint sleep dune-orchestrator:dev infinity >/dev/null
  podman run -d --name dune-postgres --entrypoint sleep dune-orchestrator:dev infinity >/dev/null
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  check "upstream's dune init steps start the autoscaler in that checkout" \
    bash -c 'cd "$1" && export DUNE_HOST_UID=0 DUNE_HOST_GID=0 \
      && runtime/scripts/repair-host-runtime-permissions.sh \
      && DUNE_RUNTIME_PERMISSIONS_REPAIRED=1 runtime/scripts/start-autoscaler.sh' _ "$owner_repo"
  check "the autoscaler runs as root" test "$(podman inspect -f '{{.Config.User}}' dune-autoscaler 2>/dev/null)" = "0:0"
  # The autoscaler creates its state files when it starts; this is the step
  # that failed with Permission denied.
  for _ in $(seq 1 30); do
    [ ! -e "$owner_repo/runtime/generated/autoscaler-director-heal.tsv" ] || break
    sleep 1
  done
  check "the autoscaler can write its runtime files" test -e "$owner_repo/runtime/generated/autoscaler-director-heal.tsv"
  podman rm --force --time 0 dune-autoscaler dune-director dune-postgres >/dev/null
  owner_check_started=0
fi

docker compose down >/dev/null 2>&1
check "compose down removes the orchestrator" sh -c '! podman container exists dune-orchestrator'
check "compose down keeps the volumes" podman volume exists "${PROJECT}_dune-server"

if [ "$failures" -gt 0 ]; then
  echo "$failures Podman integration check(s) failed." >&2
  exit 1
fi
echo "Podman integration tests passed."
