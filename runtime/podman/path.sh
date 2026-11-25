# shellcheck shell=bash
# Sourced by the /usr/local/bin/dune wrapper that runtime/scripts/install-command.sh
# writes. Puts the docker shim first on PATH so every upstream script and helper
# started from the dune command reaches rootful Podman, without installing a
# `docker` command on the host.
dune_podman_shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/shim"
case "$PATH" in
  "$dune_podman_shim_dir":*) ;;
  *) PATH="$dune_podman_shim_dir:$PATH" ;;
esac
export PATH
unset dune_podman_shim_dir
