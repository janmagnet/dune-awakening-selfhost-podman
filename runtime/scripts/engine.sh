#!/usr/bin/env bash
# Container engine + platform abstraction for the Dune self-host stack.
#
# Rootful Podman is the supported target. Every script talks to the container
# engine through the engine() wrapper and to systemd through dune_systemctl(),
# and all platform-specific paths live in the variables below. Keeping these in
# one place means a future rootless mode is an incremental change (flip the
# socket path, the Quadlet directory and the systemctl scope) rather than a
# rewrite spread across dozens of scripts.

# Guard against double-sourcing when several libraries are sourced together.
if [ -n "${DUNE_ENGINE_SH_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
DUNE_ENGINE_SH_SOURCED=1

# Container engine binary. Podman is the supported engine; DUNE_ENGINE is only
# an override hook for local experimentation, not a supported dual-engine mode.
DUNE_ENGINE="${DUNE_ENGINE:-podman}"

# Rootful Podman API socket. The orchestrator and autoscaler containers bind
# this in so they can manage sibling containers. Rootless would instead use
# "${XDG_RUNTIME_DIR}/podman/podman.sock".
DUNE_PODMAN_SOCKET="${DUNE_PODMAN_SOCKET:-/run/podman/podman.sock}"

# Directory the Podman Quadlet system generator reads unit files from. Rootless
# would use "${HOME}/.config/containers/systemd".
DUNE_QUADLET_DIR="${DUNE_QUADLET_DIR:-/etc/containers/systemd}"

# systemd manager scope for Quadlet-backed services. Rootful Podman uses the
# system manager; rootless would set this to "user".
DUNE_SYSTEMCTL_SCOPE="${DUNE_SYSTEMCTL_SCOPE:-system}"

# Run the configured container engine, e.g. engine ps / engine run / engine exec.
engine() {
  command "$DUNE_ENGINE" "$@"
}

# Run systemctl against the configured scope (system for rootful Podman).
dune_systemctl() {
  if [ "$DUNE_SYSTEMCTL_SCOPE" = "user" ]; then
    systemctl --user "$@"
  else
    systemctl "$@"
  fi
}

# True when the configured systemd/Quadlet scope requires root (rootful Podman).
dune_quadlet_needs_root() {
  [ "$DUNE_SYSTEMCTL_SCOPE" != "user" ]
}

# Fail early with a helpful message if we cannot manage the Quadlet/systemd scope.
require_quadlet_privileges() {
  if dune_quadlet_needs_root && [ "$(id -u)" -ne 0 ]; then
    echo "This step manages rootful Podman Quadlet units under ${DUNE_QUADLET_DIR} and needs root." >&2
    echo "Re-run the dune command with sudo (for example: sudo dune start)." >&2
    return 1
  fi
  return 0
}

# Write a Quadlet unit file from stdin. Units may embed secrets (tokens, hex
# secrets), so they are created root-only (mode 0600); the rootful Podman Quadlet
# generator reads them as root. Usage: quadlet_write <unit-filename> <<EOF ... EOF
quadlet_write() {
  local name="$1"
  local dest="${DUNE_QUADLET_DIR}/${name}"
  mkdir -p "$DUNE_QUADLET_DIR"
  ( umask 077; cat > "$dest" )
  chmod 600 "$dest"
}

# Reload systemd so newly written Quadlet units are turned into services.
quadlet_reload() {
  dune_systemctl daemon-reload
}

# Install the shared, secret-free Quadlet units (network + named volumes) from
# the repo into the Quadlet directory. Idempotent; callers reload systemd once
# after also writing their own unit. Must run from the repo root.
ensure_quadlet_foundation() {
  mkdir -p "$DUNE_QUADLET_DIR"
  local unit
  shopt -s nullglob
  for unit in runtime/quadlet/*.network runtime/quadlet/*.volume; do
    install -m 0644 "$unit" "${DUNE_QUADLET_DIR}/$(basename "$unit")"
  done
}
