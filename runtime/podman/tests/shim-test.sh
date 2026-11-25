#!/usr/bin/env bash
# Unit tests for the Podman docker shim (runtime/podman/shim/docker). A fake
# podman records every invocation, so no container engine is needed.
set -euo pipefail

cd "$(dirname "$0")/../../.."
ROOT_DIR="$(pwd -P)"
SHIM="$ROOT_DIR/runtime/podman/shim/docker"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
LOG="$WORK/podman.log"
SOCKET="$WORK/podman.sock"
mkdir -p "$FAKE_BIN"

# The fake podman logs each argument as [arg] and answers the queries the shim makes.
cat >"$FAKE_BIN/podman" <<'EOF'
#!/usr/bin/env bash
printf '[%s]' "$@" >>"$FAKE_PODMAN_LOG"
printf '\n' >>"$FAKE_PODMAN_LOG"
args="$*"
case "$args" in
  --remote\ --url\ *) shift 3; args="$*" ;;
esac
case "$args" in
  "image inspect --format {{.Id}} dune-orchestrator:dev")
    [ "${FAKE_IMAGE_PRESENT:-1}" = 1 ] || exit 125
    echo "sha256:fakeimage"
    ;;
  "inspect --format {{.State.Status}} dune-orchestrator")
    [ -n "${FAKE_ORCH_STATE:-}" ] || exit 125
    echo "$FAKE_ORCH_STATE"
    ;;
  "inspect --format {{index .Config.Labels \"com.docker.compose.config-hash\"}}|{{.State.Status}} dune-orchestrator")
    [ -n "${FAKE_ORCH_HASH_STATE:-}" ] || exit 125
    echo "$FAKE_ORCH_HASH_STATE"
    ;;
  "volume exists "*) exit 1 ;;
  *missing-container) exit 125 ;;
  "system df"*)
    printf 'Images|1GB (50%%)\nContainers|0B (0%%)\nLocal Volumes|0B (0%%)\n'
    ;;
esac
exit 0
EOF
chmod 755 "$FAKE_BIN/podman"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCKET"
SOCKET_GID="$(stat -c '%g' "$SOCKET")"

export FAKE_PODMAN_LOG="$LOG"
export DUNE_PODMAN_SOCKET="$SOCKET"
export DUNE_PODMAN_ROOTLESS=1
export PATH="$FAKE_BIN:$PATH"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
reset_log() { : >"$LOG"; }
assert_logged() {
  grep -qF -- "$1" "$LOG" || fail "$2: expected podman call containing $1; got: $(cat "$LOG")"
}
assert_not_logged() {
  if grep -qF -- "$1" "$LOG"; then fail "$2: unexpected podman call containing $1"; fi
}

reset_log
"$SHIM" ps --filter 'name=^/dune-postgres$' --format '{{.Names}}'
assert_logged "[ps][--filter][name=^/dune-postgres\$][--format][{{.Names}}]" "plain commands pass through"

reset_log
"$SHIM" run -d --name x --user 1000:1000 -v /var/run/docker.sock:/var/run/docker.sock -v /srv:/repo img cmd
assert_logged "[run][--group-add][$SOCKET_GID][-d][--name][x][--user][1000:1000][-v][$SOCKET:/var/run/docker.sock][-v][/srv:/repo][img][cmd]" \
  "docker.sock mounts use the Podman socket and its group"

reset_log
"$SHIM" container run --rm --volume=/run/docker.sock:/var/run/docker.sock:ro img
assert_logged "[container][run][--group-add][$SOCKET_GID][--rm][--volume=$SOCKET:/var/run/docker.sock:ro][img]" \
  "long volume form is rewritten"

reset_log
"$SHIM" run --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock img
assert_logged "[--mount][type=bind,source=$SOCKET,target=/var/run/docker.sock]" "--mount sources are rewritten"

reset_log
"$SHIM" run -d -v /srv/data:/data img
assert_not_logged "[--group-add]" "runs without the socket keep their groups"

reset_log
"$SHIM" inspect -f '{{.State.Running}}|{{.State.StartedAt}}' c1
assert_logged '[inspect][-f][{{.State.Running}}|{{(.State.StartedAt.UTC.Format "2006-01-02T15:04:05.999999999Z07:00")}}][c1]' \
  "StartedAt is printed in Docker's RFC 3339 form"

reset_log
"$SHIM" container inspect --format='finished={{.State.FinishedAt}}' c1
assert_logged '[container][inspect][--format=finished={{(.State.FinishedAt.UTC.Format "2006-01-02T15:04:05.999999999Z07:00")}}][c1]' \
  "FinishedAt is rewritten in the --format= form"

reset_log
"$SHIM" inspect --format '{{.Image}} {{.Config.Image}} {{.Id}}' c1
assert_logged '[inspect][--format][{{(printf "sha256:%s" .Image)}} {{.Config.Image}} {{.Id}}][c1]' \
  "container image IDs use Docker's sha256: form; names and container IDs are untouched"

reset_log
"$SHIM" image inspect --format '{{.Id}}' img
assert_logged '[image][inspect][--format][{{(printf "sha256:%s" .ID)}}][img]' "image IDs use Docker's sha256: form"

reset_log
"$SHIM" builder prune --force --all
assert_logged "[image][prune][--force]" "builder prune maps to a dangling-image prune"
assert_not_logged "[--all]" "builder prune never removes tagged images"

reset_log
"$SHIM" rm -f dune-server-overmap dune-server-survival-1
assert_logged "[rm][-f][dune-server-overmap]" "multi-container rm runs per container"
assert_logged "[rm][-f][dune-server-survival-1]" "multi-container rm reaches every container"

