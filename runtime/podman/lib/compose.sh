# shellcheck shell=bash
# shellcheck disable=SC2154 # podman_cmd is set by runtime/podman/shim/docker, which sources this file.
# Minimal `docker compose` for the Podman port, sourced by runtime/podman/shim/docker.
#
# Upstream manages one service with Compose: the orchestrator in
# docker-compose.yml. This runs that service with podman directly, using the
# container name, labels, volume names and settings Compose would use, so
# upstream's scripts (including runtime/scripts/compose-project.sh) work
# unchanged.
#
# The definition below mirrors docker-compose.yml. When upstream changes that
# file, `up` and `build` warn until the emulation is reviewed and
# DUNE_COMPOSE_FILE_SHA256 is updated (see runtime/podman/README.md).
# Upstream's optional add-on compose files (web console, metrics, TLS front,
# public probe, realtime agent, socket proxy) are not supported.

DUNE_COMPOSE_FILE_SHA256="b0bd574a66f0167a8ca018d8d0bed204d479d41e675243ef7c6a3f7f54508b5f"
COMPOSE_SERVICE="orchestrator"
COMPOSE_CONTAINER="dune-orchestrator"
COMPOSE_IMAGE="dune-orchestrator:dev"
COMPOSE_VOLUMES=(
  dune-server:/srv/dune/server
  dune-steam:/srv/dune/steam
  dune-cache:/srv/dune/cache
  dune-generated:/srv/dune/generated
  dune-work:/work
)

compose_explicit_project=""
compose_project=""
compose_env_file=""
compose_args=()

compose_die() {
  printf 'docker compose (dune Podman shim): %s\n' "$*" >&2
  exit 1
}

compose_note() {
  printf ' %s\n' "$*" >&2
}

compose_need_value() {
  [ "$1" -ge 2 ] || compose_die "$2 needs a value."
}

compose_main_file() {
  printf '%s/docker-compose.yml' "$DUNE_PODMAN_ROOT"
}

