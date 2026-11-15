#!/usr/bin/env bash
# Runs Ollama (the LLM), Open WebUI and optionally Caddy, all in Docker. Safe to run again.
# Also migrates the earlier setup (Ollama installed on the host) and the plain 'docker run'
# command, keeping accounts, chats and already-downloaded models.
#
# Usage: ./setup.sh [model ...]     (use sudo unless your user is in the docker group)
#        default model: qwen2.5:7b, or MODELS in .env
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# --- Docker -----------------------------------------------------------------
if ! command -v docker >/dev/null; then
  [[ $(uname -s) == Linux && $EUID -eq 0 ]] ||
    die "Docker isn't installed. Install Docker Desktop (Mac/Windows) or Docker Engine (Linux: sudo ./setup.sh installs it)."
  log "Installing Docker"
  command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null; }
  curl -fsSL https://get.docker.com | sh
fi
if ! docker info >/dev/null 2>&1; then
  [[ -d /run/systemd/system && $EUID -eq 0 ]] && systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 ||
    die "Can't talk to Docker. Start it (Docker Desktop, or: sudo systemctl start docker), or run this with sudo."
fi
docker compose version >/dev/null 2>&1 ||
  die "The Docker Compose plugin is missing. Install it: sudo apt-get install docker-compose-plugin"

# --- Settings (.env) ----------------------------------------------------------
if [[ ! -f .env ]]; then
  log "Creating .env from .env.example"
  cp .env.example .env
fi
set_env() {  # set_env KEY VALUE: replaces KEY=..., else the first commented #KEY=..., else appends
  local k=$1 v=$2 tmp pat
  tmp=$(mktemp)
  if grep -q "^$k=" .env; then pat="^$k="; else pat="^#$k="; fi
  awk -v pat="$pat" -v line="$k=$v" '!done && $0 ~ pat { print line; done=1; next } { print } END { if (!done) print line }' .env >"$tmp"
  cat "$tmp" >.env && rm -f "$tmp"
}
if (($#)); then
  set_env MODELS "\"$*\""
  echo "Models set in .env: $*"
fi

# NVIDIA GPU: use it when the driver and the NVIDIA Container Toolkit are both there.
if ! grep -q '^COMPOSE_FILE=' .env && command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
  if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    log "NVIDIA GPU found; Ollama will use it"
    set_env COMPOSE_FILE docker-compose.yml:docker-compose.gpu.yml
  else
    warn "An NVIDIA GPU is present but Docker can't use it. Install the NVIDIA Container Toolkit, restart Docker and rerun this script (see the README). Using the CPU for now."
  fi
fi

if grep -q '^COMPOSE_PROFILES=.*https' .env && ! grep -qE '^DOMAIN=.+' .env; then
  die "COMPOSE_PROFILES=https is set in .env but DOMAIN isn't. Set DOMAIN=your.domain.com"
fi

# --- Images -------------------------------------------------------------------
log "Pulling images (Open WebUI is about 2-5 GB; can take a few minutes)"
docker compose pull -q --ignore-buildable

# --- Migrate earlier installs -------------------------------------------------
# A container created by the plain 'docker run' command blocks the name. Its data is in the volume, so it can go.
if docker container inspect open-webui >/dev/null 2>&1 &&
   [[ -z $(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' open-webui) ]]; then
  mounts=$(docker container inspect -f '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' open-webui)
  [[ $mounts == *"open-webui:/app/backend/data"* ]] ||
    die "A container named open-webui exists but doesn't keep its data in the 'open-webui' volume ($mounts). Back it up, remove it, and rerun."
  log "Replacing the old 'docker run' container (data in the open-webui volume is kept)"
  docker rm -f open-webui >/dev/null
fi

# Models downloaded by an Ollama installed on the host: copy them in instead of downloading again.
if ! docker volume inspect ollama >/dev/null 2>&1; then
  for src in /usr/share/ollama/.ollama/models "${SUDO_USER:+$(eval echo "~$SUDO_USER")/.ollama/models}" "$HOME/.ollama/models"; do
    [[ -n $src && -d $src/manifests ]] || continue
    log "Copying models from the host's Ollama ($src, $(du -sh "$src" 2>/dev/null | cut -f1))"
    docker volume create ollama >/dev/null
    docker run --rm --entrypoint sh -v "$src":/from:ro -v ollama:/to \
      "ollama/ollama:$(sed -n 's/^OLLAMA_VERSION=//p' .env | tr -d '"' | grep . || echo latest)" \
      -c 'mkdir -p /to/models && cp -a /from/. /to/models/'
    break
  done
fi
if command -v ollama >/dev/null || [[ -f /etc/systemd/system/ollama.service ]]; then
  warn "Ollama is also installed on the host. It isn't used any more. To stop it: sudo systemctl disable --now ollama"
fi

# --- Start --------------------------------------------------------------------
log "Starting Ollama and Open WebUI"
docker compose up -d --remove-orphans
echo "Waiting for Open WebUI to become healthy (the first start downloads a few small models)..."
wait_for webui_up 300 || die "Open WebUI didn't become healthy. Check: docker compose logs open-webui"

fix_stored_ollama_url

log "Downloading models (only the first time takes long)"
wait_for_models || die "A model failed to download. Check the name at https://ollama.com/library and rerun. Log: docker compose logs models"

# --- Verify -------------------------------------------------------------------
log "Checking that Open WebUI can reach Ollama"
tags=$(docker exec open-webui curl -fsS --max-time 10 "$OLLAMA_INTERNAL_URL/api/tags") ||
  die "The Open WebUI container can't reach Ollama at $OLLAMA_INTERNAL_URL. Run ./diagnose.sh"
count=$(grep -o '"name"' <<<"$tags" | wc -l)
echo "OK: Open WebUI reaches Ollama and sees $count model(s)."
urls=$(stored_ollama_urls)
[[ -z $urls || $urls == *ollama:11434* ]] ||
  warn "Open WebUI is set to use $urls. If models are missing, check Admin Settings > Connections."
if docker exec ollama sh -c 'ls /dev/nvidia* >/dev/null 2>&1'; then echo "Ollama has the NVIDIA GPU."; fi

url=$(webui_url || echo "http://127.0.0.1:3000")
domain=$(sed -n 's/^DOMAIN=//p' .env | tr -d '"')
cat <<MSG

All set. Open WebUI is running on $url
$( [[ -n $domain ]] && grep -q '^COMPOSE_PROFILES=.*https' .env && echo "and on https://$domain (through Caddy)." )

Next steps:
  1. Create your admin account now. The first account to sign up becomes admin,
     and public sign-up closes after that. On this machine, open $url
     On a server, from your laptop:
         ssh -L 3000:${url#http://} <user>@<this-server>     then open http://localhost:3000
  2. Give your team access: HTTPS with the built-in Caddy (DOMAIN in .env) or a VPN (Tailscale).
  3. Add teammates in Admin Panel > Users > "+" (Add User).
  4. More models: docker compose exec ollama ollama pull <name>   (or add to MODELS in .env)
MSG
