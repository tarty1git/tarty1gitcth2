#!/usr/bin/env bash
# Updates Ollama, Open WebUI (and Caddy, if used) to the newest images, and pulls any new
# models listed in .env. Accounts, chats, logins and models are kept in their volumes.
# Usage: ./update.sh     (use sudo unless your user is in the docker group)
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

log "Pulling the newest images"
docker compose pull -q --ignore-buildable
log "Restarting with the new images"
docker compose up -d --remove-orphans
wait_for webui_up 300 || die "Open WebUI didn't become healthy. Check: docker compose logs open-webui"
fix_stored_ollama_url
log "Checking models"
wait_for_models || warn "A model failed to download. Log: docker compose logs models"
docker image prune -f >/dev/null
echo
echo "Ollama $(docker exec ollama ollama --version 2>/dev/null | grep -o '[0-9][0-9.]*' | tail -1), Open WebUI $(docker exec open-webui curl -fsS localhost:8080/api/version | sed 's/.*"version":"\([^"]*\)".*/\1/') are running."