compose_require_main_file() {
  local file resolved main
  main="$(compose_main_file)"
  [ -f "$main" ] || compose_die "docker-compose.yml was not found in $DUNE_PODMAN_ROOT."
  main="$(readlink -f "$main")"
  for file in "$@"; do
    case "$file" in
      /*) resolved="$file" ;;
      *) resolved="$PWD/$file" ;;
    esac
    resolved="$(readlink -f "$resolved" 2>/dev/null || printf '%s' "$resolved")"
    [ "$resolved" = "$main" ] && continue
    compose_die "$(basename "$file") is not supported by the Podman port. Only the orchestrator in docker-compose.yml is emulated; upstream's optional add-ons need Docker Compose."
  done
}

compose_check_service() {
  [ "$1" = "$COMPOSE_SERVICE" ] \
    || compose_die "no such service: $1 (the Podman port only runs '$COMPOSE_SERVICE')."
}

compose_resolve_project() {
  if [ -n "$compose_explicit_project" ]; then
    compose_project="$compose_explicit_project"
  elif [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    compose_project="$COMPOSE_PROJECT_NAME"
  else
    compose_project="$(dune_resolve_compose_project_name "$DUNE_PODMAN_ROOT")" || exit $?
  fi
  dune_compose_project_is_valid "$compose_project" || compose_die "invalid project name: $compose_project"
}

# Compose interpolation: the shell environment wins over the .env file, and an
# empty value falls back to the default like ${VAR:-default}.
compose_env() {
  local key="$1" default="${2-}" value
  value="${!key-}"
  if [ -z "$value" ]; then
    value="$(dune_compose_env_file_value "$compose_env_file" "$key" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-$default}"
}

compose_warn_if_changed() {
  local actual
  actual="$(tr -d '\r' <"$(compose_main_file)" | sha256sum | cut -d' ' -f1)"
  [ "$actual" = "$DUNE_COMPOSE_FILE_SHA256" ] && return 0
  printf '%s\n' \
    "docker compose (dune Podman shim): warning: docker-compose.yml changed upstream and the Podman" \
    "emulation in runtime/podman/lib/compose.sh may be out of date; review it (runtime/podman/README.md)." >&2
}

compose_image_id() {
  "${podman_cmd[@]}" image inspect --format '{{.Id}}' "$COMPOSE_IMAGE" 2>/dev/null
}

compose_run_args() {
  local socket_gid docker_gid volume
  socket_gid="$(podman_socket_gid)" || exit $?
  docker_gid="$(compose_env DOCKER_SOCKET_GID 0)"
  compose_args=(
    --name "$COMPOSE_CONTAINER"
    --restart unless-stopped
    --network host
    --group-add "$docker_gid"
  )
  [ "$socket_gid" = "$docker_gid" ] || compose_args+=(--group-add "$socket_gid")
  compose_args+=(
    --env "SERVER_IP=$(compose_env SERVER_IP)"
    --env "SERVER_TITLE=$(compose_env SERVER_TITLE)"
    --env "SERVER_REGION=$(compose_env SERVER_REGION)"
    --env "STEAM_APP_ID=$(compose_env STEAM_APP_ID 4754530)"
    --env DUNE_ROOT=/srv/dune
    --env DUNE_SERVER_DIR=/srv/dune/server
    --env DUNE_STEAM_DIR=/srv/dune/steam
    --env DUNE_GENERATED_DIR=/srv/dune/generated
    --volume "$DUNE_PODMAN_SOCKET:/var/run/docker.sock"
  )
  for volume in "${COMPOSE_VOLUMES[@]}"; do
    compose_args+=(--volume "${compose_project}_${volume}")
  done
  compose_args+=(
    # stdin_open is left out: the daemon never reads stdin, and Podman warns
    # about -i with -t whenever the caller has no terminal (timers, scripts).
    --tty
    --health-cmd "docker info >/dev/null 2>&1 || exit 1"
    --health-interval 30s
    --health-timeout 10s
    --health-retries 3
    --health-start-period 15s
    --log-driver json-file
    --log-opt "max-size=$(compose_env DUNE_DOCKER_LOG_MAX_SIZE 50m)"
    --log-opt "max-file=$(compose_env DUNE_DOCKER_LOG_MAX_FILES 3)"
    --label "com.docker.compose.project=$compose_project"
    --label "com.docker.compose.service=$COMPOSE_SERVICE"
    --label com.docker.compose.container-number=1
    --label com.docker.compose.oneoff=False
    --label "com.docker.compose.project.working_dir=$DUNE_PODMAN_ROOT"
    --label "com.docker.compose.project.config_files=$(compose_main_file)"
  )
}

compose_ensure_volumes() {
  local volume name
  for volume in "${COMPOSE_VOLUMES[@]}"; do
    name="${compose_project}_${volume%%:*}"
    "${podman_cmd[@]}" volume exists "$name" && continue
    "${podman_cmd[@]}" volume create \
      --label "com.docker.compose.project=$compose_project" \
      --label "com.docker.compose.volume=${volume%%:*}" \
      "$name" >/dev/null
    compose_note "Volume $name  Created"
  done
}

compose_version() {
  case "${1-}" in
    --short) printf '2\n' ;;
    *) printf 'Docker Compose version v2 (dune Podman emulation of docker-compose.yml)\n' ;;
  esac
}

compose_config() {
  case "${1-}" in
    --services) printf '%s\n' "$COMPOSE_SERVICE" ;;
    --volumes) printf '%s\n' "${COMPOSE_VOLUMES[@]%%:*}" ;;
    -q | --quiet) ;;
    "") cat "$(compose_main_file)" ;;
    *) compose_die "unsupported 'config' option: $1" ;;
  esac
}

compose_build() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-cache) opts+=(--no-cache) ;;
      --pull) opts+=(--pull) ;;
      -q | --quiet) opts+=(--quiet) ;;
      --build-arg)
        compose_need_value "$#" "$1"
        opts+=(--build-arg "$2")
        shift
        ;;
      --build-arg=*) opts+=("$1") ;;
      --progress)
        compose_need_value "$#" "$1"
        shift
        ;;
      --progress=*) ;;
      -*) compose_die "unsupported 'build' option: $1" ;;
      *) compose_check_service "$1" ;;
    esac
    shift
  done
  compose_warn_if_changed
  "${podman_cmd[@]}" build "${opts[@]}" \
    --tag "$COMPOSE_IMAGE" \
    --file "$DUNE_PODMAN_ROOT/orchestrator/Dockerfile" \
    "$DUNE_PODMAN_ROOT/orchestrator"
}

compose_up() {
  local build=0 no_build=0 force=0 detach=0 image_id hash existing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d | --detach) detach=1 ;;
      --build) build=1 ;;
      --no-build) no_build=1 ;;
      --force-recreate) force=1 ;;
      --no-recreate | --no-deps | --remove-orphans | --quiet-pull | --wait | --no-color | --no-log-prefix) ;;
      --pull | --timeout | -t | --wait-timeout)
        compose_need_value "$#" "$1"
        shift
        ;;
      --pull=* | --timeout=* | --wait-timeout=*) ;;
      -*) compose_die "unsupported 'up' option: $1" ;;
      *) compose_check_service "$1" ;;
    esac
    shift
  done

  compose_resolve_project
  if [ "$build" = 1 ] || ! image_id="$(compose_image_id)" || [ -z "$image_id" ]; then
    [ "$no_build" = 0 ] || compose_die "image $COMPOSE_IMAGE is missing and --no-build was given."
    compose_build
  else
    compose_warn_if_changed
  fi
  image_id="$(compose_image_id)" || compose_die "image $COMPOSE_IMAGE was not built."
  compose_ensure_volumes
  compose_run_args
  hash="$(printf '%s\n' "${compose_args[@]}" "$image_id" dune daemon | sha256sum | cut -d' ' -f1)"

  existing="$("${podman_cmd[@]}" inspect --format '{{index .Config.Labels "com.docker.compose.config-hash"}}|{{.State.Status}}' "$COMPOSE_CONTAINER" 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$force" = 0 ] && [ "${existing%%|*}" = "$hash" ]; then
    if [ "${existing#*|}" = "running" ]; then
      compose_note "Container $COMPOSE_CONTAINER  Running"
    else
      "${podman_cmd[@]}" start "$COMPOSE_CONTAINER" >/dev/null
      compose_note "Container $COMPOSE_CONTAINER  Started"
    fi
  else
    if [ -n "$existing" ]; then
      compose_note "Container $COMPOSE_CONTAINER  Recreate"
      "${podman_cmd[@]}" rm --force --time 10 "$COMPOSE_CONTAINER" >/dev/null
    fi
    "${podman_cmd[@]}" run --detach "${compose_args[@]}" \
      --label "com.docker.compose.config-hash=$hash" \
      "$COMPOSE_IMAGE" dune daemon >/dev/null
    compose_note "Container $COMPOSE_CONTAINER  Started"
  fi
  [ "$detach" = 1 ] || compose_note "Running detached; follow the output with: docker compose logs -f $COMPOSE_SERVICE"
}

compose_exec() {
  local tty=1 detach=0
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -T | --no-TTY | --no-tty) tty=0 ;;
      -d | --detach) detach=1 ;;
      -i | --interactive) ;;
      --privileged) opts+=(--privileged) ;;
      -e | --env | -u | --user | -w | --workdir)
        compose_need_value "$#" "$1"
        case "$1" in
          -e | --env) opts+=(--env "$2") ;;
          -u | --user) opts+=(--user "$2") ;;
          *) opts+=(--workdir "$2") ;;
        esac
        shift
        ;;
      --env=*) opts+=(--env "${1#*=}") ;;
      --user=*) opts+=(--user "${1#*=}") ;;
      --workdir=*) opts+=(--workdir "${1#*=}") ;;
      --index)
        compose_need_value "$#" "$1"
        shift
        ;;
      --index=*) ;;
      --)
        shift
        break
        ;;
      -*) compose_die "unsupported 'exec' option: $1" ;;
      *) break ;;
    esac
    shift
  done
  [ "$#" -ge 2 ] || compose_die "usage: docker compose exec [options] $COMPOSE_SERVICE COMMAND [ARGS...]"
  compose_check_service "$1"
  shift
  if [ "$detach" = 1 ]; then
    opts=(--detach "${opts[@]}")
  else
    opts=(--interactive "${opts[@]}")
    if [ "$tty" = 1 ] && [ -t 0 ] && [ -t 1 ]; then
      opts=(--tty "${opts[@]}")
    fi
  fi
  run_podman exec "${opts[@]}" "$COMPOSE_CONTAINER" "$@"
}

compose_ps() {
  local services_only=0 quiet=0 all=0 status_filter="" state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --services) services_only=1 ;;
      -q | --quiet) quiet=1 ;;
      -a | --all) all=1 ;;
      --status)
        compose_need_value "$#" "$1"
        status_filter="$2"
        shift
        ;;
      --status=*) status_filter="${1#*=}" ;;
      --format | --filter)
        compose_need_value "$#" "$1"
        shift
        ;;
      --format=* | --filter=* | --no-trunc | --orphans | --orphans=*) ;;
      -*) compose_die "unsupported 'ps' option: $1" ;;
      *) compose_check_service "$1" ;;
    esac
    shift
  done
  state="$("${podman_cmd[@]}" inspect --format '{{.State.Status}}' "$COMPOSE_CONTAINER" 2>/dev/null || true)"
  [ -n "$state" ] || return 0
  if [ -n "$status_filter" ]; then
    [ "$state" = "$status_filter" ] || return 0
  elif [ "$all" = 0 ] && [ "$state" != "running" ]; then
    return 0
  fi
  if [ "$services_only" = 1 ]; then
    printf '%s\n' "$COMPOSE_SERVICE"
  elif [ "$quiet" = 1 ]; then
    "${podman_cmd[@]}" inspect --format '{{.Id}}' "$COMPOSE_CONTAINER"
  else
    "${podman_cmd[@]}" ps --all --filter "name=^${COMPOSE_CONTAINER}\$" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  fi
}

compose_logs() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f | --follow) opts+=(--follow) ;;
      -t | --timestamps) opts+=(--timestamps) ;;
      -n | --tail | --since | --until)
        compose_need_value "$#" "$1"
        case "$1" in
          -n | --tail) opts+=(--tail "$2") ;;
          *) opts+=("$1" "$2") ;;
        esac
        shift
        ;;
      --tail=* | --since=* | --until=*) opts+=("$1") ;;
      --no-color | --no-log-prefix) ;;
      -*) compose_die "unsupported 'logs' option: $1" ;;
      *) compose_check_service "$1" ;;
    esac
    shift
  done
  run_podman logs "${opts[@]}" "$COMPOSE_CONTAINER"
}

compose_lifecycle() {
  local action="$1" remove_volumes=0 stop_first=0 volume
  local -a opts=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$action:$1" in
      stop:-t | stop:--timeout | restart:-t | restart:--timeout | down:-t | down:--timeout)
        compose_need_value "$#" "$1"
        opts+=(--time "$2")
        shift
        ;;
      kill:-s | kill:--signal)
        compose_need_value "$#" "$1"
        opts+=(--signal "$2")
        shift
        ;;
      rm:-s | rm:--stop) stop_first=1 ;;
      rm:-f | rm:--force) ;;
      rm:-v | rm:--volumes) ;;
      down:-v | down:--volumes) remove_volumes=1 ;;
      down:--remove-orphans) ;;
      down:--rmi)
        compose_need_value "$#" "$1"
        shift
        ;;
      *:-*) compose_die "unsupported '$action' option: $1" ;;
      *) compose_check_service "$1" ;;
    esac
    shift
  done
  case "$action" in
    start | stop | restart | kill) run_podman "$action" "${opts[@]}" "$COMPOSE_CONTAINER" ;;
    rm)
      if [ "$stop_first" = 1 ]; then
        "${podman_cmd[@]}" rm --force "$COMPOSE_CONTAINER" >/dev/null
      else
        "${podman_cmd[@]}" rm "$COMPOSE_CONTAINER" >/dev/null
      fi
      compose_note "Container $COMPOSE_CONTAINER  Removed"
      ;;
    down)
      "${podman_cmd[@]}" rm --force "${opts[@]}" "$COMPOSE_CONTAINER" >/dev/null
      compose_note "Container $COMPOSE_CONTAINER  Removed"
      if [ "$remove_volumes" = 1 ]; then
        compose_resolve_project
        for volume in "${COMPOSE_VOLUMES[@]}"; do
          "${podman_cmd[@]}" volume rm --force "${compose_project}_${volume%%:*}" >/dev/null
          compose_note "Volume ${compose_project}_${volume%%:*}  Removed"
        done
      fi
      ;;
  esac
}

dune_compose_main() {
  local -a files=()
  local sub=""
  compose_env_file="$DUNE_PODMAN_ROOT/.env"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f | --file | -p | --project-name | --env-file | --project-directory | --profile | --ansi | --progress | --parallel)
        compose_need_value "$#" "$1"
        case "$1" in
          -f | --file) files+=("$2") ;;
          -p | --project-name) compose_explicit_project="$2" ;;
          --env-file) compose_env_file="$2" ;;
        esac
        shift
        ;;
      --file=*) files+=("${1#*=}") ;;
      --project-name=*) compose_explicit_project="${1#*=}" ;;
      --env-file=*) compose_env_file="${1#*=}" ;;
      --project-directory=* | --profile=* | --ansi=* | --progress=* | --parallel=* | --compatibility | --dry-run) ;;
      -*) compose_die "unsupported option: $1" ;;
      *)
        sub="$1"
        shift
        break
        ;;
    esac
    shift
  done

  case "$sub" in
    version)
      compose_version "$@"
      return
      ;;
    "" | help | --help)
      compose_die "usage: docker compose [-f docker-compose.yml] [-p PROJECT] {up|build|exec|ps|logs|config|start|stop|restart|kill|rm|down|version}"
      ;;
  esac
  compose_require_main_file "${files[@]}"
  # shellcheck source=runtime/scripts/compose-project.sh
  . "$DUNE_PODMAN_ROOT/runtime/scripts/compose-project.sh"
  case "$sub" in
    config) compose_config "$@" ;;
    ps) compose_ps "$@" ;;
    up) compose_up "$@" ;;
    build) compose_build "$@" ;;
    exec) compose_exec "$@" ;;
    logs) compose_logs "$@" ;;
    start | stop | restart | kill | rm | down) compose_lifecycle "$sub" "$@" ;;
    *) compose_die "'docker compose $sub' is not supported by the Podman port." ;;
  esac
}
