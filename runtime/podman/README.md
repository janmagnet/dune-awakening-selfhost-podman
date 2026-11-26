# Podman layer

This directory is the whole Podman port. Everything else in the repository is
[RedBlink's Docker project](https://github.com/Red-Blink/dune-awakening-selfhost-docker),
kept as close to upstream as possible so its changes merge cleanly.

## How it works

Upstream's scripts call `docker`. The `dune` command installed by
`runtime/scripts/install-command.sh` (`/usr/local/bin/dune`) runs as root and
puts `shim/docker` first on `PATH`, so every upstream script, Python helper and
background job it starts reaches rootful Podman. Nothing is installed as
`docker` on the host, so a Docker installation on the same machine (Fedora
CoreOS ships one) is not used or changed.

| File | Purpose |
|---|---|
| `shim/docker` | The `docker` command for the stack: runs `podman`, translating only what behaves differently (below). |
| `lib/compose.sh` | `docker compose` for the one Compose service the stack uses: the orchestrator in `docker-compose.yml`. |
| `lib/owner.sh` | Makes root the installation owner (used by `setup-host.sh`). |
| `path.sh` | Puts the shim on `PATH` (sourced by the `dune` wrapper). |
| `setup-host.sh` | Host integration, run by `install-command.sh`. |
| `restore-containers.sh` | Restarts the stack after a reboot on Podman before 5.8.2. |
| `tests/` | Shim unit tests and an integration test against real rootful Podman. |

Containers that run upstream scripts themselves (the autoscaler, the Coriolis
coordinator and the orchestrator) keep upstream's docker CLI and reach Podman
through its Docker-compatible API socket, which the shim mounts in place of
`/var/run/docker.sock`. The autoscaler and the coordinator also start containers
that mount `/var/run/docker.sock`, for example when a game farm restart
recreates the autoscaler. Podman resolves that path on the host, where it is
Docker's socket or missing. So when the shim starts a `dune-orchestrator:dev`
container with the socket, it also mounts itself there as
`/usr/local/bin/docker`, in front of the image's `/usr/bin/docker`. There it only
rewrites those mounts and passes everything else to the image's docker CLI.

## What the shim translates

| Upstream relies on (Docker) | Podman difference | Shim |
|---|---|---|
| `-v /var/run/docker.sock:...` | That path is Docker's own socket, if any | Mounts the Podman API socket and adds its group, also for containers started inside the stack's containers |
| `inspect` `.State.StartedAt` / `.FinishedAt` in RFC 3339 | Go's default time format, which `date -d` and `logs --since` reject | Formats them as RFC 3339 UTC |
| `sha256:` image IDs from `inspect .Image`, `image inspect .Id` and `image ls --no-trunc` | Bare IDs from `inspect`; upstream compares them to protect in-use images | Adds the `sha256:` prefix |
| `rm`/`stop`/`kill`/`start`/`restart` act on every named container that exists | The whole batch is skipped when one name is missing | Runs them one container at a time |
| `builder prune --all` clears the build cache | Deletes every unused tagged image, including the game images | Prunes dangling images only |
| `volume create` returns the existing volume when the name is taken (`start-postgres.sh` relies on it) | Fails with "volume already exists" | Adds `--ignore` (Podman 4.4+) |
| `system df` has a `Build Cache` row | No such row; upstream's storage checks need it | Adds an empty row |
| `docker compose` | Not available | `lib/compose.sh` |
| Non-root access through the `docker` group | Would silently use the user's rootless Podman | Refuses unless the rootful socket is writable |

Everything else is passed to `podman` unchanged. The compose emulation runs the
orchestrator with the container name, labels, project-prefixed volumes and
settings Compose would use, so `runtime/scripts/compose-project.sh` keeps
working.

## Host setup

`setup-host.sh` is idempotent; `install-command.sh` runs it. It:

- enables `podman.socket` and `podman-restart.service`;
- makes root the owner of the checkout directory and its `.git`, and sets
  `DUNE_HOST_UID` and `DUNE_HOST_GID` in `.env` to 0. Upstream runs the
  autoscaler, the Coriolis coordinator, scheduled restarts and backups as the
  checkout's owner, while the `dune` command here runs as root (and `dune init`
  gives `runtime/` to root), so a checkout cloned by a regular user would leave
  those unable to write their files or reach Podman. Upstream gives `runtime/`
  to the new owner at the next start; game saves keep their owners;
