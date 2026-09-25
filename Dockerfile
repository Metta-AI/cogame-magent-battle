# One image: game server, player policy, and headless training bridge.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/magent-battle
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --threads:on \
  --mm:orc \
  --nimcache:/tmp/magent-battle-nimcache \
  --out:magent-battle \
  src/magent_battle.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/magent-battle-player-nimcache \
  --out:magent-battle-player \
  src/magent_battle_player.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/magent-battle-numeric-bridge-nimcache \
  --out:magent-battle-numeric-bridge \
  src/magent/numeric_bridge.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/magent-battle
COPY --from=build /workspace/magent-battle/magent-battle /bin/magent-battle
COPY --from=build /workspace/magent-battle/magent-battle-player \
  /bin/magent-battle-player
COPY --from=build /workspace/magent-battle/magent-battle-numeric-bridge \
  /bin/magent-battle-numeric-bridge
COPY --from=build /workspace/magent-battle/*.json ./
COPY --from=build /workspace/magent-battle/data ./data
COPY --from=build /workspace/magent-battle/client ./client

CMD ["/bin/magent-battle"]
