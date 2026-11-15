# Self-hosted team chat: Ollama + Open WebUI, all in Docker

Everything runs in Docker containers. You don't need to install anything except Docker:

| Container | What it is |
|---|---|
| `ollama` | Runs the LLM. Downloaded models live in the `ollama` volume. |
| `ollama-models` | A one-off job that downloads the models listed in `.env`, then exits. |
| `open-webui` | The chat web interface. Accounts and chats live in the `open-webui` volume. |
| `caddy` | Optional HTTPS front door with automatic certificates (`COMPOSE_PROFILES=https`). |

Ollama publishes no port, because it has no login. Only the other containers can reach it.
Open WebUI is published on `127.0.0.1:3000`, so only this machine can reach it unless you change that.

| File | What it does |
|---|---|
| `setup.sh` | Creates `.env`, starts everything, downloads models, and checks that it all works. Safe to run again. Migrates earlier installs. |
| `update.sh` | Updates all images to the newest versions. Accounts, chats, logins and models are kept. |
| `diagnose.sh` | Read-only health check. Explains why something isn't working. |
| `docker-compose.yml` | The containers. |
| `docker-compose.gpu.yml` / `docker-compose.amd.yml` | Add-ons that give Ollama an NVIDIA or AMD GPU. |
| `.env.example` | All settings (models, port, HTTPS, GPU). Copied to `.env` on first run. |
| `Caddyfile` | The HTTPS reverse-proxy config used by the `caddy` container. |

## Quick start

Works on Linux, macOS and Windows (Docker Desktop or Docker Engine).

```bash
git clone <this repo> ai && cd ai
./setup.sh                          # default model: qwen2.5:7b
./setup.sh llama3.1:8b qwen2.5:7b   # or name one or more models (saved in .env)
```

On Linux, use `sudo ./setup.sh` unless your user is in the `docker` group. If Docker isn't
installed, `sudo ./setup.sh` installs it. On Windows, run the script from Git Bash or WSL.

**Without the script**, plain Docker Compose works too:

```bash
cp .env.example .env        # edit MODELS etc.
docker compose up -d
docker compose logs -f models   # watch the model download (Ctrl+C when it says "All models ready")
```

Then open <http://localhost:3000> and **straight away** create the admin account. The first
account to sign up becomes admin, and public sign-up closes after that. On a remote server,
tunnel in from your laptop:

```bash
ssh -L 3000:127.0.0.1:3000 you@your-server     # then open http://localhost:3000
```

Add teammates in **Admin Panel → Users → +** (Add User). Then give them a way in: [HTTPS](#https-with-the-built-in-caddy) or a [VPN](#vpn-instead).

## Models

- **Choosing:** on a CPU or a GPU with 8 GB, use a 7–8B model. With 16–24 GB of VRAM, 14B
  models fit. Very small models, such as `qwen2.5:0.5b`, are fast but give weak answers.
  Browse the [Ollama library](https://ollama.com/library).
- **Adding one:** `docker compose exec ollama ollama pull llama3.1:8b`, then reload the page.
  To have it pulled on every setup, also add it to `MODELS` in `.env`.
- **Listing / removing:** `docker compose exec ollama ollama list`, `... ollama rm <name>`.
- Models are stored in the `ollama` volume, so they survive updates and restarts.
- The `models` job runs on every `docker compose up`. Models you already have are only checked
  for updates, which takes a few seconds. If the machine is offline, the check fails, but the
  containers keep running and the models you already have still work.

## Settings (`.env`)

| Setting | Default | Meaning |
|---|---|---|
| `MODELS` | `qwen2.5:7b` | Models to download, separated by spaces. |
| `WEBUI_BIND` | `127.0.0.1` | `0.0.0.0` opens Open WebUI to the network. Ports Docker publishes skip UFW, so your firewall won't block it. Prefer Caddy or a VPN. |
| `WEBUI_PORT` | `3000` | Port for Open WebUI. |
| `COMPOSE_PROFILES` / `DOMAIN` | off | Set both to turn on HTTPS with Caddy. |
| `COMPOSE_FILE` | – | Adds the GPU add-on files. |
| `OLLAMA_VERSION` / `WEBUI_VERSION` | `latest` / `main` | Pin image versions. |
| `OLLAMA_KEEP_ALIVE` | `5m` | How long a model stays in memory after the last request. |

After changing `.env`, run `docker compose up -d` (or `./setup.sh`).

## HTTPS with the built-in Caddy

You need a domain name whose DNS A/AAAA record points at your server, and ports 80 and 443 open.

1. In `.env`, set:
   ```
   COMPOSE_PROFILES=https
   DOMAIN=ai.yourdomain.com
   ```
2. Run `./setup.sh` (or `docker compose up -d`).
3. Open the firewall if you use UFW: `sudo ufw allow 80,443/tcp`.

Caddy gets and renews the certificate itself, and forwards WebSockets, which Open WebUI needs
for streaming replies. Certificates are kept in the `caddy-data` volume.

## VPN instead

With Tailscale or WireGuard the server is never exposed publicly. For a small team that's
often the safest choice. With Tailscale installed on the server and your team's devices,
`sudo tailscale serve --bg 3000` gives HTTPS on your tailnet with no open ports.

## GPU

**NVIDIA:**

1. Install the driver and reboot (Ubuntu: `sudo ubuntu-drivers autoinstall`). Check that `nvidia-smi` lists your GPU.
2. Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html), then run
   `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
3. Run `./setup.sh`. It finds the GPU and sets `COMPOSE_FILE=docker-compose.yml:docker-compose.gpu.yml` in `.env`.
4. Load a model, then run `docker compose exec ollama ollama ps`. The PROCESSOR column should say `100% GPU`.
   A split like `40%/60% CPU/GPU` means the model doesn't fit in VRAM and will be much slower.

**AMD (ROCm):** set `COMPOSE_FILE=docker-compose.yml:docker-compose.amd.yml` in `.env`.
This uses the `ollama/ollama:rocm` image.

**Mac:** Docker on macOS can't use the Apple GPU, so Ollama runs on the CPU in Docker. For
GPU speed on a Mac, install the Ollama app natively and point Open WebUI at
`http://host.docker.internal:11434` in Admin Settings → Connections.

Only Ollama needs the GPU; Open WebUI doesn't.

## Updating

```bash
./update.sh
```

This pulls the newest Ollama, Open WebUI and Caddy images, restarts the containers and pulls
any new models from `.env`. Logins survive updates because the session-signing key is kept in
the data volume (`WEBUI_SECRET_KEY_FILE`).

## Moving from the earlier setup (Ollama installed on the host)

Just run `./setup.sh`. It:

- reuses the `open-webui` volume, so accounts and chats carry over;
- replaces the old container, whether it came from the earlier `docker-compose.yml` (host
  networking) or from the plain `docker run -p 3000:8080 ...` command;
- copies the models from the host's Ollama (`/usr/share/ollama/.ollama/models` or
  `~/.ollama/models`) into the `ollama` volume, so they aren't downloaded again;