reset_log
if "$SHIM" container stop -t 5 missing-container dune-director 2>/dev/null; then
  fail "a partial stop failure is reported like Docker"
fi
assert_logged "[container][stop][-t][5][dune-director]" "stop still acts on the containers that exist"

reset_log
"$SHIM" stop --time 120 dune-postgres
assert_logged "[stop][--time][120][dune-postgres]" "single-container stop passes through"

output="$("$SHIM" system df --format '{{.Type}}|{{.Reclaimable}}')"
grep -qx 'Build Cache|0B (0%)' <<<"$output" || fail "system df reports an empty Build Cache row; got: $output"

[ "$("$SHIM" compose version --short)" = "2" ] || fail "compose version --short"
[ "$("$SHIM" compose -f docker-compose.yml config --services)" = "orchestrator" ] || fail "compose config --services"

if "$SHIM" compose -f docker-compose.web.yml config --services >"$WORK/out" 2>&1; then
  fail "add-on compose files are rejected"
fi
grep -q 'not supported by the Podman port' "$WORK/out" || fail "add-on rejection explains why"

reset_log
"$SHIM" compose exec -T -e APP_ID=4754530 -u root orchestrator bash -lc 'echo hi' </dev/null
assert_logged "[exec][--interactive][--env][APP_ID=4754530][--user][root][dune-orchestrator][bash][-lc][echo hi]" \
  "compose exec targets the orchestrator container"

[ "$(FAKE_ORCH_STATE=running "$SHIM" compose ps --status running --services)" = "orchestrator" ] \
  || fail "compose ps lists a running orchestrator"
[ -z "$(FAKE_ORCH_STATE=exited "$SHIM" compose ps --status running --services)" ] \
  || fail "compose ps hides a stopped orchestrator"

reset_log
: >"$WORK/empty.env"
COMPOSE_PROJECT_NAME=testproj SERVER_IP=203.0.113.5 DOCKER_SOCKET_GID=998 \
  "$SHIM" compose --env-file "$WORK/empty.env" up -d --build orchestrator 2>"$WORK/up.err"
assert_logged "[build][--tag][dune-orchestrator:dev][--file][$ROOT_DIR/orchestrator/Dockerfile][$ROOT_DIR/orchestrator]" "compose up --build builds the image"
assert_logged "[volume][create][--label][com.docker.compose.project=testproj][--label][com.docker.compose.volume=dune-server][testproj_dune-server]" \
  "compose volumes get the project prefix and labels"
assert_logged "[run][--detach][--name][dune-orchestrator][--restart][unless-stopped][--network][host][--group-add][998]" "orchestrator run arguments"
[ "$SOCKET_GID" = 998 ] || assert_logged "[--group-add][$SOCKET_GID]" "orchestrator can use the Podman socket"
assert_logged "[--env][SERVER_IP=203.0.113.5]" "environment interpolation"
assert_logged "[--env][STEAM_APP_ID=4754530]" "environment defaults"
assert_logged "[--volume][$SOCKET:/var/run/docker.sock]" "orchestrator gets the Podman socket"
assert_logged "[--volume][testproj_dune-work:/work]" "orchestrator volumes"
assert_logged "[--label][com.docker.compose.project=testproj][--label][com.docker.compose.service=orchestrator]" "compose labels"
assert_logged "[dune-orchestrator:dev][dune][daemon]" "orchestrator command"
if grep -q 'warning' "$WORK/up.err"; then
  fail "docker-compose.yml no longer matches the emulated checksum; review runtime/podman/lib/compose.sh"
fi

hash="$(grep -o 'com.docker.compose.config-hash=[0-9a-f]*' "$LOG" | head -n1 | cut -d= -f2)"
reset_log
COMPOSE_PROJECT_NAME=testproj SERVER_IP=203.0.113.5 DOCKER_SOCKET_GID=998 FAKE_ORCH_HASH_STATE="$hash|running" \
  "$SHIM" compose --env-file "$WORK/empty.env" up -d orchestrator 2>/dev/null
assert_not_logged "[run]" "an unchanged running orchestrator is left alone"
assert_not_logged "[build]" "compose up without --build reuses the image"

reset_log
COMPOSE_PROJECT_NAME=testproj SERVER_IP=198.51.100.7 DOCKER_SOCKET_GID=998 FAKE_ORCH_HASH_STATE="$hash|running" \
  "$SHIM" compose --env-file "$WORK/empty.env" up -d orchestrator 2>/dev/null
assert_logged "[rm][--force][--time][10][dune-orchestrator]" "a changed configuration recreates the orchestrator"
assert_logged "[--env][SERVER_IP=198.51.100.7]" "the recreated orchestrator uses the new configuration"

# Without root, the shim must not fall back to the user's rootless Podman.
if [ "$(id -u)" -ne 0 ]; then
  if DUNE_PODMAN_ROOTLESS=0 DUNE_PODMAN_SOCKET="$WORK/missing.sock" "$SHIM" ps >"$WORK/out" 2>&1; then
    fail "non-root use without the rootful socket is refused"
  fi
  grep -q 'sudo dune' "$WORK/out" || fail "the refusal explains how to run it"
  reset_log
  DUNE_PODMAN_ROOTLESS=0 "$SHIM" ps
  assert_logged "[--remote][--url][unix://$SOCKET][ps]" "a writable rootful socket is used remotely"
else
  echo "SKIP: non-root refusal (running as root)"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures shim test(s) failed." >&2
  exit 1
fi
echo "Podman shim tests passed."
