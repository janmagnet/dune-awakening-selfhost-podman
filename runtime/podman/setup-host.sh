#!/usr/bin/env bash
# Prepares a rootful Podman host for this stack. Idempotent; safe to re-run.
# Called by runtime/scripts/install-command.sh.
#
# It installs no `docker` command and does not touch Docker's socket, so a
# Docker installation on the same host (for example on Fedora CoreOS) is left
# alone. See runtime/podman/README.md for what each step is for.
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT_DIR="$(pwd -P)"
SHIM_DIR="$ROOT_DIR/runtime/podman/shim"
SYSTEMD_DIR="/etc/systemd/system"
QUADLET_DIR="/etc/containers/systemd"
RESTORE_UNIT="dune-podman-restore.service"
TIMER_DROPIN="$SYSTEMD_DIR/dune-awakening-.service.d/50-dune-podman.conf"
SELINUX_CONF="/etc/containers/containers.conf.d/50-dune-selfhost-podman.conf"

step() { printf '\n=== %s ===\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# True when version $1 >= version $2.
version_at_least() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

selinux_enabled() {
  if command -v selinuxenabled >/dev/null 2>&1; then
    selinuxenabled
  else
    [ -e /sys/fs/selinux/enforce ]
  fi
}

[ "$(id -u)" -eq 0 ] || die "run this as root, for example: sudo runtime/podman/setup-host.sh"
command -v podman >/dev/null 2>&1 || die "podman was not found. Install Podman 4.4 or newer and re-run."
if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  die "systemd is required."
fi

podman_version="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
[ -n "$podman_version" ] || die "could not run 'podman version' as root."

step "Podman"
info "podman $podman_version (rootful)"
version_at_least "$podman_version" 4.4.0 || info "WARN: Podman 4.4 or newer is recommended."
command -v python3 >/dev/null 2>&1 || info "WARN: python3 is missing; the stack's scripts need it (Fedora CoreOS: rpm-ostree install python3)."

step "Podman API socket"
systemctl enable --now podman.socket >/dev/null 2>&1 \
  || die "could not enable podman.socket; check 'systemctl status podman.socket'."
info "podman.socket is enabled; the orchestrator and autoscaler containers manage the stack through it."

step "Restarting containers after a reboot"
if systemctl cat podman-restart.service >/dev/null 2>&1; then
  if systemctl enable podman-restart.service >/dev/null 2>&1; then
    info "podman-restart.service is enabled."
  else
    info "WARN: could not enable podman-restart.service."
  fi
fi
if version_at_least "$podman_version" 5.8.2; then
  if [ -f "$SYSTEMD_DIR/$RESTORE_UNIT" ]; then
    systemctl disable "$RESTORE_UNIT" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/$RESTORE_UNIT"
  fi
  info "This Podman restores --restart unless-stopped containers by itself."
else
  cat >"$SYSTEMD_DIR/$RESTORE_UNIT" <<EOF
# Installed by runtime/podman/setup-host.sh (dune-awakening-selfhost-podman).
[Unit]
Description=Start Dune containers that use --restart unless-stopped (Podman before 5.8.2)
Wants=network-online.target
After=network-online.target podman.socket podman-restart.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=$ROOT_DIR/runtime/podman/restore-containers.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$RESTORE_UNIT" >/dev/null 2>&1 || die "could not enable $RESTORE_UNIT."
  info "Installed $RESTORE_UNIT: Podman $podman_version does not restart"
  info "--restart unless-stopped containers after a reboot by itself."
fi

step "SELinux"
if ! selinux_enabled; then
  info "SELinux is not enabled; nothing to do."
elif [ "${DUNE_PODMAN_KEEP_SELINUX_LABELS:-0}" = "1" ]; then
  rm -f "$SELINUX_CONF"
  info "Keeping SELinux container labels (DUNE_PODMAN_KEEP_SELINUX_LABELS=1). Containers that"
  info "bind-mount the repository or the Podman socket will be denied access."
else
  mkdir -p "$(dirname "$SELINUX_CONF")"
  cat >"$SELINUX_CONF" <<'EOF'
# Installed by runtime/podman/setup-host.sh (dune-awakening-selfhost-podman).
# Upstream's containers bind-mount the repository and the container API socket
# without SELinux relabel options, which works on Docker because it does not
# label containers by default. Do the same for this host's Podman containers.
[containers]
label = false
EOF
  systemctl try-restart podman.service >/dev/null 2>&1 || true
  info "Disabled SELinux label separation for Podman containers ($SELINUX_CONF)."
  info "Re-run with DUNE_PODMAN_KEEP_SELINUX_LABELS=1 to undo."
fi

step "Docker shim for the stack's systemd timers"
mkdir -p "$(dirname "$TIMER_DROPIN")"
cat >"$TIMER_DROPIN" <<EOF
# Installed by runtime/podman/setup-host.sh (dune-awakening-selfhost-podman).
# Upstream's timers (auto-update, scheduled restarts, backups, IP-change restart)
# run its scripts directly, so route their docker calls to Podman here.
[Service]
Environment=PATH=$SHIM_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
info "dune-awakening-*.service units use $SHIM_DIR first on PATH."
docker_can_start=0
for unit in docker.socket docker.service; do
  if systemctl cat "$unit" >/dev/null 2>&1 \
    && [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" != "masked" ]; then
    docker_can_start=1
  fi
done
if [ "$docker_can_start" = 1 ]; then
  info "NOTE: those units also declare Wants=docker.service, so they can start this host's Docker,"
  info "which the stack does not use. If nothing else uses it, turn it off with the command below."
  info "Mask both units: with only docker.service masked, docker.socket fails to start at each boot."
  info "  sudo systemctl mask --now docker.socket docker.service"
fi

step "Quadlet units from the previous Podman port"
removed=0
shopt -s nullglob
for unit in "$QUADLET_DIR"/dune-*.container; do
  grep -q 'Generated by runtime/scripts/' "$unit" || continue
  service="$(basename "$unit" .container).service"
  info "Stopping and removing $service"
  systemctl stop "$service" >/dev/null 2>&1 || true
  rm -f "$unit"
  removed=1
done
for unit in "$QUADLET_DIR"/dune-net.network "$QUADLET_DIR"/dune-server.volume "$QUADLET_DIR"/dune-steam.volume \
  "$QUADLET_DIR"/dune-cache.volume "$QUADLET_DIR"/dune-generated.volume "$QUADLET_DIR"/dune-postgres-data.volume; do
  if [ -f "$unit" ] && grep -q 'Dune Awakening' "$unit"; then
    rm -f "$unit"
    removed=1
  fi
done
shopt -u nullglob
if podman image exists dune-orchestrator:dev; then
  component="$(podman image inspect --format '{{index .Labels "io.github.red-blink.dune-selfhost.component"}}' dune-orchestrator:dev 2>/dev/null || true)"
  if [ "$component" != "orchestrator" ]; then
    # The previous port built this image with podman instead of the docker CLI
    # that upstream's scripts use inside it; it is rebuilt when next needed.
    info "Removing the dune-orchestrator:dev image built by the previous port; it is rebuilt from"
    info "upstream's Dockerfile when the stack next needs it."
    podman rmi --force dune-orchestrator:dev >/dev/null 2>&1 || true
    removed=1
  fi
fi
if [ "$removed" = 1 ]; then
  info "Removed. The dune-net network and the dune-postgres-data world volume are kept and reused."
  info "The old dune-server, dune-steam, dune-cache and dune-generated volumes are no longer used."
  info "After 'dune update install' has downloaded the server files again, remove them with:"
  info "  sudo podman volume rm dune-server dune-steam dune-cache dune-generated"
else
  info "None found."
fi

systemctl daemon-reload
echo
echo "Host setup for rootful Podman is complete."