- rewrites the saved Ollama URL (`127.0.0.1:11434`, `localhost:11434` or
  `host.docker.internal:11434`) to `http://ollama:11434`.

The host's Ollama is no longer used. To stop it: `sudo systemctl disable --now ollama`.
Docker Compose then prints `volume "open-webui" already exists but was not created by Docker
Compose`. That warning is harmless.

## Why it's set up this way

- **Ollama publishes no port.** It has no login. The containers share a private Docker
  network and Open WebUI reaches it at `http://ollama:11434`.
- **Open WebUI binds to `127.0.0.1`.** Ports Docker publishes skip UFW's rules, so a plain
  `-p 3000:8080` would be open to the internet even with UFW blocking it.
- **Changing `OLLAMA_BASE_URL` later does nothing.** Open WebUI reads it only on its first
  start, then uses the URL saved in its database. `setup.sh` and `update.sh` repair known-bad
  values. Otherwise, change it in Admin Settings → Connections.
- **Regular users see no models by default.** Open WebUI shows models only to admins until each
  one is shared. `BYPASS_MODEL_ACCESS_CONTROL=True` makes every model visible to every
  signed-in user. Remove that line if you want per-model access control.

## Troubleshooting

Run `./diagnose.sh` first. It checks each link in the chain and tells you which one is broken.

- **Logs:** `docker compose logs -f open-webui`, `docker compose logs -f ollama`, `docker compose logs models`
- **Status:** `docker compose ps -a`
- **A model failed to download:** check the name on [ollama.com/library](https://ollama.com/library), then `docker compose up models`.
- **Stop everything:** `docker compose down` (data is kept). `docker compose down -v` also
  **deletes** accounts, chats and models.

## How this was tested

Tested on Linux with Docker 29 and Compose v5, Ollama 0.40.16, Open WebUI 0.13.3 and `qwen2.5:0.5b` (no GPU):

- Fresh install from nothing (no volumes). Run a second time to check it's safe to rerun.
- Migration from the earlier host-networking setup: the saved Ollama URL was repaired and Open WebUI switched to the Docker network.
- Models copied from a host Ollama folder were used with no new download.
- Rerunning `setup.sh` after `docker compose down` works.
- First sign-up becomes admin, and a second public sign-up is refused. The admin login survives `update.sh`.
- Chat replies through the API and in a real browser, both directly and through Caddy over HTTPS (with a local certificate for `localhost`).
- Ollama is not reachable from the host, and Open WebUI listens on `127.0.0.1` only.

Not tested: NVIDIA/AMD GPUs, Docker Desktop on Mac/Windows, real Let's Encrypt certificates, and Tailscale.
