# syntax=docker/dockerfile:1
# One self-contained image: Open WebUI (chat interface) + Ollama (runs the LLM) + the model itself.
# Nothing is downloaded when the container starts, so it also runs offline.
#
#   docker build -t ai-chat .
#   docker build -t ai-chat --build-arg MODELS="llama3.1:8b qwen2.5:7b" .
#   docker run -d --name ai-chat -p 127.0.0.1:3000:8080 -v ai-chat-data:/app/backend/data --restart always ai-chat
#
# Then open http://localhost:3000 and create the admin account (the first sign-up becomes admin).
# For the multi-container setup instead (separate Ollama, HTTPS, GPU add-ons), see docker-compose.yml.

# Open WebUI's official image with Ollama built in. Pin a release with e.g.
#   --build-arg BASE_IMAGE=ghcr.io/open-webui/open-webui:v0.13.3-ollama
ARG BASE_IMAGE=ghcr.io/open-webui/open-webui:ollama
FROM ${BASE_IMAGE}

# Models to build into the image, separated by spaces. https://ollama.com/library
# Each adds its download size to the image (qwen2.5:7b is about 4.7 GB).
ARG MODELS="qwen2.5:7b"

# Start Ollama for the length of this build step, download the models into the image, stop it.
RUN set -eu; \
    ollama serve >/tmp/ollama-build.log 2>&1 & pid=$!; \
    for i in $(seq 1 60); do ollama list >/dev/null 2>&1 && break; sleep 1; done; \
    ollama list >/dev/null 2>&1 || { cat /tmp/ollama-build.log; exit 1; }; \
    for m in $MODELS; do echo "Pulling model $m"; ollama pull "$m"; done; \
    ollama list; \
    kill "$pid"; wait "$pid" 2>/dev/null || true; \
    rm -f /tmp/ollama-build.log

ENV \
    # Start the bundled Ollama together with Open WebUI.
    USE_OLLAMA_DOCKER=true \
    # Every signed-in user sees every model (otherwise only admins do until each is shared).
    BYPASS_MODEL_ACCESS_CONTROL=True \
    # Hide the built-in OpenAI connection (no key; it only logs errors).
    ENABLE_OPENAI_API=False \
    # Keep the session-signing key in the data volume, so updates don't log everyone out.
    WEBUI_SECRET_KEY_FILE=/app/backend/data/.webui_secret_key

EXPOSE 8080
# Accounts, chats and settings. Models are in /root/.ollama (inside the image).
VOLUME ["/app/backend/data"]
