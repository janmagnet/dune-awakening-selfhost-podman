# shellcheck shell=bash
# Sourced by runtime/podman/setup-host.sh (and its integration test).
#
# Upstream runs the autoscaler, the Coriolis coordinator, scheduled restarts and
# backups as the owner of the checkout, and gives runtime/ to that owner. In this
# port the dune command and the stack's timers run as root, because the stack
# runs on rootful Podman, so root has to be that owner. Otherwise those
# containers cannot write the runtime files root creates (dune init gives
# runtime/ to root), and scheduled jobs that switch to the owner cannot reach
# Podman.
#
# Upstream takes the owner from the checkout directory and from DUNE_HOST_UID
# and DUNE_HOST_GID in .env, and gives runtime/ to it at the next start, so only
# those change here; game saves under runtime/game keep their owners. .git
# follows so that git still accepts the checkout when root runs it without sudo,
# as the stack's update timer does.

# Usage: dune_podman_make_root_owner <checkout>
dune_podman_make_root_owner() {
  local dir="$1" owner changed=0
  owner="$(stat -c '%u:%g' "$dir")"
  if [ "$owner" = "0:0" ]; then
    printf '  %s\n' "root owns $dir."
  else
    chown root:root "$dir"
    if [ -e "$dir/.git" ]; then
      chown root:root "$dir/.git"
    fi
    changed=1
    printf '  %s\n' \
      "Made root the owner of $dir (was $owner), because the stack runs as root." \
      "Use sudo for git in it from now on, for example: sudo git pull"
  fi
  if [ -f "$dir/.env" ] && grep -Eq "^DUNE_HOST_[UG]ID=[\"']?[1-9]" "$dir/.env"; then
    sed -i -E 's/^(DUNE_HOST_[UG]ID)=.*/\1=0/' "$dir/.env"
    changed=1
    printf '  %s\n' "Set DUNE_HOST_UID and DUNE_HOST_GID to 0 in .env."
  fi
  if [ "$changed" = 1 ] && [ -f "$dir/.env" ]; then
    printf '  %s\n' "Restart the stack so that its containers run as root: dune stop, then dune start."
  fi
}
