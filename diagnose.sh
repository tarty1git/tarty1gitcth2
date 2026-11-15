#!/usr/bin/env bash
# Finds out why Open WebUI isn't working or showing models. Run: ./diagnose.sh (sudo if needed)
# Read-only: it changes nothing.
set -u
cd "$(dirname "$0")" || exit 1
source ./lib.sh
problems=0
bad() { printf '  PROBLEM: %s\n' "$*"; problems=$((problems + 1)); }
ok()  { printf '  ok: %s\n' "$*"; }

log "Docker"
if ! docker info >/dev/null 2>&1; then
  bad "Docker isn't reachable (start it, or run with sudo)"; echo; echo "1 problem found."; exit 1
fi
ok "Docker $(docker version --format '{{.Server.Version}}')"
[[ -f .env ]] && ok ".env present" || printf '  note: no .env; defaults are used. Run setup.sh to create one.\n'

log "Ollama container"
st=$(container_state ollama)
if [[ -z $st ]]; then bad "No ollama container. Run setup.sh"
elif [[ $st != healthy ]]; then bad "ollama is '$st'. See: docker compose logs ollama"
else
  models=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | paste -sd' ')
  [[ -n $models ]] && ok "Ollama is running with: $models" ||
    bad "Ollama has no models. Run: docker compose up models   (or: docker compose exec ollama ollama pull qwen2.5:7b)"
  if docker exec ollama sh -c 'ls /dev/nvidia* >/dev/null 2>&1'; then ok "Ollama sees the NVIDIA GPU"
  elif command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then
    printf '  note: this machine has an NVIDIA GPU but Ollama runs on the CPU. See "GPU" in the README.\n'
  fi
fi
mc=$(docker container inspect -f '{{.State.ExitCode}}' ollama-models 2>/dev/null)
[[ -n $mc && $mc != 0 && $(container_state ollama-models) == exited ]] &&
  bad "The last model download failed. See: docker compose logs models"

log "Open WebUI container"
st=$(container_state open-webui)
if [[ -z $st ]]; then bad "No open-webui container. Run setup.sh"
else
  [[ -z $(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' open-webui) ]] &&
    bad "The container was made with plain 'docker run', not this compose file. Rerun setup.sh to migrate it."
  [[ $(docker container inspect -f '{{.HostConfig.NetworkMode}}' open-webui) == host ]] &&
    bad "The container uses host networking (the older setup). Rerun setup.sh to switch to the all-Docker setup."
  [[ $st == healthy ]] && ok "Open WebUI is healthy on $(webui_url || echo '?')" || bad "open-webui is '$st'. See: docker compose logs open-webui"
  env=$(docker container inspect open-webui --format '{{range .Config.Env}}{{println .}}{{end}}')
  grep -q '^BYPASS_MODEL_ACCESS_CONTROL=True' <<<"$env" ||
    printf '  note: non-admin users only see models shared with them (Admin Settings > Models).\n'

  if [[ $st == healthy ]]; then
    log "Connection from Open WebUI to Ollama"
    urls=$(stored_ollama_urls)
    echo "  saved Ollama URL(s): ${urls:-unknown}"
    for u in $(tr -d '[]"' <<<"$urls" | tr ',' ' '); do
      if docker exec open-webui curl -fsS --max-time 5 "$u/api/tags" >/dev/null 2>&1; then ok "container reaches $u"
      else bad "container can't reach $u. Rerun setup.sh, or set $OLLAMA_INTERNAL_URL in Admin Settings > Connections."; fi
    done
  fi
fi

log "Exposure"
ports=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null)
grep -q '^ollama .*->11434' <<<"$ports" && bad "Ollama publishes port 11434. It has no login; remove that port mapping."
wp=$(docker compose port open-webui 8080 2>/dev/null | head -1)
case $wp in
  127.0.0.1:*) ok "Open WebUI is local-only ($wp)" ;;
  "") ;;
  *) printf '  note: Open WebUI is published on %s, reachable from the network. Docker-published ports skip UFW.\n' "$wp" ;;
esac
grep -q '^caddy ' <<<"$ports" && ok "Caddy is running: $(grep '^caddy ' <<<"$ports" | cut -d' ' -f2-)"

log "Recent Open WebUI errors"
docker logs --since 30m open-webui 2>&1 | grep -iE 'error|exception' | grep -viE "SyntaxWarning|FutureWarning|SAWarning" | tail -8 || true

echo
((problems == 0)) && echo "No problems found. If a user still sees no models, have them reload the page and sign in again." \
                  || echo "$problems problem(s) found above."
