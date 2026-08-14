
(日本語版: [README.jp.md](README.jp.md))

# Purpose

This repository is a minimal, self-contained Docker Compose setup for running
[Hermes Agent](https://github.com/NousResearch/hermes-agent) against a locally hosted LLM served by
`llama.cpp` (CUDA backend), instead of a hosted model API. It's kept deliberately small so it can be
shared and read end-to-end as a reference.

# Tested environment

- OS: Ubuntu 26.04 LTS
- CPU: Intel Xeon E-2276ME @ 2.80GHz (6 cores / 12 threads)
- RAM: 30GB
- GPU: NVIDIA Quadro P2200 (5GB VRAM), driver 580.173.02

# Prerequisites

The host needs the NVIDIA driver, Docker Engine, and the NVIDIA Container Toolkit installed before
following the steps below (no driver is needed inside the container).

## Check the NVIDIA driver is installed

```bash
nvidia-smi
```
You're good if this prints GPU info. If not, install the driver first.
Install driver 580 — it's the last full-feature driver branch for the Pascal generation, since 590 and
later drop Pascal support, so it needs to be pinned to this version.
```bash
sudo apt install nvidia-driver-580
# reboot
sudo reboot
```

After rebooting, GPU info should show up again:

```bash
nvidia-smi
```

## Install Docker Engine (from the official repository)

Use the official APT package, not the snap package. The snap package is sandboxed and can't access the
GPU device files, so GPU passthrough fails.

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg

# add the official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# add the repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# install
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ubuntu 26 doesn't ship newgrp by default, so install it
sudo usermod -aG docker $USER
sudo apt install -y util-linux-extra
newgrp docker
```

## NVIDIA Container Toolkit

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

# Model files

`models/` holds the GGUF model files that `compose.e4b-qat.yml` mounts into the `llama-server`
container; it's gitignored, so nothing under it is tracked by this repository. Download the following
three files from [unsloth/gemma-4-E4B-it-qat-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF)
on Hugging Face and place them as shown:

```
models/gemma-4-E4B-it-qat/
├── gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf   # main model (4-bit dynamic quant)
├── mmproj-F16.gguf                      # multimodal projector
└── mtp-gemma-4-E4B-it.gguf              # multi-token-prediction draft model
```

# Initial setup

`./.hermes-data` is just a plain bind mount, so a size cap can't be set through Docker Compose
alone. To keep a runaway `hermes` container from filling up the host disk with logs/DB writes, back
it with a fixed-size loopback image (an ext4-formatted file) instead, and mount that.

`.hermes` (dashboard data) and `.hermes-web` (web assets) share the same image and the same mount
point (`./.hermes-data`), split into subdirectories underneath it:

- `./.hermes-data/hermes` → the container's `/opt/data`
- `./.hermes-data/web` → the container's `/opt/hermes/web`

Why a loopback image rather than `tmpfs` or a Docker volume's `--storage-opt size=`: this data
(dashboard config, history, web assets) needs to survive container restarts and host reboots, which
rules out `tmpfs` (RAM-backed, gone on restart). `--storage-opt size=` was also considered, but it
only works when the backing filesystem is XFS with project quotas (or for `tmpfs`-type volumes);
this repo's tested environment is ext4, where that option isn't available. A loopback ext4 image
works regardless of the host filesystem and persists to disk.

## First-time setup

```bash
# 1. Create a fixed-size sparse image (resize as needed)
truncate -s 10G .hermes-data.img

# 2. Format as ext4
mkfs.ext4 -q .hermes-data.img

# 3. Create the mount point
mkdir -p .hermes-data

# 4. Loop-mount it (requires root)
sudo mount -o loop .hermes-data.img .hermes-data

# 5. Chown it to yourself, purely so the mkdir/cp steps below don't need sudo.
#    It does NOT need to match any UID inside the container: the hermes image runs its
#    process as root (`docker inspect nousresearch/hermes-agent:latest --format
#    '{{.Config.User}}'`) with no user-namespace remap, so it bypasses host file
#    permissions entirely and can write here regardless of ownership. One consequence:
#    files it creates from then on will show up owned by root on the host, so later
#    inspection/cleanup under .hermes-data/hermes may need sudo.
sudo chown "$(id -u):$(id -g)" .hermes-data

# 6. Create the subdirectories
mkdir -p .hermes-data/hermes .hermes-data/web

# 7. Place the config file
cp config.yaml .hermes-data/hermes/
```

## Before every startup

Loop mounts don't survive a host reboot or an unmount, so check it's mounted before `docker
compose up`:

```bash
mountpoint -q .hermes-data || sudo mount -o loop .hermes-data.img .hermes-data
```

## Auto-mounting on reboot (optional)

`/etc/fstab` only accepts absolute paths, so run this from the repo root to build the absolute
path from the current directory and append it (`nofail` keeps boot from stalling if the image is
missing):

```bash
echo "$(pwd)/.hermes-data.img $(pwd)/.hermes-data ext4 loop,nofail 0 0" | sudo tee -a /etc/fstab
```

Verify what got appended:

```bash
grep hermes-data /etc/fstab
```

To test the `fstab` entry without rebooting, unmount and then let `mount -a` remount it via
`fstab`:

```bash
sudo umount .hermes-data
sudo mount -a
mountpoint .hermes-data
```

## When the image fills up

Once the 10GB image is full, writes from the container fail (the host disk itself is unaffected).
Check free space:

```bash
df -h .hermes-data
```

To grow it, stop the container, unmount, then extend the image with `truncate` and `resize2fs`:

```bash
sudo umount .hermes-data
truncate -s 20G .hermes-data.img
e2fsck -f .hermes-data.img
resize2fs .hermes-data.img
sudo mount -o loop .hermes-data.img .hermes-data
```

# Configure the environment

`docker-compose.yml` marks `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`/`PASSWORD` as required, and
`docker compose` validates the whole file — including the `hermes` service's env vars — for every
subcommand, even `build`. `.env.sample` also sets `COMPOSE_FILE`, which `docker compose` reads
automatically from `.env` (it's not just used for variable substitution). Copy it and fill in the
credentials instead of exporting everything by hand every time:

```bash
cp .env.sample .env
$EDITOR .env  # set your own username/password
```

`.env.sample` points `COMPOSE_FILE` at `compose.e4b-qat.yml`, the default single-slot config for the E4B
model. This repo also ships `compose.e4b-qat-np2.yml`, which runs two parallel slots instead — swap it in
by editing `COMPOSE_FILE` in `.env`:

```
COMPOSE_FILE=docker-compose.yml:compose.e4b-qat-np2.yml
```

See "Known gap" under [About the healthcheck / supervisor](#about-the-healthcheck--supervisor) before
using it — the stall watchdog has a blind spot with two slots.

# Build
```bash
docker compose build llama-server
docker compose pull hermes
```

# Run
```bash
docker compose up -d
```

# About the healthcheck / supervisor

There are reports of `/health` continuing to return OK while an inference slot hangs
([llama.cpp#20921](https://github.com/ggml-org/llama.cpp/issues/20921)). The issue is closed, but no root
cause was identified and no fix or workaround has confirmed effectiveness, so it can still recur
intermittently. To handle this, this repository monitors the `/slots` endpoint's progress (healthy as
long as any one of `id_task` / `n_prompt_tokens_processed` / `n_decoded` is moving) and restarts the
whole container when a hang is detected (`healthcheck-slots.sh` / `supervisor.sh`).

`/slots` can time out for up to ~48 seconds even during normal prefill (distinguishable because `/health`
still responds instantly). So a single timeout is not treated as a failure — only when there has been no
response at all for `SLOT_STALL_SECONDS` seconds (default 180) is it marked unhealthy.

### Known gap: `compose.e4b-qat-np2.yml` (`-np 2`) can miss a hung slot

The watchdog builds a single progress fingerprint from the whole `/slots` response (`id_task` /
`n_prompt_tokens_processed` / `n_decoded` of every slot concatenated together) rather than tracking each
slot separately.

**This misses a hang under one specific condition: slot A hangs while slot B keeps continuously receiving
and processing requests for the entire `SLOT_STALL_SECONDS` window.** Because the fingerprint concatenates
both slots, slot B's fields keep changing every poll, so the combined fingerprint never goes stale and the
timer never fires — slot A's hang goes unnoticed indefinitely. If slot B is idle (not processing) instead,
the aggregate fingerprint IS static and the hang is still detected correctly as before; the gap only opens
when the healthy slot is kept busy throughout.

If you use `compose.e4b-qat-np2.yml`, keep this in mind, especially under sustained/always-on traffic where
both slots may be busy back-to-back.

`supervisor.sh` runs llama-server as a child process; once it detects the stall above, it SIGKILLs the
child and exits, taking the container down (`restart: unless-stopped` lets compose recreate it). It
avoids using `docker.sock` because sharing that socket effectively grants host-root-equivalent privileges.
Running llama-server as a child process rather than as PID 1 also means it can be reliably SIGKILLed from
within the container.

### Watchdog timing thresholds

These control when a stall is detected and the container gets restarted. They haven't been verified to
be optimal, just values that seemed reasonable. Set them too short and a temporary slowdown can be
misdetected as a stall, triggering an unnecessary restart; set them too long and a real hang takes longer
to detect and recover from.

| Env var | Default | Description |
|---|---|---|
| `SLOT_STALL_SECONDS` | 180 | Seconds of no progress/no response before it's considered a stall |
| `WATCH_POLL_SECONDS` | 30 | Supervisor polling interval |
| `WATCH_START_PERIOD` | 120 | Grace period (seconds) after startup before monitoring begins |

### Other variables

Paths and URLs the scripts use — not tuning knobs, just either correct or not for how the container is
built.

| Env var | Default | Description |
|---|---|---|
| `LLAMA_URL` | `http://localhost:8080` | URL of llama-server |
| `SLOT_STATE_FILE` | `/tmp/llama-slots-watch` | State file used to track progress |
| `LLAMA_SLOTS_FIXTURE` | (none) | For testing. If set, this file's content is used as the `/slots` response |
| `LLAMA_BIN` | `/app/llama-server` | Path to the llama-server binary |