- on Podman before 5.8.2, installs `dune-podman-restore.service`, because those
  releases do not restart `--restart unless-stopped` containers after a reboot;
- on SELinux hosts, disables container label separation for Podman
  (`/etc/containers/containers.conf.d/50-dune-selfhost-podman.conf`), because
  upstream bind-mounts the repository and the API socket without relabeling.
  Set `DUNE_PODMAN_KEEP_SELINUX_LABELS=1` to skip this;
- adds `/etc/systemd/system/dune-awakening-.service.d/50-dune-podman.conf` so
  the timers upstream installs (auto-update, scheduled restarts, backups, IP
  change restart) use the shim. Those units also declare `Wants=docker.service`,
  so they start Docker on a host that has it (Fedora CoreOS); the script says so
  and suggests masking `docker.socket` and `docker.service` when nothing else
  uses Docker;
- removes the Quadlet units and orchestrator image of the previous version of
  this port.

Re-run `sudo runtime/scripts/install-command.sh` after moving the repository.

## Not supported yet

- Upstream's web console (`docker-compose.web.yml`) and Compose add-ons
  (metrics, TLS front / encrypted API, public probe, realtime agent, socket
  proxy). `docker compose -f <add-on file>` fails with a clear message.
- `install.sh` and `bootstrap.sh`: they install Docker and upstream's console.
- Running `runtime/scripts/*` directly bypasses the shim; go through `dune`.

On Podman before 5, `docker update` memory changes apply to running containers
but `inspect` keeps reporting the old limit.

## Syncing with upstream

```bash
git remote add upstream https://github.com/Red-Blink/dune-awakening-selfhost-docker.git
git config remote.upstream.tagOpt --no-tags
git fetch upstream
git merge upstream/main
```

Keep upstream's release tags out of this repository: they point at Docker-only
commits, and `dune`'s stack repair resets checkouts to the tag named in
`VERSION`.

Conflicts can only occur in the few upstream files this fork changes; keep the
fork's lines when resolving them:

| File | Fork change |
|---|---|
| `README.md` | Podman documentation |
| `NOTICE` | Title and attribution |
| `.env.example` | `HOST_DATACENTER_ID="dune-podman"` |
| `runtime/scripts/install-command.sh` | Root wrapper that loads the shim; runs `setup-host.sh` |
| `runtime/scripts/self-update.sh` | Updates come from this fork's releases |
| `runtime/scripts/dune` | `dune start` skips the web console, which is not ported |

After merging:

1. `git diff upstream/main --stat` should list only those files plus
   `runtime/podman/` and `.github/workflows/podman-port.yml`.
2. Review new `docker` usage in the merged upstream changes against the table
   above (`git diff ORIG_HEAD HEAD -G 'docker ' -- runtime/scripts orchestrator`).
   Containers that mount `/var/run/docker.sock` and start containers themselves
   only get the shim when they use `dune-orchestrator:dev` (see `translate_run`).
3. If `docker-compose.yml` changed, mirror the change in `lib/compose.sh` and
   update `DUNE_COMPOSE_FILE_SHA256` (`tr -d '\r' < docker-compose.yml | sha256sum`).
4. Run `bash runtime/podman/tests/shim-test.sh`, and on a disposable host with
   Podman, `sudo bash runtime/podman/tests/podman-integration-test.sh`. The
   `Podman port` GitHub workflow runs both.
