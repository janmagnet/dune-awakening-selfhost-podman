#!/usr/bin/env bash
# Boot-time restore for Podman releases before 5.8.2, whose podman-restart.service
# only restarts containers created with `--restart always`. Upstream starts the
# stack with `--restart unless-stopped`, so start those Dune containers here,
# skipping any an operator stopped on purpose (Docker's semantics).
# Installed as dune-podman-restore.service by runtime/podman/setup-host.sh.
set -euo pipefail

# Dependencies first; the rest follow in name order.
PRIORITY=(dune-postgres dune-rmq-admin dune-rmq-game dune-text-router dune-director dune-server-gateway)

mapfile -t names < <(
  podman ps --all --filter restart-policy=unless-stopped --format '{{.Names}}' | grep '^dune-' | sort || true
)

ordered=()
for name in "${PRIORITY[@]}"; do
  for candidate in "${names[@]}"; do
    [ "$candidate" = "$name" ] && ordered+=("$name")
  done
done
for candidate in "${names[@]}"; do
  case " ${PRIORITY[*]} " in
    *" $candidate "*) ;;
    *) ordered+=("$candidate") ;;
  esac
done

for name in "${ordered[@]}"; do
  if ! state="$(podman inspect --format '{{.State.Status}}|{{.State.StoppedByUser}}' "$name" 2>/dev/null)"; then
    # Older Podman releases do not report StoppedByUser.
    state="$(podman inspect --format '{{.State.Status}}|false' "$name" 2>/dev/null)" || continue
  fi
  [ "${state%%|*}" != "running" ] || continue
  if [ "${state#*|}" = "true" ]; then
    echo "Leaving $name stopped (it was stopped by an operator)."
    continue
  fi
  echo "Starting $name"
  podman start "$name" >/dev/null || echo "WARN: could not start $name" >&2
done
