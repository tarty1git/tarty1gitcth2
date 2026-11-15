# shellcheck shell=bash
# Shared helpers for setup.sh, update.sh and diagnose.sh. Source this file; don't run it.

OLLAMA_INTERNAL_URL=http://ollama:11434   # how containers reach Ollama
export WEBUI_IMAGE=ghcr.io/open-webui/open-webui:main

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# healthy / starting / unhealthy, or the plain state (running, exited) when there's no healthcheck.
container_state() {
  docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null
}
ollama_up() { [[ $(container_state ollama) == healthy ]]; }
webui_up()  { [[ $(container_state open-webui) == healthy ]]; }

# wait_for <check-function> <seconds>
wait_for() {
  local fn=$1 secs=$2 i
  for ((i = 0; i < secs; i += 2)); do "$fn" && return 0; sleep 2; done
  "$fn"
}

# The address people use to reach Open WebUI from this machine, e.g. http://127.0.0.1:3000
webui_url() {
  local p
  p=$(docker compose port open-webui 8080 2>/dev/null | head -1) || return 1
  [[ -n $p ]] || return 1
  p=${p/0.0.0.0/127.0.0.1}
  echo "http://$p"
}

# Prints the Ollama URL(s) Open WebUI has saved in its database.
stored_ollama_urls() {
  docker exec open-webui python3 -c "
import sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
r = c.execute(\"select value from config where key='ollama.base_urls'\").fetchone()
print(r[0] if r else '')" 2>/dev/null
}

# Open WebUI reads OLLAMA_BASE_URL only on its first start, then uses the URL saved in its
# database. Data carried over from the host-Ollama setup or the plain 'docker run' command has
# 127.0.0.1:11434, localhost:11434 or host.docker.internal:11434 saved, none of which reach the
# Ollama container. Those are rewritten to http://ollama:11434. Other custom URLs (such as a
# remote Ollama server) are left alone.
# Also turns off the default OpenAI connection when it has no API key: it can't work
# and only fills the log with errors.
fix_stored_ollama_url() {
  local changed
  changed=$(docker exec open-webui python3 -c "
import re, sqlite3
c = sqlite3.connect('/app/backend/data/webui.db')
get = lambda k: (c.execute('select value from config where key=?', (k,)).fetchone() or [''])[0]
bad = re.compile(r'(127\.0\.0\.1|localhost|host\.docker\.internal):11434')
out = []
for k in ('ollama.base_urls', 'rag.ollama.base_url'):
    v = str(get(k))
    if bad.search(v):
        if k == 'ollama.base_urls':
            out.append('Ollama URL %s -> ollama:11434' % v)
        c.execute('update config set value = ? where key = ?', (bad.sub('ollama:11434', v), k))
if str(get('openai.enable')) == 'true' and str(get('openai.api_keys')).replace(' ', '') in ('', '[\"\"]'):
    out.append('turned off the OpenAI connection (no API key)')
    c.execute(\"update config set value = 'false' where key = 'openai.enable'\")
c.commit()
print('; '.join(out))") || return 0
  [[ -n $changed ]] || return 0
  log "Fixing saved settings: $changed"
  docker restart open-webui >/dev/null
  sleep 5
  wait_for webui_up 300 || die "Open WebUI didn't come back after the restart. Check: docker logs open-webui"
}

# Follows the 'models' job until it exits. Returns its exit code.
wait_for_models() {
  # 'docker logs -f' (unlike 'docker compose logs -f') stops when the container exits.
  # --since: the container is reused between runs; show only this run's output.
  local since
  since=$(docker container inspect -f '{{.State.StartedAt}}' ollama-models 2>/dev/null) || return 1
  docker logs -f --since "$since" ollama-models 2>&1 || true
  local code
  code=$(docker container inspect -f '{{.State.ExitCode}}' ollama-models 2>/dev/null) || return 1
  return "$code"
}
