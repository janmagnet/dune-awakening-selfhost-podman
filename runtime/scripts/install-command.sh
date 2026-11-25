#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
LAB_DIR="$(pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root, for example: sudo runtime/scripts/install-command.sh" >&2
  exit 1
fi

cat > /usr/local/bin/dune <<EOF
#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="\${DUNE_PODMAN_DIR:-\${DUNE_DOCKER_DIR:-$LAB_DIR}}"

if [ ! -d "\$LAB_DIR" ]; then
  echo "Dune lab directory not found: \$LAB_DIR"
  echo "Set DUNE_PODMAN_DIR=/path/to/dune-awakening-selfhost-podman if needed."
  exit 1
fi

# The stack runs on rootful Podman.
if [ "\$(id -u)" -ne 0 ]; then
  exec sudo env DUNE_PODMAN_DIR="\$LAB_DIR" "\$0" "\$@"
fi

. "\$LAB_DIR/runtime/podman/path.sh"
case "\${1:-}" in
  # Upstream moved its interactive manager into the web console, which this
  # Podman port does not run yet, so keep the terminal manager reachable.
  manager | menu) exec "\$LAB_DIR/runtime/scripts/manager.sh" ;;
esac
exec "\$LAB_DIR/runtime/scripts/dune" "\$@"
EOF

chmod +x /usr/local/bin/dune

echo "Installed dune command:"
which dune

runtime/podman/setup-host.sh
