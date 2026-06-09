FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Talk to the host's rootful Podman API socket (bind-mounted at runtime). With
# CONTAINER_HOST set, the in-container podman binary acts as a remote client, so
# `podman load` / `podman ps` operate on the host engine that runs the stack.
ENV CONTAINER_HOST=unix:///run/podman/podman.sock

RUN dpkg --add-architecture i386 \
 && apt-get update -y \
 && apt-get install -y \
    ca-certificates \
    curl \
    tar \
    gzip \
    unzip \
    jq \
    git \
    python3 \
    python3-yaml \
    procps \
    util-linux \
    lib32gcc-s1 \
    lib32stdc++6 \
    podman \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash dune \
 && mkdir -p \
    /home/dune/.steam \
    /srv/dune/server \
    /srv/dune/steam \
    /srv/dune/generated \
    /srv/dune/cache \
 && chown -R dune:dune /home/dune /srv/dune

COPY dune_orchestrator.py /usr/local/bin/dune
RUN chmod +x /usr/local/bin/dune

ENTRYPOINT ["/usr/local/bin/dune"]
CMD ["help"]
